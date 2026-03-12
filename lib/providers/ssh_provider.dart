import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/background/foreground_task_service.dart';
import '../services/network/network_monitor.dart';
import '../services/ssh/ssh_client.dart';
import 'connection_provider.dart';
import 'known_hosts_provider.dart';

typedef SshClientFactory = SshClient Function();

final sshClientFactoryProvider = Provider<SshClientFactory>((ref) {
  return SshClient.new;
});

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
  final SshForegroundTaskService _foregroundService =
      SshForegroundTaskService();

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
  Completer<bool>? _scheduledReconnectCompleter;
  Future<bool>? _activeReconnectFuture;
  int _reconnectGeneration = 0;

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
      _reconnectGeneration++;
      _cancelReconnectFlow(completePending: true);
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
    _networkStatusSubscription = monitor.statusStream.listen(
      _onNetworkStatusChanged,
    );
  }

  /// Handler for network state changes
  void _onNetworkStatusChanged(NetworkStatus status) {
    final isOnline = status == NetworkStatus.online;

    state = state.copyWith(isNetworkAvailable: isOnline);

    if (isOnline) {
      // When recovering from offline to online
      if (state.isPaused && state.isReconnecting) {
        // Attempt to reconnect immediately (no delay)
        state = state.copyWith(
          isPaused: false,
          reconnectAttempt: 0,
          reconnectDelayMs: null,
          nextRetryAt: null,
        );
        _cancelReconnectFlow();
        unawaited(reconnectNow());
      }
    } else {
      // When going offline
      if (state.isReconnecting) {
        // Pause reconnection
        state = state.copyWith(
          isPaused: true,
          reconnectDelayMs: null,
          nextRetryAt: null,
        );
        _cancelReconnectFlow(completePending: true);
      }
    }
  }

  /// Calculate reconnection delay (exponential backoff)
  int _calculateDelay(int attempt) {
    final delay = (_baseDelayMs * math.pow(_backoffMultiplier, attempt))
        .round();
    final jitter = 0.85 + (math.Random().nextDouble() * 0.3);
    return (delay * jitter).round().clamp(_baseDelayMs, _maxDelayMs);
  }

  SshClient _createClient() {
    return ref.read(sshClientFactoryProvider)();
  }

  void _cancelReconnectFlow({bool completePending = false}) {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;

    final completer = _scheduledReconnectCompleter;
    _scheduledReconnectCompleter = null;
    if (completePending && completer != null && !completer.isCompleted) {
      completer.complete(false);
    }
  }

  bool _canRetry(int attempt) {
    return _maxReconnectAttempts == 0 || attempt < _maxReconnectAttempts;
  }

  /// Get the SSH client
  SshClient? get client => _client;

  /// Last connection information
  Connection? get lastConnection => _lastConnection;

  /// Last connection options
  SshConnectOptions? get lastOptions => _lastOptions;

  /// Establish SSH connection (with shell - legacy method)
  Future<void> connect(Connection connection, SshConnectOptions options) async {
    _reconnectGeneration++;
    _cancelReconnectFlow(completePending: true);
    state = state.copyWith(
      connectionState: SshConnectionState.connecting,
      error: null,
      isReconnecting: false,
      isPaused: false,
      reconnectAttempt: 0,
      reconnectDelayMs: null,
      nextRetryAt: null,
    );

    try {
      _client = _createClient();

      await _client!.connect(
        host: connection.host,
        port: connection.port,
        username: connection.username,
        options: options,
      );

      await _client!.startShell();

      state = state.copyWith(connectionState: SshConnectionState.connected);

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
  Future<void> connectWithoutShell(
    Connection connection,
    SshConnectOptions options,
  ) async {
    // Cache for reconnection
    _lastConnection = connection;
    _lastOptions = options;
    _reconnectGeneration++;
    _cancelReconnectFlow(completePending: true);

    // Cancel existing connection state monitoring
    await _connectionStateSubscription?.cancel();
    _connectionStateSubscription = null;

    state = state.copyWith(
      connectionState: SshConnectionState.connecting,
      error: null,
      isReconnecting: false,
      isPaused: false,
      reconnectAttempt: 0,
      reconnectDelayMs: null,
      nextRetryAt: null,
    );

    try {
      _client = _createClient();

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
        isPaused: false,
        reconnectAttempt: 0,
        reconnectDelayMs: null,
        nextRetryAt: null,
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
        unawaited(reconnect());
      }
    }
  }

  /// Attempt reconnection
  ///
  /// For automatic reconnection. Retries indefinitely with exponential backoff.
  /// Pauses when network is offline and automatically resumes on recovery.
  Future<bool> reconnect() async {
    return _requestReconnect(immediate: false, resetAttempt: false);
  }

  Future<bool> _requestReconnect({
    required bool immediate,
    required bool resetAttempt,
  }) async {
    if (_lastConnection == null || _lastOptions == null) {
      return false;
    }

    final activeReconnectFuture = _activeReconnectFuture;
    if (activeReconnectFuture != null) {
      return activeReconnectFuture;
    }

    final pendingCompleter = _scheduledReconnectCompleter;
    if (_reconnectTimer != null) {
      if (!immediate) {
        return pendingCompleter!.future;
      }
      _reconnectTimer?.cancel();
      _reconnectTimer = null;
      _scheduledReconnectCompleter = null;
    }

    // Pause if network is offline
    if (!state.isNetworkAvailable) {
      state = state.copyWith(
        isReconnecting: true,
        isPaused: true,
        error: 'Waiting for network...',
        reconnectDelayMs: null,
        nextRetryAt: null,
      );
      return false;
    }

    final attempt = resetAttempt ? 0 : state.reconnectAttempt;

    // Only check limit if not in unlimited retry mode
    if (_maxReconnectAttempts > 0 && attempt >= _maxReconnectAttempts) {
      state = state.copyWith(
        isReconnecting: false,
        error: 'Max reconnect attempts reached',
      );
      if (pendingCompleter != null && !pendingCompleter.isCompleted) {
        pendingCompleter.complete(false);
      }
      return false;
    }

    final completer = pendingCompleter ?? Completer<bool>();
    final delayMs = immediate ? 0 : _calculateDelay(attempt);
    final nextRetry = delayMs > 0
        ? DateTime.now().add(Duration(milliseconds: delayMs))
        : null;

    state = state.copyWith(
      isReconnecting: true,
      isPaused: false,
      reconnectAttempt: attempt + 1,
      reconnectDelayMs: delayMs > 0 ? delayMs : null,
      nextRetryAt: nextRetry,
    );

    final generation = _reconnectGeneration;

    if (delayMs == 0) {
      unawaited(_runReconnectAttempt(completer, generation));
      return completer.future;
    }

    _scheduledReconnectCompleter = completer;
    _reconnectTimer = Timer(Duration(milliseconds: delayMs), () {
      _reconnectTimer = null;
      final scheduledCompleter = _scheduledReconnectCompleter;
      _scheduledReconnectCompleter = null;
      unawaited(
        _runReconnectAttempt(scheduledCompleter ?? completer, generation),
      );
    });

    return completer.future;
  }

  Future<void> _runReconnectAttempt(
    Completer<bool> completer,
    int generation,
  ) async {
    final activeReconnectFuture = _activeReconnectFuture;
    if (activeReconnectFuture != null) {
      final result = await activeReconnectFuture;
      if (!completer.isCompleted) {
        completer.complete(result);
      }
      return;
    }

    if (generation != _reconnectGeneration) {
      if (!completer.isCompleted) {
        completer.complete(false);
      }
      return;
    }

    final reconnectFuture = _doReconnect(generation);
    _activeReconnectFuture = reconnectFuture;
    final result = await reconnectFuture;
    if (identical(_activeReconnectFuture, reconnectFuture)) {
      _activeReconnectFuture = null;
    }

    if (generation != _reconnectGeneration) {
      if (!completer.isCompleted) {
        completer.complete(false);
      }
      return;
    }

    if (!completer.isCompleted) {
      completer.complete(result);
    }

    if (!result &&
        state.isNetworkAvailable &&
        _canRetry(state.reconnectAttempt)) {
      unawaited(_requestReconnect(immediate: false, resetAttempt: false));
    }
  }

  /// Actual reconnection process
  Future<bool> _doReconnect(int generation) async {
    if (_lastConnection == null || _lastOptions == null) {
      return false;
    }

    // Abort if network is offline
    if (!state.isNetworkAvailable) {
      state = state.copyWith(
        isPaused: true,
        reconnectDelayMs: null,
        nextRetryAt: null,
      );
      return false;
    }

    SshClient? nextClient;
    try {
      // Cancel existing connection state monitoring
      await _connectionStateSubscription?.cancel();
      _connectionStateSubscription = null;

      // Clean up old client
      final previousClient = _client;
      _client = null;
      await previousClient?.dispose();
      nextClient = _createClient();

      // Build non-interactive verifier for reconnection (no UI context)
      final knownHostsNotifier = ref.read(knownHostsProvider.notifier);
      final reconnectOptions = _lastOptions!.copyWith(
        onVerifyHostKey: knownHostsNotifier.buildNonInteractiveVerifier(
          _lastConnection!.host,
          _lastConnection!.port,
        ),
      );

      await nextClient.connect(
        host: _lastConnection!.host,
        port: _lastConnection!.port,
        username: _lastConnection!.username,
        options: reconnectOptions,
      );

      if (generation != _reconnectGeneration) {
        await nextClient.dispose();
        return false;
      }

      _client = nextClient;
      _connectionStateSubscription = _client!.connectionStateStream.listen(
        _onConnectionStateChanged,
      );

      state = state.copyWith(
        connectionState: SshConnectionState.connected,
        isReconnecting: false,
        isPaused: false,
        reconnectAttempt: 0,
        reconnectDelayMs: null,
        error: null,
        nextRetryAt: null,
      );

      // Reconnection success callback
      onReconnectSuccess?.call();

      return true;
    } catch (e) {
      await nextClient?.dispose();
      if (generation != _reconnectGeneration) {
        return false;
      }

      // Reconnection failed, let the coordinator schedule the next attempt
      state = state.copyWith(
        connectionState: SshConnectionState.error,
        error: 'Reconnect failed: $e',
        reconnectDelayMs: null,
        nextRetryAt: null,
      );

      return false;
    }
  }

  /// Attempt reconnection immediately (for user-initiated action)
  Future<bool> reconnectNow() async {
    return _requestReconnect(immediate: true, resetAttempt: true);
  }

  /// Check if connection is active
  bool checkConnection() {
    return _client != null && _client!.isConnected;
  }

  /// Reset reconnection state
  void resetReconnect() {
    _reconnectGeneration++;
    _cancelReconnectFlow(completePending: true);
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
    _reconnectGeneration++;
    _cancelReconnectFlow(completePending: true);

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
      reconnectDelayMs: null,
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
