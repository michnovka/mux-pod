import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../utils/async_utils.dart';

/// Network status
enum NetworkStatus {
  /// Network available
  online,

  /// Network unavailable
  offline,
}

/// Service that monitors network status
///
/// Uses connectivity_plus to detect network connection/disconnection,
/// and uses it as a trigger for SSH reconnection.
class NetworkMonitor {
  final Connectivity _connectivity = Connectivity();
  StreamSubscription<List<ConnectivityResult>>? _subscription;

  final _statusController = StreamController<NetworkStatus>.broadcast();

  NetworkStatus _currentStatus = NetworkStatus.online;
  bool _isDisposed = false;

  /// Current network status
  NetworkStatus get currentStatus => _currentStatus;

  /// Network status stream
  Stream<NetworkStatus> get statusStream => _statusController.stream;

  /// Whether the network is available
  bool get isOnline => _currentStatus == NetworkStatus.online;

  /// Start monitoring
  Future<void> start() async {
    if (_isDisposed || _subscription != null) return;

    // Get initial status
    final results = await _connectivity.checkConnectivity();
    _updateStatus(results);

    // Monitor changes
    _subscription = _connectivity.onConnectivityChanged.listen(_updateStatus);
  }

  /// Stop monitoring
  Future<void> stop() async {
    await _subscription?.cancel();
    _subscription = null;
  }

  /// Update status
  void _updateStatus(List<ConnectivityResult> results) {
    if (_isDisposed) return;

    final newStatus = _determineStatus(results);

    if (newStatus != _currentStatus) {
      _currentStatus = newStatus;
      _statusController.add(newStatus);
    }
  }

  /// Determine NetworkStatus from ConnectivityResult
  NetworkStatus _determineStatus(List<ConnectivityResult> results) {
    // Online if there is any connection other than none
    for (final result in results) {
      if (result != ConnectivityResult.none) {
        return NetworkStatus.online;
      }
    }
    return NetworkStatus.offline;
  }

  /// Release resources
  Future<void> dispose() async {
    if (_isDisposed) return;
    _isDisposed = true;
    await stop();
    await _statusController.close();
  }
}

/// Provider for the network monitor
final networkMonitorProvider = Provider<NetworkMonitor>((ref) {
  final monitor = NetworkMonitor();

  // Automatically start monitoring
  monitor.start();

  ref.onDispose(() {
    fireAndForget(
      monitor.dispose(),
      debugLabel: 'NetworkMonitor.dispose',
    );
  });

  return monitor;
});

/// Stream provider for network status
final networkStatusProvider = StreamProvider<NetworkStatus>((ref) {
  final monitor = ref.watch(networkMonitorProvider);
  return monitor.statusStream;
});
