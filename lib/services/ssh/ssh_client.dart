import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';

import 'persistent_shell.dart';

/// SSH connection error
class SshConnectionError implements Exception {
  final String message;
  final Object? cause;

  SshConnectionError(this.message, [this.cause]);

  @override
  String toString() => 'SshConnectionError: $message${cause != null ? ' ($cause)' : ''}';
}

/// SSH authentication error
class SshAuthenticationError implements Exception {
  final String message;
  final Object? cause;

  SshAuthenticationError(this.message, [this.cause]);

  @override
  String toString() => 'SshAuthenticationError: $message${cause != null ? ' ($cause)' : ''}';
}

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

  const SshConnectOptions({
    this.password,
    this.privateKey,
    this.passphrase,
    this.tmuxPath,
    this.timeout = 30,
  });
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

  const SshEvents({
    this.onData,
    this.onClose,
    this.onError,
  });

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
enum SshConnectionState {
  disconnected,
  connecting,
  connected,
  error,
}

/// SSH client
///
/// Wraps dartssh2 and manages SSH connections.
class SshClient {
  SSHClient? _client;
  SSHSession? _session;
  SSHSocket? _socket;

  SshConnectionState _state = SshConnectionState.disconnected;
  SshEvents _events = const SshEvents();
  String? _lastError;
  bool _isDisposed = false;

  StreamSubscription<Uint8List>? _stdoutSubscription;
  StreamSubscription<Uint8List>? _stderrSubscription;

  /// Persistent shell session (for polling)
  PersistentShell? _persistentShell;

  /// Detected absolute path of the tmux binary
  String? _tmuxPath;

  /// Lock for exclusive access to exec channel
  Completer<void>? _execLock;

  /// Absolute path of tmux (null if not detected)
  String? get tmuxPath => _tmuxPath;

  /// Keep-alive timer
  Timer? _keepAliveTimer;

  /// StreamController for connection monitoring
  final _connectionStateController = StreamController<SshConnectionState>.broadcast();

  /// Stream of connection state (for external monitoring)
  Stream<SshConnectionState> get connectionStateStream => _connectionStateController.stream;

  /// Keep-alive minimum interval (seconds)
  static const int _minKeepAliveIntervalSeconds = 5;

  /// Keep-alive maximum interval (seconds)
  static const int _maxKeepAliveIntervalSeconds = 30;

  /// Keep-alive timeout (seconds) - reduced to 3 seconds for fast detection
  static const int _keepAliveTimeoutSeconds = 3;

  /// Current keep-alive interval (dynamically adjusted)
  int _currentKeepAliveIntervalSeconds = 10;

  /// Consecutive keep-alive success count
  int _keepAliveSuccessCount = 0;

  /// Current connection state
  SshConnectionState get state => _state;

  /// Whether currently connected
  bool get isConnected => _state == SshConnectionState.connected;

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
        );
      } else if (options.password != null) {
        // Password authentication
        _client = SSHClient(
          _socket!,
          username: username,
          onPasswordRequest: () => options.password!,
          onAuthenticated: _onAuthenticated,
        );
      } else {
        throw SshAuthenticationError('No authentication method provided');
      }

      // Wait for authentication to complete
      await _client!.authenticated;

      _state = SshConnectionState.connected;
      _connectionStateController.add(_state);

      // Detect tmux path (use user-specified path if provided, otherwise auto-detect)
      if (options.tmuxPath != null && options.tmuxPath!.isNotEmpty) {
        // Verify user-specified path exists
        final verifyExitCode = await _withExecLock(() async {
          final session = await _client!.execute('test -x ${options.tmuxPath}');
          await session.stdout.drain();
          await session.stderr.drain();
          final code = session.exitCode;
          session.close();
          return code;
        });
        if (verifyExitCode == 0) {
          _tmuxPath = options.tmuxPath;
          debugPrint('connect: user-specified tmux path verified: $_tmuxPath');
        } else {
          debugPrint('connect: user-specified tmux path not found: ${options.tmuxPath}');
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
        throw SshAuthenticationError('Private key is encrypted, passphrase required');
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
    // Stop keep-alive
    _stopKeepAlive();

    // Release persistent shell
    await _persistentShell?.dispose();
    _persistentShell = null;

    await _stdoutSubscription?.cancel();
    await _stderrSubscription?.cancel();
    _stdoutSubscription = null;
    _stderrSubscription = null;

    _session?.close();
    _session = null;

    _client?.close();
    _client = null;

    _socket?.close();
    _socket = null;
  }

  /// Start persistent shell
  Future<void> _startPersistentShell() async {
    if (_client == null) return;

    try {
      _persistentShell = PersistentShell(_client!);
      await _persistentShell!.start();
    } catch (e) {
      // Even if persistent shell fails to start, the connection itself continues
      // Falls back to the traditional exec() method
      _persistentShell = null;
    }
  }

  /// Restart persistent shell
  Future<void> restartPersistentShell() async {
    if (_client == null || !isConnected) return;

    try {
      await _persistentShell?.dispose();
      _persistentShell = PersistentShell(_client!);
      await _persistentShell!.start();
    } catch (e) {
      _persistentShell = null;
    }
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
        final session = await _client!.execute(
          r"$SHELL -lc 'command -v tmux'",
        );
        final stdoutBytes = <int>[];
        await session.stdout.forEach((data) => stdoutBytes.addAll(data));
        await session.stderr.drain();
        session.close();
        return utf8.decode(stdoutBytes, allowMalformed: true).trim();
      });
      if (path.isNotEmpty && path.startsWith('/')) {
        _tmuxPath = path;
        debugPrint('_detectTmuxPath: found via login shell: $path');
        return;
      }
    } catch (e) {
      debugPrint('_detectTmuxPath: login shell detection failed: $e');
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
          final session = await _client!.execute('test -x $candidate');
          await session.stdout.drain();
          await session.stderr.drain();
          final code = session.exitCode;
          session.close();
          return code;
        });
        if (exitCode == 0) {
          _tmuxPath = candidate;
          debugPrint('_detectTmuxPath: found via fallback: $candidate');
          return;
        }
      } catch (e) {
        debugPrint('_detectTmuxPath: error checking $candidate: $e');
      }
    }
    debugPrint('_detectTmuxPath: tmux not found');
  }

  /// Replace `tmux` in command with detected absolute path
  String _resolveTmuxCommand(String command) {
    if (_tmuxPath == null) {
      debugPrint('_resolveTmuxCommand: _tmuxPath=null, command unchanged');
      return command;
    }
    final resolved = command.replaceAllMapped(
      RegExp(r'(^|;\s*)tmux\b'),
      (m) => '${m[1]}$_tmuxPath',
    );
    if (resolved != command) {
      debugPrint('_resolveTmuxCommand: "$command" => "$resolved"');
    }
    return resolved;
  }

  /// Start keep-alive
  ///
  /// Periodically executes a lightweight command to verify the connection is alive.
  /// Immediately transitions to error state if the connection is lost.
  /// The interval is dynamically adjusted (extended on success, shortened on failure).
  void _startKeepAlive() {
    _stopKeepAlive();
    _currentKeepAliveIntervalSeconds = 10; // Initial value: 10 seconds
    _keepAliveSuccessCount = 0;
    _scheduleNextKeepAlive();
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
    if (success) {
      _keepAliveSuccessCount++;
      // Extend interval after 3 consecutive successes
      if (_keepAliveSuccessCount >= 3) {
        _currentKeepAliveIntervalSeconds = (_currentKeepAliveIntervalSeconds + 5)
            .clamp(_minKeepAliveIntervalSeconds, _maxKeepAliveIntervalSeconds);
        _keepAliveSuccessCount = 0;
      }
    } else {
      // Reset to minimum interval on failure
      _currentKeepAliveIntervalSeconds = _minKeepAliveIntervalSeconds;
      _keepAliveSuccessCount = 0;
    }
  }

  /// Send keep-alive packet
  Future<void> _sendKeepAlive() async {
    if (!isConnected || _client == null) {
      return;
    }

    try {
      // Keep-alive via persistent shell (fast)
      await execPersistent(
        'echo ping',
        timeout: Duration(seconds: _keepAliveTimeoutSeconds),
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
        _handleData,
        onError: _handleError,
        onDone: _handleDone,
      );

      _stderrSubscription = _session!.stderr.listen(
        _handleData,
        onError: _handleError,
      );
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
    _session!.write(utf8.encode(data));
  }

  /// Write byte data to the shell
  ///
  /// [data] Data to send (bytes)
  void writeBytes(Uint8List data) {
    if (_isDisposed || !isConnected || _session == null) {
      throw SshConnectionError('Not connected or shell not started');
    }
    _session!.write(data);
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
        final session = await _client!.execute(resolvedCommand);

        // Collect output (collect as byte sequence and decode at the end)
        final stdoutBytes = <int>[];
        final stderrBytes = <int>[];

        final stdoutCompleter = Completer<void>();
        final stderrCompleter = Completer<void>();

        session.stdout.listen(
          (data) => stdoutBytes.addAll(data),
          onDone: () => stdoutCompleter.complete(),
          onError: (e) => stdoutCompleter.completeError(e),
        );

        session.stderr.listen(
          (data) => stderrBytes.addAll(data),
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
          await Future.wait([
            stdoutCompleter.future,
            stderrCompleter.future,
          ]);
        }

        session.close();

        // Decode byte sequence as UTF-8 (invalid bytes become replacement characters)
        final stdout = utf8.decode(stdoutBytes, allowMalformed: true);
        final stderr = utf8.decode(stderrBytes, allowMalformed: true);

        // Treat stderr as error if present (optional)
        if (stderr.isNotEmpty) {
          // Include stderr in result (tmux commands may output to stderr)
          debugPrint('exec: stdout="${stdout.trim()}", stderr="${stderr.trim()}"');
          return stdout + stderr;
        }

        debugPrint('exec: stdout="${stdout.trim()}"');
        return stdout;
      });
    } on TimeoutException {
      debugPrint('exec: timed out');
      throw SshConnectionError('Command execution timed out');
    } catch (e) {
      debugPrint('exec: error=$e');
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
    if (_persistentShell == null || !_persistentShell!.isStarted) {
      return exec(resolvedCommand, timeout: timeout);
    }

    try {
      return await _persistentShell!.exec(resolvedCommand, timeout: timeout);
    } on PersistentShellError catch (e) {
      // Attempt restart if shell session has been disconnected
      if (e.message.contains('closed') || e.message.contains('disposed')) {
        try {
          await restartPersistentShell();
          return await _persistentShell!.exec(resolvedCommand, timeout: timeout);
        } catch (_) {
          // Fall back to traditional exec() if restart also fails
          return exec(resolvedCommand, timeout: timeout);
        }
      }
      // Fall back to traditional exec() for other errors
      return exec(resolvedCommand, timeout: timeout);
    }
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
        final session = await _client!.execute(resolvedCommand);

        // Accumulate as byte sequence (prevents UTF-8 boundary splits from chunk-by-chunk decoding)
        final stdoutBytes = <int>[];
        final stderrBytes = <int>[];

        final stdoutCompleter = Completer<void>();
        final stderrCompleter = Completer<void>();

        session.stdout.listen(
          (data) => stdoutBytes.addAll(data),
          onDone: () => stdoutCompleter.complete(),
          onError: (e) => stdoutCompleter.completeError(e),
        );

        session.stderr.listen(
          (data) => stderrBytes.addAll(data),
          onDone: () => stderrCompleter.complete(),
          onError: (e) => stderrCompleter.completeError(e),
        );

        if (timeout != null) {
          await Future.wait([
            stdoutCompleter.future,
            stderrCompleter.future,
          ]).timeout(timeout);
        } else {
          await Future.wait([
            stdoutCompleter.future,
            stderrCompleter.future,
          ]);
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
}

/// Create an SSH client
SshClient createSshClient() {
  return SshClient();
}
