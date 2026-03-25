import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';

import '../../utils/async_utils.dart';
import '../terminal/terminal_image_attachment.dart';
import 'ssh_lifecycle.dart';
import 'persistent_shell.dart';

/// SSH connection error
class SshConnectionError implements Exception {
  final String message;
  final Object? cause;

  SshConnectionError(this.message, [this.cause]);

  @override
  String toString() =>
      'SshConnectionError: $message${cause != null ? ' ($cause)' : ''}';
}

/// SSH authentication error
class SshAuthenticationError implements Exception {
  final String message;
  final Object? cause;

  SshAuthenticationError(this.message, [this.cause]);

  @override
  String toString() =>
      'SshAuthenticationError: $message${cause != null ? ' ($cause)' : ''}';
}

/// SSH host key verification failed or rejected by user
class SshHostKeyError implements Exception {
  final String message;

  SshHostKeyError(this.message);

  @override
  String toString() => 'SshHostKeyError: $message';
}

/// Callback type for SSH host key verification (matches dartssh2 signature).
typedef HostKeyVerifyCallback =
    FutureOr<bool> Function(String type, Uint8List fingerprint);

/// SSH connection options
class SshConnectOptions {
  /// Password for password authentication
  final String? password;

  /// Private key for key authentication (PEM format)
  final String? privateKey;

  /// Passphrase for the private key
  final String? passphrase;

  /// User-specified tmux path (auto-detected if null)
  final String? tmuxPath;

  /// Connection timeout (seconds)
  final int timeout;

  /// Host key verification callback (TOFU).
  /// If null, all host keys are accepted (insecure).
  final HostKeyVerifyCallback? onVerifyHostKey;

  const SshConnectOptions({
    this.password,
    this.privateKey,
    this.passphrase,
    this.tmuxPath,
    this.timeout = 30,
    this.onVerifyHostKey,
  });

  SshConnectOptions copyWith({
    String? password,
    String? privateKey,
    String? passphrase,
    String? tmuxPath,
    int? timeout,
    HostKeyVerifyCallback? onVerifyHostKey,
  }) {
    return SshConnectOptions(
      password: password ?? this.password,
      privateKey: privateKey ?? this.privateKey,
      passphrase: passphrase ?? this.passphrase,
      tmuxPath: tmuxPath ?? this.tmuxPath,
      timeout: timeout ?? this.timeout,
      onVerifyHostKey: onVerifyHostKey ?? this.onVerifyHostKey,
    );
  }
}

/// Shell options
class ShellOptions {
  /// Terminal type
  final String term;

  /// Number of columns
  final int cols;

  /// Number of rows
  final int rows;

  const ShellOptions({
    this.term = 'xterm-256color',
    this.cols = 80,
    this.rows = 24,
  });
}

/// SSH connection events
class SshEvents {
  /// On data received
  final void Function(Uint8List data)? onData;

  /// On connection closed
  final void Function()? onClose;

  /// On error occurred
  final void Function(Object error)? onError;

  const SshEvents({this.onData, this.onClose, this.onError});

  SshEvents copyWith({
    void Function(Uint8List data)? onData,
    void Function()? onClose,
    void Function(Object error)? onError,
  }) {
    return SshEvents(
      onData: onData ?? this.onData,
      onClose: onClose ?? this.onClose,
      onError: onError ?? this.onError,
    );
  }
}

/// SSH connection state
enum SshConnectionState { disconnected, connecting, connected, error }

/// SSH client
///
/// Wraps dartssh2 and manages SSH connections.
class SshClient {
  static final RegExp _safeTmuxPathPattern = RegExp(r'^/[A-Za-z0-9._/-]+$');
  static final RegExp _tmuxWordPattern = RegExp(r'(^|[\s;|&(])tmux(?=\s)', multiLine: true);

  SSHClient? _client;
  SSHSession? _session;
  SSHSession? _streamingShellSession;
  SSHSocket? _socket;

  SshConnectionState _state = SshConnectionState.disconnected;
  SshEvents _events = const SshEvents();
  String? _lastError;
  bool _isDisposed = false;

  StreamSubscription<Uint8List>? _stdoutSubscription;
  StreamSubscription<Uint8List>? _stderrSubscription;
  StreamSubscription<Uint8List>? _streamingShellStdoutSubscription;
  StreamSubscription<Uint8List>? _streamingShellStderrSubscription;

  /// Persistent shell used for serialized control commands and polling.
  PersistentShell? _controlShell;

  /// Dedicated persistent shell for terminal input writes.
  PersistentShell? _inputShell;

  void Function(Uint8List data)? _streamingShellOnData;
  void Function()? _streamingShellOnDone;
  void Function(Object error)? _streamingShellOnError;

  /// Detected absolute path of the tmux binary
  String? _tmuxPath;

  int _receivedPayloadBytes = 0;
  int _sentPayloadBytes = 0;
  int _lastKeepAliveLatencyMs = 0;
  DateTime? _lastKeepAliveLatencyAt;

  /// Lock for exclusive access to exec channel
  Completer<void>? _execLock;

  /// Absolute path of tmux (null if not detected)
  String? get tmuxPath => _tmuxPath;

  int get receivedPayloadBytes => _receivedPayloadBytes;

  int get sentPayloadBytes => _sentPayloadBytes;

  int get totalPayloadBytes => _receivedPayloadBytes + _sentPayloadBytes;

  int get lastKeepAliveLatencyMs => _lastKeepAliveLatencyMs;

  DateTime? get lastKeepAliveLatencyAt => _lastKeepAliveLatencyAt;

  /// Keep-alive timer
  Timer? _keepAliveTimer;

  final _cleanupCoordinator = AsyncCleanupCoordinator();

  /// StreamController for connection monitoring
  final _connectionStateController =
      StreamController<SshConnectionState>.broadcast();

  /// Stream of connection state (for external monitoring)
  Stream<SshConnectionState> get connectionStateStream =>
      _connectionStateController.stream;

  /// Keep-alive minimum interval (seconds)
  static const int _minKeepAliveIntervalSeconds = 5;

  /// Keep-alive maximum interval (seconds)
  static const int _maxKeepAliveIntervalSeconds = 30;

  /// Keep-alive timeout (seconds) - configurable, default 10 seconds
  int keepAliveTimeoutSeconds = 10;

  /// Current keep-alive interval (dynamically adjusted)
  int _currentKeepAliveIntervalSeconds = 10;

  /// Consecutive keep-alive success count
  int _keepAliveSuccessCount = 0;

  /// Whether the client is in background mode (reduced keep-alive frequency)
  bool _isInBackgroundMode = false;

  /// Background keep-alive interval in seconds (configurable)
  int backgroundKeepAliveIntervalSeconds = 120;

  /// Minimum keep-alive interval for background mode
  static const int _minBackgroundKeepAliveIntervalSeconds = 60;

  /// Current connection state
  SshConnectionState get state => _state;

  /// Whether currently connected
  bool get isConnected => _state == SshConnectionState.connected;

  /// Whether the dedicated streaming shell is active.
  bool get isStreamingShellActive => _streamingShellSession != null;

  /// Last error message
  String? get lastError => _lastError;

  /// Establish an SSH connection
  ///
  /// [host] Hostname or IP address
  /// [port] Port number
  /// [username] Username
  /// [options] Connection options (authentication info, etc.)
  Future<void> connect({
    required String host,
    required int port,
    required String username,
    required SshConnectOptions options,
  }) async {
    if (_isDisposed) {
      throw SshConnectionError('Client has been disposed');
    }

    // Validation
    _validateConnectionParams(host, port, username, options);

    _state = SshConnectionState.connecting;
    _lastError = null;
    _resetConnectionStats();

    try {
      // Socket connection
      _socket = await SSHSocket.connect(
        host,
        port,
        timeout: Duration(seconds: options.timeout),
      );

      // Create client according to authentication method
      if (options.privateKey != null) {
        // Key authentication
        _client = SSHClient(
          _socket!,
          username: username,
          identities: _parsePrivateKey(options.privateKey!, options.passphrase),
          onAuthenticated: _onAuthenticated,
          onVerifyHostKey: options.onVerifyHostKey,
        );
      } else if (options.password != null) {
        // Password authentication
        _client = SSHClient(
          _socket!,
          username: username,
          onPasswordRequest: () => options.password!,
          onAuthenticated: _onAuthenticated,
          onVerifyHostKey: options.onVerifyHostKey,
        );
      } else {
        throw SshAuthenticationError('No authentication method provided');
      }

      // Wait for authentication to complete
      await _client!.authenticated;

      _state = SshConnectionState.connected;
      _connectionStateController.add(_state);

      // Detect tmux path (use user-specified path if provided, otherwise auto-detect)
      final sanitizedTmuxPath = _sanitizeTmuxPath(options.tmuxPath);
      if (sanitizedTmuxPath != null) {
        // Verify user-specified path exists
        final verifyExitCode = await _withExecLock(() async {
          final command = 'test -x $sanitizedTmuxPath';
          _recordSentBytes(utf8.encode(command).length);
          final session = await _client!.execute(command);
          await session.stdout.forEach((data) {
            _recordReceivedBytes(data.length);
          });
          await session.stderr.forEach((data) {
            _recordReceivedBytes(data.length);
          });
          final code = session.exitCode;
          session.close();
          return code;
        });
        if (verifyExitCode == 0) {
          _tmuxPath = sanitizedTmuxPath;
        }
      } else {
        await _detectTmuxPath();
      }

      // Start persistent shell (for polling)
      await _startPersistentShell();

      // Start keep-alive
      _startKeepAlive();
    } on SocketException catch (e) {
      _state = SshConnectionState.error;
      _lastError = 'Connection failed: ${e.message}';
      await _cleanup();
      throw SshConnectionError(_lastError!, e);
    } on SSHHostkeyError {
      _state = SshConnectionState.error;
      _lastError = 'Host key verification failed';
      await _cleanup();
      throw SshHostKeyError(_lastError!);
    } on SshHostKeyError {
      _state = SshConnectionState.error;
      await _cleanup();
      rethrow;
    } on SSHAuthFailError catch (e) {
      _state = SshConnectionState.error;
      _lastError = 'Authentication failed: ${e.message}';
      await _cleanup();
      throw SshAuthenticationError(_lastError!, e);
    } catch (e) {
      _state = SshConnectionState.error;
      _lastError = 'Connection failed: $e';
      await _cleanup();
      throw SshConnectionError(_lastError!, e);
    }
  }

  /// Validate connection parameters
  void _validateConnectionParams(
    String host,
    int port,
    String username,
    SshConnectOptions options,
  ) {
    if (host.trim().isEmpty) {
      throw SshConnectionError('Host is required');
    }
    if (username.trim().isEmpty) {
      throw SshConnectionError('Username is required');
    }
    if (port < 1 || port > 65535) {
      throw SshConnectionError('Invalid port number: $port');
    }
    if (options.password == null && options.privateKey == null) {
      throw SshAuthenticationError(
        'Either password or privateKey must be provided',
      );
    }
  }

  /// Parse private key
  List<SSHKeyPair> _parsePrivateKey(String privateKey, String? passphrase) {
    try {
      // SSHKeyPair.fromPem returns List<SSHKeyPair>
      final keyPairs = SSHKeyPair.fromPem(privateKey, passphrase);
      if (keyPairs.isEmpty) {
        throw SshAuthenticationError('No valid key found in PEM data');
      }
      return keyPairs;
    } on FormatException catch (e) {
      throw SshAuthenticationError('Invalid private key format: ${e.message}');
    } catch (e) {
      if (e is SshAuthenticationError) rethrow;
      if (passphrase == null && privateKey.contains('ENCRYPTED')) {
        throw SshAuthenticationError(
          'Private key is encrypted, passphrase required',
        );
      }
      throw SshAuthenticationError('Failed to parse private key: $e');
    }
  }

  /// Authentication completed callback
  void _onAuthenticated() {
    // Authentication successful
  }

  /// Disconnect the connection
  Future<void> disconnect() async {
    await _cleanup();
    _updateState(SshConnectionState.disconnected);
    _events.onClose?.call();
  }

  /// Update state and notify via stream
  void _updateState(SshConnectionState newState) {
    if (_state != newState) {
      _state = newState;
      _connectionStateController.add(newState);
    }
  }

  /// Clean up resources
  Future<void> _cleanup() async {
    await _cleanupCoordinator.run(() async {
      // Stop keep-alive
      _stopKeepAlive();
      _resetConnectionStats();

      final controlShell = _controlShell;
      final inputShell = _inputShell;
      final stdoutSubscription = _stdoutSubscription;
      final stderrSubscription = _stderrSubscription;
      final session = _session;
      final client = _client;
      final socket = _socket;

      _controlShell = null;
      _inputShell = null;
      _stdoutSubscription = null;
      _stderrSubscription = null;
      _session = null;
      _client = null;
      _socket = null;
      _tmuxPath = null;

      await _disposeQuietly(controlShell?.dispose);
      await _disposeQuietly(inputShell?.dispose);
      await _disposeQuietly(stopStreamingShell);
      await _disposeQuietly(stdoutSubscription?.cancel);
      await _disposeQuietly(stderrSubscription?.cancel);
      _closeQuietly(session?.close);
      _closeQuietly(client?.close);
      _closeQuietly(socket?.close);
    });
  }

  /// Start persistent shell
  Future<void> _startPersistentShell() async {
    if (_client == null) return;

    _controlShell = await _startPersistentShellInstance();
    _inputShell = await _startPersistentShellInstance();
  }

  /// Restart persistent shell
  Future<void> restartPersistentShell({
    bool restartControlShell = true,
    bool restartInputShell = true,
  }) async {
    if (_client == null || !isConnected) return;

    if (restartControlShell) {
      _controlShell = await _restartPersistentShellInstance(_controlShell);
    }

    if (restartInputShell) {
      _inputShell = await _restartPersistentShellInstance(_inputShell);
    }
  }

  Future<PersistentShell?> _restartPersistentShellInstance(
    PersistentShell? shell,
  ) async {
    if (_client == null || !isConnected) {
      return null;
    }

    await _disposeQuietly(shell?.dispose);
    return _startPersistentShellInstance();
  }

  /// Use the exec channel exclusively
  Future<T> _withExecLock<T>(Future<T> Function() fn) async {
    while (_execLock != null) {
      await _execLock!.future;
    }
    final completer = Completer<void>();
    _execLock = completer;
    try {
      return await fn();
    } finally {
      _execLock = null;
      completer.complete();
    }
  }

  /// Detect the absolute path of tmux via exec channel
  ///
  /// Step 1: Execute `command -v tmux` via login shell
  /// Step 2: On failure, fall back to `test -x` with known candidate paths
  Future<void> _detectTmuxPath() async {
    if (_client == null || !isConnected) return;

    // Step 1: Detect via login shell
    try {
      final path = await _withExecLock(() async {
        const command = r"$SHELL -lc 'command -v tmux'";
        _recordSentBytes(utf8.encode(command).length);
        final session = await _client!.execute(command);
        final stdoutBytes = <int>[];
        await session.stdout.forEach((data) {
          _recordReceivedBytes(data.length);
          stdoutBytes.addAll(data);
        });
        await session.stderr.forEach((data) {
          _recordReceivedBytes(data.length);
        });
        session.close();
        return utf8.decode(stdoutBytes, allowMalformed: true).trim();
      });
      final sanitizedPath = _sanitizeTmuxPath(path);
      if (sanitizedPath != null) {
        _tmuxPath = sanitizedPath;
        return;
      }
    } catch (e) {
      // Fall back to known tmux locations below.
      assert(() { debugPrint('SshClient._detectTmuxPath login shell: $e'); return true; }());
    }

    // Step 2: Fallback to known paths
    const candidates = [
      '/opt/homebrew/bin/tmux',
      '/usr/local/bin/tmux',
      '/usr/bin/tmux',
    ];

    for (final candidate in candidates) {
      try {
        final exitCode = await _withExecLock(() async {
          final command = 'test -x $candidate';
          _recordSentBytes(utf8.encode(command).length);
          final session = await _client!.execute(command);
          await session.stdout.forEach((data) {
            _recordReceivedBytes(data.length);
          });
          await session.stderr.forEach((data) {
            _recordReceivedBytes(data.length);
          });
          final code = session.exitCode;
          session.close();
          return code;
        });
        if (exitCode == 0) {
          _tmuxPath = candidate;
          return;
        }
      } catch (e) {
        // Try the next candidate path.
        assert(() { debugPrint('SshClient._detectTmuxPath candidate $candidate: $e'); return true; }());
      }
    }
  }

  /// Replace `tmux` in command with detected absolute path
  String _resolveTmuxCommand(String command) {
    if (_tmuxPath == null) return command;
    return command.replaceAllMapped(
      _tmuxWordPattern,
      (m) => '${m[1]}$_tmuxPath',
    );
  }

  /// Resolve `tmux` words in [command] using the given [tmuxPath].
  ///
  /// Exposed for unit testing the replacement logic without requiring
  /// a live SSH connection.
  @visibleForTesting
  static String resolveForTesting(String command, String tmuxPath) {
    return command.replaceAllMapped(
      _tmuxWordPattern,
      (m) => '${m[1]}$tmuxPath',
    );
  }

  @visibleForTesting
  static bool isSafeTmuxPath(String path) => _sanitizeTmuxPath(path) != null;

  static String? _sanitizeTmuxPath(String? path) {
    final trimmed = path?.trim();
    if (trimmed == null || trimmed.isEmpty) {
      return null;
    }
    if (!_safeTmuxPathPattern.hasMatch(trimmed)) {
      return null;
    }
    return trimmed;
  }

  /// Switch between background mode (slow keep-alive) and foreground mode.
  void setBackgroundMode(bool isBackground) {
    if (_isInBackgroundMode == isBackground) return;
    _isInBackgroundMode = isBackground;

    if (!isConnected || _keepAliveTimer == null) return;

    if (isBackground) {
      _currentKeepAliveIntervalSeconds = backgroundKeepAliveIntervalSeconds;
    } else {
      _currentKeepAliveIntervalSeconds = _minKeepAliveIntervalSeconds;
    }
    _keepAliveSuccessCount = 0;
    _scheduleNextKeepAlive();
  }

  /// Start keep-alive
  ///
  /// Periodically executes a lightweight command to verify the connection is alive.
  /// Immediately transitions to error state if the connection is lost.
  /// The interval is dynamically adjusted (extended on success, shortened on failure).
  void _startKeepAlive() {
    if (_isDisposed || !isConnected || _client == null) {
      return;
    }
    _stopKeepAlive();
    _currentKeepAliveIntervalSeconds = _isInBackgroundMode
        ? backgroundKeepAliveIntervalSeconds
        : 10; // Foreground initial value: 10 seconds
    _keepAliveSuccessCount = 0;
    _scheduleNextKeepAlive();
  }

  Future<PersistentShell?> _startPersistentShellInstance() async {
    final client = _client;
    if (client == null) {
      return null;
    }

    return startOptionalAsyncResource(
      create: () => PersistentShell(
        client,
        onBytesReceived: _recordReceivedBytes,
        onBytesSent: _recordSentBytes,
      ),
      start: (shell) => shell.start(),
      disposeOnFailure: (shell) => shell.dispose(),
    );
  }

  Future<void> _disposeQuietly(Future<void> Function()? cleanup) async {
    if (cleanup == null) {
      return;
    }
    try {
      await cleanup();
    } catch (e) {
      // Ignore cleanup races for partially-initialized resources.
      assert(() { debugPrint('SshClient._disposeQuietly: $e'); return true; }());
    }
  }

  void _closeQuietly(void Function()? close) {
    if (close == null) {
      return;
    }
    try {
      close();
    } catch (e) {
      // Ignore cleanup races for partially-initialized resources.
      assert(() { debugPrint('SshClient._closeQuietly: $e'); return true; }());
    }
  }

  /// Schedule the next keep-alive
  void _scheduleNextKeepAlive() {
    _keepAliveTimer?.cancel();
    _keepAliveTimer = Timer(
      Duration(seconds: _currentKeepAliveIntervalSeconds),
      () async {
        await _sendKeepAlive();
        if (isConnected) {
          _scheduleNextKeepAlive();
        }
      },
    );
  }

  /// Stop keep-alive
  void _stopKeepAlive() {
    _keepAliveTimer?.cancel();
    _keepAliveTimer = null;
  }

  /// Adjust keep-alive interval
  void _adjustKeepAliveInterval({required bool success}) {
    final minInterval = _isInBackgroundMode
        ? _minBackgroundKeepAliveIntervalSeconds
        : _minKeepAliveIntervalSeconds;
    final maxInterval = _isInBackgroundMode
        ? backgroundKeepAliveIntervalSeconds
        : _maxKeepAliveIntervalSeconds;

    if (success) {
      _keepAliveSuccessCount++;
      // Extend interval after 3 consecutive successes
      if (_keepAliveSuccessCount >= 3) {
        _currentKeepAliveIntervalSeconds =
            (_currentKeepAliveIntervalSeconds + 5).clamp(
              minInterval,
              maxInterval,
            );
        _keepAliveSuccessCount = 0;
      }
    } else {
      // Reset to minimum interval on failure
      _currentKeepAliveIntervalSeconds = minInterval;
      _keepAliveSuccessCount = 0;
    }
  }

  /// Send keep-alive packet
  Future<void> _sendKeepAlive() async {
    if (!isConnected || _client == null) {
      return;
    }

    try {
      final startTime = DateTime.now();
      // Keep-alive via persistent shell (fast)
      await execPersistent(
        'echo ping',
        timeout: Duration(seconds: keepAliveTimeoutSeconds),
      );
      _recordKeepAliveLatency(
        DateTime.now().difference(startTime).inMilliseconds,
      );
      _adjustKeepAliveInterval(success: true);
    } catch (e) {
      _adjustKeepAliveInterval(success: false);
      // Keep-alive failure = connection lost
      _lastError = 'Connection lost: $e';
      _updateState(SshConnectionState.error);
      _events.onError?.call(SshConnectionError(_lastError!));
      _events.onClose?.call();
    }
  }

  /// Start an interactive shell
  ///
  /// [options] Shell options
  Future<void> startShell([ShellOptions options = const ShellOptions()]) async {
    if (_isDisposed) {
      throw SshConnectionError('Client has been disposed');
    }
    if (!isConnected || _client == null) {
      throw SshConnectionError('Not connected');
    }

    try {
      _session = await _client!.shell(
        pty: SSHPtyConfig(
          type: options.term,
          width: options.cols,
          height: options.rows,
        ),
      );

      // Set up stdout/stderr listeners
      _stdoutSubscription = _session!.stdout.listen(
        (data) {
          _recordReceivedBytes(data.length);
          _handleData(data);
        },
        onError: _handleError,
        onDone: _handleDone,
      );

      _stderrSubscription = _session!.stderr.listen((data) {
        _recordReceivedBytes(data.length);
        _handleData(data);
      }, onError: _handleError);
    } catch (e) {
      // Clean up any partially created subscriptions
      await _stdoutSubscription?.cancel();
      _stdoutSubscription = null;
      await _stderrSubscription?.cancel();
      _stderrSubscription = null;
      _session?.close();
      _session = null;
      throw SshConnectionError('Failed to start shell: $e', e);
    }
  }

  /// Start a dedicated long-lived streaming shell session.
  ///
  /// This is used for tmux control-mode or other live transports and stays
  /// separate from both the legacy shell session and the persistent exec shells.
  Future<void> startStreamingShell({
    required String startupCommand,
    required void Function(Uint8List data) onData,
    void Function()? onDone,
    void Function(Object error)? onError,
    ShellOptions options = const ShellOptions(
      term: 'dumb',
      cols: 200,
      rows: 50,
    ),
  }) async {
    if (_isDisposed) {
      throw SshConnectionError('Client has been disposed');
    }
    if (!isConnected || _client == null) {
      throw SshConnectionError('Not connected');
    }

    await stopStreamingShell();

    _streamingShellOnData = onData;
    _streamingShellOnDone = onDone;
    _streamingShellOnError = onError;

    try {
      _streamingShellSession = await _client!.shell(
        pty: SSHPtyConfig(
          type: options.term,
          width: options.cols,
          height: options.rows,
        ),
      );

      _streamingShellStdoutSubscription = _streamingShellSession!.stdout.listen(
        (data) {
          _recordReceivedBytes(data.length);
          _handleStreamingShellData(data);
        },
        onError: _handleStreamingShellError,
        onDone: _handleStreamingShellDone,
      );

      _streamingShellStderrSubscription = _streamingShellSession!.stderr.listen(
        (data) {
          _recordReceivedBytes(data.length);
          _handleStreamingShellData(data);
        },
        onError: _handleStreamingShellError,
      );

      final command = startupCommand.endsWith('\n')
          ? startupCommand
          : '$startupCommand\n';
      final commandBytes = utf8.encode(command);
      _recordSentBytes(commandBytes.length);
      _streamingShellSession!.write(commandBytes);
    } catch (e) {
      await stopStreamingShell();
      throw SshConnectionError('Failed to start streaming shell: $e', e);
    }
  }

  /// Data reception handler
  void _handleData(Uint8List data) {
    _events.onData?.call(data);
  }

  /// Error handler
  void _handleError(Object error) {
    _lastError = error.toString();
    _events.onError?.call(error);
  }

  /// Completion handler
  void _handleDone() {
    _state = SshConnectionState.disconnected;
    _events.onClose?.call();
  }

  /// Write data to the shell
  ///
  /// [data] Data to send (string)
  void write(String data) {
    if (_isDisposed || !isConnected || _session == null) {
      throw SshConnectionError('Not connected or shell not started');
    }
    final encoded = utf8.encode(data);
    _recordSentBytes(encoded.length);
    _session!.write(encoded);
  }

  /// Write byte data to the shell
  ///
  /// [data] Data to send (bytes)
  void writeBytes(Uint8List data) {
    if (_isDisposed || !isConnected || _session == null) {
      throw SshConnectionError('Not connected or shell not started');
    }
    _recordSentBytes(data.length);
    _session!.write(data);
  }

  /// Write text data to the dedicated streaming shell.
  void writeStreamingShell(String data) {
    if (_isDisposed || !isConnected || _streamingShellSession == null) {
      throw SshConnectionError('Streaming shell not started');
    }
    final encoded = utf8.encode(data);
    _recordSentBytes(encoded.length);
    _streamingShellSession!.write(encoded);
  }

  /// Stop the dedicated streaming shell without disconnecting SSH.
  Future<void> stopStreamingShell() async {
    final stdoutSubscription = _streamingShellStdoutSubscription;
    final stderrSubscription = _streamingShellStderrSubscription;
    final session = _streamingShellSession;

    _streamingShellStdoutSubscription = null;
    _streamingShellStderrSubscription = null;
    _streamingShellSession = null;
    _streamingShellOnData = null;
    _streamingShellOnDone = null;
    _streamingShellOnError = null;

    await stdoutSubscription?.cancel();
    await stderrSubscription?.cancel();
    try {
      session?.close();
    } catch (e) {
      // Ignore races with remote shutdown.
      assert(() { debugPrint('SshClient.stopStreamingShell: $e'); return true; }());
    }
  }

  /// Resize the terminal
  ///
  /// [cols] Number of columns
  /// [rows] Number of rows
  void resize(int cols, int rows) {
    if (_session == null) {
      return; // Do nothing if the shell has not been started
    }

    try {
      _session!.resizeTerminal(cols, rows);
    } catch (e) {
      // Resize error is warning only (not fatal)
      _lastError = 'Failed to resize: $e';
    }
  }

  void _handleStreamingShellData(Uint8List data) {
    _streamingShellOnData?.call(data);
  }

  void _handleStreamingShellError(Object error) {
    _streamingShellOnError?.call(error);
  }

  void _handleStreamingShellDone() {
    final onDone = _streamingShellOnDone;
    final stdoutSubscription = _streamingShellStdoutSubscription;
    final stderrSubscription = _streamingShellStderrSubscription;

    _streamingShellStdoutSubscription = null;
    _streamingShellStderrSubscription = null;
    _streamingShellSession = null;
    _streamingShellOnData = null;
    _streamingShellOnDone = null;
    _streamingShellOnError = null;

    fireAndForget(
      stdoutSubscription?.cancel() ?? Future<void>.value(),
      debugLabel: 'SshClient streaming shell stdout cancel',
    );
    fireAndForget(
      stderrSubscription?.cancel() ?? Future<void>.value(),
      debugLabel: 'SshClient streaming shell stderr cancel',
    );

    onDone?.call();
  }

  /// Execute a command and get the result
  ///
  /// [command] Command to execute
  /// [timeout] Timeout duration
  /// Returns: Command output
  Future<String> exec(String command, {Duration? timeout}) async {
    if (_isDisposed || !isConnected || _client == null) {
      throw SshConnectionError('Not connected');
    }

    try {
      final resolvedCommand = _resolveTmuxCommand(command);
      return await _withExecLock(() async {
        _recordSentBytes(utf8.encode(resolvedCommand).length);
        final session = await _client!.execute(resolvedCommand);

        // Collect output (collect as byte sequence and decode at the end)
        final stdoutBytes = <int>[];
        final stderrBytes = <int>[];

        final stdoutCompleter = Completer<void>();
        final stderrCompleter = Completer<void>();

        session.stdout.listen(
          (data) {
            _recordReceivedBytes(data.length);
            stdoutBytes.addAll(data);
          },
          onDone: () => stdoutCompleter.complete(),
          onError: (e) => stdoutCompleter.completeError(e),
        );

        session.stderr.listen(
          (data) {
            _recordReceivedBytes(data.length);
            stderrBytes.addAll(data);
          },
          onDone: () => stderrCompleter.complete(),
          onError: (e) => stderrCompleter.completeError(e),
        );

        // Wait for completion with timeout
        if (timeout != null) {
          await Future.wait([
            stdoutCompleter.future,
            stderrCompleter.future,
          ]).timeout(timeout);
        } else {
          await Future.wait([stdoutCompleter.future, stderrCompleter.future]);
        }

        session.close();

        // Decode byte sequence as UTF-8 (invalid bytes become replacement characters)
        final stdout = utf8.decode(stdoutBytes, allowMalformed: true);
        final stderr = utf8.decode(stderrBytes, allowMalformed: true);
        return stderr.isNotEmpty ? stdout + stderr : stdout;
      });
    } on TimeoutException {
      throw SshConnectionError('Command execution timed out');
    } catch (e) {
      throw SshConnectionError('Failed to execute command: $e', e);
    }
  }

  /// Execute command via persistent shell (fast)
  ///
  /// Eliminates channel open/close overhead, enabling execution in about 1 RTT.
  /// Suitable for high-frequency command execution such as polling.
  ///
  /// [command] Command to execute
  /// [timeout] Timeout duration
  /// Returns: Command output
  Future<String> execPersistent(String command, {Duration? timeout}) async {
    if (_isDisposed || !isConnected || _client == null) {
      throw SshConnectionError('Not connected');
    }

    final resolvedCommand = _resolveTmuxCommand(command);

    // Fall back to traditional exec() if persistent shell is unavailable
    if (_controlShell == null || !_controlShell!.isStarted) {
      return exec(resolvedCommand, timeout: timeout);
    }

    try {
      return await _controlShell!.exec(resolvedCommand, timeout: timeout);
    } on PersistentShellError catch (e) {
      // Attempt restart if shell session has been disconnected
      if (e.message.contains('closed') || e.message.contains('disposed')) {
        try {
          await restartPersistentShell(restartInputShell: false);
          if (_controlShell != null && _controlShell!.isStarted) {
            return await _controlShell!.exec(resolvedCommand, timeout: timeout);
          }
        } catch (e) {
          // Fall back to traditional exec() if restart also fails
          if (kDebugMode) {
            debugPrint('[SshClient] control shell restart failed: $e');
          }
          return exec(resolvedCommand, timeout: timeout);
        }
      }
      // Fall back to traditional exec() for other errors
      return exec(resolvedCommand, timeout: timeout);
    }
  }

  /// Execute a command through a dedicated non-PTY exec session.
  ///
  /// This bypasses the marker-delimited persistent shell and is preferred for
  /// snapshot-style commands that can return large ANSI payloads. It avoids the
  /// persistent shell's PTY/marker transport and preserves the raw command
  /// output as closely as possible.
  Future<String> execDirect(String command, {Duration? timeout}) {
    return exec(command, timeout: timeout);
  }

  /// Execute a command via the dedicated input shell.
  ///
  /// Used by the terminal screen to avoid contention with polling and control
  /// commands on the primary persistent shell.
  Future<String> execPersistentInput(
    String command, {
    Duration? timeout,
  }) async {
    if (_isDisposed || !isConnected || _client == null) {
      throw SshConnectionError('Not connected');
    }

    final resolvedCommand = _resolveTmuxCommand(command);

    if (_inputShell == null || !_inputShell!.isStarted) {
      return execPersistent(resolvedCommand, timeout: timeout);
    }

    try {
      return await _inputShell!.exec(resolvedCommand, timeout: timeout);
    } on PersistentShellError catch (e) {
      if (e.message.contains('closed') || e.message.contains('disposed')) {
        try {
          await restartPersistentShell(restartControlShell: false);
          if (_inputShell != null && _inputShell!.isStarted) {
            return await _inputShell!.exec(resolvedCommand, timeout: timeout);
          }
        } catch (e) {
          if (kDebugMode) {
            debugPrint('[SshClient] input shell restart failed: $e');
          }
          return execPersistent(resolvedCommand, timeout: timeout);
        }
      }
      return execPersistent(resolvedCommand, timeout: timeout);
    }
  }

  /// Resolve the remote home directory for the connected SSH user.
  Future<String> resolveRemoteHomeDirectory() async {
    if (_isDisposed || !isConnected || _client == null) {
      throw SshConnectionError('Not connected');
    }

    try {
      return await _withSftpClient((sftp) async {
        final resolved = (await sftp.absolute('.')).trim();
        if (resolved.isEmpty) {
          throw SshConnectionError('Failed to resolve remote home directory');
        }
        return resolved;
      });
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[SshClient] SFTP home resolution failed, falling back: $e');
      }
      final resolved = await execPersistent(
        r'printf %s "$HOME"',
        timeout: const Duration(seconds: 2),
      );
      final trimmed = resolved.trim();
      if (trimmed.isEmpty) {
        throw SshConnectionError('Failed to resolve remote home directory');
      }
      return trimmed;
    }
  }

  /// Upload an image attachment to a stable remote location and return its
  /// absolute remote path.
  Future<String> uploadTerminalImageAttachment(
    Uint8List bytes, {
    String? originalFilename,
  }) async {
    if (_isDisposed || !isConnected || _client == null) {
      throw SshConnectionError('Not connected');
    }
    if (bytes.isEmpty) {
      throw SshConnectionError('Image payload is empty');
    }

    final remoteHomeDirectory = await resolveRemoteHomeDirectory();
    final uploadTarget = TerminalImageUploadTarget.forHomeDirectory(
      remoteHomeDirectory,
      originalFilename: originalFilename,
    );

    await _withSftpClient((sftp) async {
      await _ensureSftpDirectory(sftp, uploadTarget.remoteDirectory);
      final file = await sftp.open(
        uploadTarget.remotePath,
        mode:
            SftpFileOpenMode.write |
            SftpFileOpenMode.create |
            SftpFileOpenMode.truncate,
      );
      try {
        await file.writeBytes(bytes);
      } finally {
        await file.close();
      }
    });

    _recordSentBytes(bytes.length);
    return uploadTarget.remotePath;
  }

  /// Execute a command and get the exit code
  ///
  /// [command] Command to execute
  /// Returns: (stdout, stderr, exitCode)
  Future<({String stdout, String stderr, int? exitCode})> execWithExitCode(
    String command, {
    Duration? timeout,
  }) async {
    if (_isDisposed || !isConnected || _client == null) {
      throw SshConnectionError('Not connected');
    }

    try {
      final resolvedCommand = _resolveTmuxCommand(command);
      return await _withExecLock(() async {
        _recordSentBytes(utf8.encode(resolvedCommand).length);
        final session = await _client!.execute(resolvedCommand);

        // Accumulate as byte sequence (prevents UTF-8 boundary splits from chunk-by-chunk decoding)
        final stdoutBytes = <int>[];
        final stderrBytes = <int>[];

        final stdoutCompleter = Completer<void>();
        final stderrCompleter = Completer<void>();

        session.stdout.listen(
          (data) {
            _recordReceivedBytes(data.length);
            stdoutBytes.addAll(data);
          },
          onDone: () => stdoutCompleter.complete(),
          onError: (e) => stdoutCompleter.completeError(e),
        );

        session.stderr.listen(
          (data) {
            _recordReceivedBytes(data.length);
            stderrBytes.addAll(data);
          },
          onDone: () => stderrCompleter.complete(),
          onError: (e) => stderrCompleter.completeError(e),
        );

        if (timeout != null) {
          await Future.wait([
            stdoutCompleter.future,
            stderrCompleter.future,
          ]).timeout(timeout);
        } else {
          await Future.wait([stdoutCompleter.future, stderrCompleter.future]);
        }

        final exitCode = session.exitCode;
        session.close();

        return (
          stdout: utf8.decode(stdoutBytes, allowMalformed: true),
          stderr: utf8.decode(stderrBytes, allowMalformed: true),
          exitCode: exitCode,
        );
      });
    } on TimeoutException {
      throw SshConnectionError('Command execution timed out');
    } catch (e) {
      throw SshConnectionError('Failed to execute command: $e', e);
    }
  }

  Future<T> _withSftpClient<T>(
    Future<T> Function(SftpClient sftp) action,
  ) async {
    if (_isDisposed || !isConnected || _client == null) {
      throw SshConnectionError('Not connected');
    }

    final sftp = await _client!.sftp();
    try {
      return await action(sftp);
    } finally {
      sftp.close();
    }
  }

  Future<void> _ensureSftpDirectory(SftpClient sftp, String path) async {
    if (path.isEmpty || path == '/') {
      return;
    }

    final isAbsolute = path.startsWith('/');
    var currentPath = isAbsolute ? '/' : '';
    final segments = path.split('/').where((segment) => segment.isNotEmpty);

    for (final segment in segments) {
      currentPath = currentPath == '/'
          ? '/$segment'
          : (currentPath.isEmpty ? segment : '$currentPath/$segment');

      try {
        final attrs = await sftp.stat(currentPath);
        if (!attrs.isDirectory) {
          throw SshConnectionError(
            'Remote upload directory is not a directory: $currentPath',
          );
        }
      } on SftpStatusError catch (error) {
        if (error.code != SftpStatusCode.noSuchFile) {
          rethrow;
        }
        await sftp.mkdir(currentPath);
      }
    }
  }

  /// Set event handlers
  void setEventHandlers(SshEvents events) {
    _events = events;
  }

  /// Update event handlers
  void updateEventHandlers({
    void Function(Uint8List data)? onData,
    void Function()? onClose,
    void Function(Object error)? onError,
  }) {
    _events = _events.copyWith(
      onData: onData,
      onClose: onClose,
      onError: onError,
    );
  }

  /// Release resources
  Future<void> dispose() async {
    if (_isDisposed) return;
    _isDisposed = true;
    await disconnect();
    await _connectionStateController.close();
  }

  void _resetConnectionStats() {
    _lastKeepAliveLatencyMs = 0;
    _lastKeepAliveLatencyAt = null;
    _resetPayloadCounters();
  }

  void _resetPayloadCounters() {
    _receivedPayloadBytes = 0;
    _sentPayloadBytes = 0;
  }

  void _recordKeepAliveLatency(int milliseconds) {
    if (milliseconds < 0) {
      return;
    }
    _lastKeepAliveLatencyMs = milliseconds;
    _lastKeepAliveLatencyAt = DateTime.now();
  }

  void _recordReceivedBytes(int bytes) {
    if (bytes <= 0) {
      return;
    }
    _receivedPayloadBytes += bytes;
  }

  void _recordSentBytes(int bytes) {
    if (bytes <= 0) {
      return;
    }
    _sentPayloadBytes += bytes;
  }

  @visibleForTesting
  void debugRecordPayloadBytes({int received = 0, int sent = 0}) {
    _recordReceivedBytes(received);
    _recordSentBytes(sent);
  }

  @visibleForTesting
  void debugRecordKeepAliveLatency(int milliseconds) {
    _recordKeepAliveLatency(milliseconds);
  }
}

/// Create an SSH client
SshClient createSshClient() {
  return SshClient();
}
