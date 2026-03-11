import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/background/foreground_task_service.dart';
import '../services/network/network_monitor.dart';
import '../services/ssh/ssh_client.dart';
import 'connection_provider.dart';

/// SSH connection state
class SshState {
  final SshConnectionState connectionState;
  final String? error;
  final String? sessionTitle;
  final bool isReconnecting;
  final int reconnectAttempt;
  final int? reconnectDelayMs;

  /// Whether the network is available
  final bool isNetworkAvailable;

  /// Scheduled next retry time
  final DateTime? nextRetryAt;

  /// Whether reconnection is paused (when network is unavailable)
  final bool isPaused;

  const SshState({
    this.connectionState = SshConnectionState.disconnected,
    this.error,
    this.sessionTitle,
    this.isReconnecting = false,
    this.reconnectAttempt = 0,
    this.reconnectDelayMs,
    this.isNetworkAvailable = true,
    this.nextRetryAt,
    this.isPaused = false,
  });

  SshState copyWith({
    SshConnectionState? connectionState,
    String? error,
    String? sessionTitle,
    bool? isReconnecting,
    int? reconnectAttempt,
    int? reconnectDelayMs,
    bool? isNetworkAvailable,
    DateTime? nextRetryAt,
    bool? isPaused,
  }) {
    return SshState(
      connectionState: connectionState ?? this.connectionState,
      error: error,
      sessionTitle: sessionTitle ?? this.sessionTitle,
      isReconnecting: isReconnecting ?? this.isReconnecting,
      reconnectAttempt: reconnectAttempt ?? this.reconnectAttempt,
      reconnectDelayMs: reconnectDelayMs,
      isNetworkAvailable: isNetworkAvailable ?? this.isNetworkAvailable,
      nextRetryAt: nextRetryAt,
      isPaused: isPaused ?? this.isPaused,
    );
  }

  bool get isConnected => connectionState == SshConnectionState.connected;
  bool get isConnecting => connectionState == SshConnectionState.connecting;
  bool get isDisconnected => connectionState == SshConnectionState.disconnected;
  bool get hasError => connectionState == SshConnectionState.error;

  /// Whether waiting offline for network
  bool get isWaitingForNetwork => isPaused && !isNetworkAvailable;
}

/// Notifier that manages SSH connections
class SshNotifier extends Notifier<SshState> {
  SshClient? _client;
  final SshForegroundTaskService _foregroundService = SshForegroundTaskService();

  // Cache for reconnection
  Connection? _lastConnection;
  SshConnectOptions? _lastOptions;

  // Unlimited retry mode (0 = unlimited)
  static const int _maxReconnectAttempts = 0; // Unlimited

  // Exponential backoff (max 60 seconds)
  static const int _baseDelayMs = 1000;
  static const int _maxDelayMs = 60000;
  static const double _backoffMultiplier = 1.5;

  // For connection state monitoring
  StreamSubscription<SshConnectionState>? _connectionStateSubscription;

  // For network state monitoring
  StreamSubscription<NetworkStatus>? _networkStatusSubscription;

  // Reconnection timer
  Timer? _reconnectTimer;

  // Disconnect detection callback (configurable externally)
  void Function()? onDisconnectDetected;

  // Reconnection success callback (configurable externally)
  void Function()? onReconnectSuccess;

  @override
  SshState build() {
    // Monitor network state
    _startNetworkMonitoring();

    // Register cleanup
    ref.onDispose(() {
      _reconnectTimer?.cancel();
      _reconnectTimer = null;
      // Stream subscriptions and client dispose are async but
      // ref.onDispose is synchronous. Cancel what we can synchronously
      // and fire the async cleanup without awaiting.
      _connectionStateSubscription?.cancel();
      _connectionStateSubscription = null;
      _networkStatusSubscription?.cancel();
      _networkStatusSubscription = null;
      _client?.dispose();
      _client = null;
      _foregroundService.stopService();
    });
    return const SshState();
  }

  /// Start monitoring network state
  void _startNetworkMonitoring() {
    final monitor = ref.read(networkMonitorProvider);
    _networkStatusSubscription = monitor.statusStream.listen(_onNetworkStatusChanged);
  }

  /// Handler for network state changes
  void _onNetworkStatusChanged(NetworkStatus status) {
    final isOnline = status == NetworkStatus.online;

    state = state.copyWith(isNetworkAvailable: isOnline);

    if (isOnline) {
      // When recovering from offline to online
      if (state.isPaused && state.isReconnecting) {
        // Attempt to reconnect immediately (no delay)
        state = state.copyWith(isPaused: false, reconnectAttempt: 0);
        _reconnectTimer?.cancel();
        // Call _doReconnect directly for immediate reconnection
        _doReconnect();
      }
    } else {
      // When going offline
      if (state.isReconnecting) {
        // Pause reconnection
        state = state.copyWith(isPaused: true);
        _reconnectTimer?.cancel();
      }
    }
  }

  /// Calculate reconnection delay (exponential backoff)
  int _calculateDelay(int attempt) {
    final delay = (_baseDelayMs * math.pow(_backoffMultiplier, attempt)).round();
    return delay.clamp(_baseDelayMs, _maxDelayMs);
  }

  /// Get the SSH client
  SshClient? get client => _client;

  /// Last connection information
  Connection? get lastConnection => _lastConnection;

  /// Last connection options
  SshConnectOptions? get lastOptions => _lastOptions;

  /// Establish SSH connection (with shell - legacy method)
  Future<void> connect(Connection connection, SshConnectOptions options) async {
    state = state.copyWith(
      connectionState: SshConnectionState.connecting,
      error: null,
    );

    try {
      _client = SshClient();

      await _client!.connect(
        host: connection.host,
        port: connection.port,
        username: connection.username,
        options: options,
      );

      await _client!.startShell();

      state = state.copyWith(
        connectionState: SshConnectionState.connected,
      );

      // Update last connected time
      ref.read(connectionsProvider.notifier).updateLastConnected(connection.id);

      // Start foreground service to maintain connection in background
      await _foregroundService.startService(
        connectionName: connection.name,
        host: connection.host,
      );
    } on SshConnectionError catch (e) {
      state = state.copyWith(
        connectionState: SshConnectionState.error,
        error: e.message,
      );
      _client?.dispose();
      _client = null;
    } on SshAuthenticationError catch (e) {
      state = state.copyWith(
        connectionState: SshConnectionState.error,
        error: e.message,
      );
      _client?.dispose();
      _client = null;
    } catch (e) {
      state = state.copyWith(
        connectionState: SshConnectionState.error,
        error: e.toString(),
      );
      _client?.dispose();
      _client = null;
    }
  }

  /// Establish SSH connection (without shell - for tmux command mode)
  ///
  /// Only uses exec(), so no shell is started.
  Future<void> connectWithoutShell(Connection connection, SshConnectOptions options) async {
    // Cache for reconnection
    _lastConnection = connection;
    _lastOptions = options;

    // Cancel existing connection state monitoring
    await _connectionStateSubscription?.cancel();
    _connectionStateSubscription = null;

    state = state.copyWith(
      connectionState: SshConnectionState.connecting,
      error: null,
      isReconnecting: false,
      reconnectAttempt: 0,
    );

    try {
      _client = SshClient();

      // Monitor connection state stream (for faster disconnect detection)
      _connectionStateSubscription = _client!.connectionStateStream.listen(
        _onConnectionStateChanged,
      );

      await _client!.connect(
        host: connection.host,
        port: connection.port,
        username: connection.username,
        options: options,
      );

      // Do not start a shell (exec only)

      state = state.copyWith(
        connectionState: SshConnectionState.connected,
        isReconnecting: false,
        reconnectAttempt: 0,
      );

      // Update last connected time
      ref.read(connectionsProvider.notifier).updateLastConnected(connection.id);

      // Start foreground service to maintain connection in background
      await _foregroundService.startService(
        connectionName: connection.name,
        host: connection.host,
      );
    } on SshConnectionError catch (e) {
      state = state.copyWith(
        connectionState: SshConnectionState.error,
        error: e.message,
      );
      _client?.dispose();
      _client = null;
    } on SshAuthenticationError catch (e) {
      state = state.copyWith(
        connectionState: SshConnectionState.error,
        error: e.message,
      );
      _client?.dispose();
      _client = null;
    } catch (e) {
      state = state.copyWith(
        connectionState: SshConnectionState.error,
        error: e.toString(),
      );
      _client?.dispose();
      _client = null;
    }
  }

  /// Handler for connection state changes
  ///
  /// Immediately processes disconnect detection from keep-alive or socket.
  void _onConnectionStateChanged(SshConnectionState newState) {
    // When transitioning from connected state to disconnected/error
    if (state.isConnected &&
        (newState == SshConnectionState.error ||
         newState == SshConnectionState.disconnected)) {
      // Update state
      state = state.copyWith(
        connectionState: newState,
        error: newState == SshConnectionState.error ? 'Connection lost' : null,
      );

      // Invoke disconnect detection callback
      onDisconnectDetected?.call();

      // Attempt automatic reconnection (if not already reconnecting)
      if (!state.isReconnecting) {
        reconnect();
      }
    }
  }

  /// Attempt reconnection
  ///
  /// For automatic reconnection. Retries indefinitely with exponential backoff.
  /// Pauses when network is offline and automatically resumes on recovery.
  Future<bool> reconnect() async {
    if (_lastConnection == null || _lastOptions == null) {
      return false;
    }

    // Pause if network is offline
    if (!state.isNetworkAvailable) {
      state = state.copyWith(
        isReconnecting: true,
        isPaused: true,
        error: 'Waiting for network...',
      );
      return false;
    }

    final attempt = state.reconnectAttempt;

    // Only check limit if not in unlimited retry mode
    if (_maxReconnectAttempts > 0 && attempt >= _maxReconnectAttempts) {
      state = state.copyWith(
        isReconnecting: false,
        error: 'Max reconnect attempts reached',
      );
      return false;
    }

    final delayMs = _calculateDelay(attempt);
    final nextRetry = DateTime.now().add(Duration(milliseconds: delayMs));

    state = state.copyWith(
      isReconnecting: true,
      isPaused: false,
      reconnectAttempt: attempt + 1,
      reconnectDelayMs: delayMs,
      nextRetryAt: nextRetry,
    );

    // Reconnect after delay
    final completer = Completer<bool>();
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(Duration(milliseconds: delayMs), () async {
      final result = await _doReconnect();
      if (!completer.isCompleted) {
        completer.complete(result);
      }
    });

    return completer.future;
  }

  /// Actual reconnection process
  Future<bool> _doReconnect() async {
    if (_lastConnection == null || _lastOptions == null) {
      return false;
    }

    // Abort if network is offline
    if (!state.isNetworkAvailable) {
      state = state.copyWith(isPaused: true);
      return false;
    }

    try {
      // Cancel existing connection state monitoring
      await _connectionStateSubscription?.cancel();
      _connectionStateSubscription = null;

      // Clean up old client
      _client?.dispose();
      _client = SshClient();

      // Monitor connection state stream (for faster disconnect detection)
      _connectionStateSubscription = _client!.connectionStateStream.listen(
        _onConnectionStateChanged,
      );

      await _client!.connect(
        host: _lastConnection!.host,
        port: _lastConnection!.port,
        username: _lastConnection!.username,
        options: _lastOptions!,
      );

      state = state.copyWith(
        connectionState: SshConnectionState.connected,
        isReconnecting: false,
        isPaused: false,
        reconnectAttempt: 0,
        error: null,
        nextRetryAt: null,
      );

      // Reconnection success callback
      onReconnectSuccess?.call();

      return true;
    } catch (e) {
      // Reconnection failed, schedule next attempt
      state = state.copyWith(
        connectionState: SshConnectionState.error,
        error: 'Reconnect failed: $e',
      );

      // Automatically schedule next attempt (for unlimited retry mode)
      if (_maxReconnectAttempts == 0 || state.reconnectAttempt < _maxReconnectAttempts) {
        // Schedule next reconnection asynchronously
        Future.microtask(() => reconnect());
      }

      return false;
    }
  }

  /// Attempt reconnection immediately (for user-initiated action)
  Future<bool> reconnectNow() async {
    _reconnectTimer?.cancel();
    state = state.copyWith(
      reconnectAttempt: 0,
      isPaused: false,
    );
    return _doReconnect();
  }

  /// Check if connection is active
  bool checkConnection() {
    return _client != null && _client!.isConnected;
  }

  /// Reset reconnection state
  void resetReconnect() {
    _reconnectTimer?.cancel();
    state = state.copyWith(
      isReconnecting: false,
      isPaused: false,
      reconnectAttempt: 0,
      reconnectDelayMs: null,
      nextRetryAt: null,
    );
  }

  /// Disconnect
  Future<void> disconnect() async {
    // Cancel reconnection timer
    _reconnectTimer?.cancel();
    _reconnectTimer = null;

    // Cancel connection state monitoring
    await _connectionStateSubscription?.cancel();
    _connectionStateSubscription = null;

    // Stop foreground service
    await _foregroundService.stopService();

    await _client?.disconnect();
    _client = null;
    state = state.copyWith(
      connectionState: SshConnectionState.disconnected,
      error: null,
      sessionTitle: null,
      isReconnecting: false,
      isPaused: false,
      reconnectAttempt: 0,
      nextRetryAt: null,
    );
  }

  /// Update session title
  void updateSessionTitle(String title) {
    state = state.copyWith(sessionTitle: title);
  }

  /// Send data
  void write(String data) {
    _client?.write(data);
  }

  /// Resize terminal
  void resize(int cols, int rows) {
    _client?.resize(cols, rows);
  }
}

/// SSH provider
final sshProvider = NotifierProvider<SshNotifier, SshState>(() {
  return SshNotifier();
});
