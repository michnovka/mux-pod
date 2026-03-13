import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

/// Persistent shell session
///
/// Writes commands and detects output completion via markers to return results.
/// Eliminates channel open/close overhead, enabling command execution in about 1 RTT.
class PersistentShell {
  final SSHClient _sshClient;
  final void Function(int bytes)? _onBytesReceived;
  final void Function(int bytes)? _onBytesSent;
  SSHSession? _session;

  /// Core text of the marker
  static const String _markerId = '7f3d8a2b';

  /// Marker for detecting command start (with \x01 prefix/suffix)
  ///
  /// By including \x01 (SOH control character), this distinguishes from
  /// literal strings (`\x01` = 4 characters) in shell echo-back text.
  /// Only printf's actual output contains byte 0x01, so it won't match in echo-back.
  static const String _startMarker = '\x01###START_$_markerId###\x01';

  /// Marker for detecting command end
  static const String _endMarker = '\x01###END_$_markerId###\x01';

  /// Marker string for printf (used within shell commands)
  static const String _printfStartMarker = r'\x01###START_' '$_markerId' r'###\x01';
  static const String _printfEndMarker = r'\x01###END_' '$_markerId' r'###\x01';

  static final List<int> _startMarkerBytes = utf8.encode(_startMarker);
  static final List<int> _endMarkerBytes = utf8.encode(_endMarker);

  /// Output buffer (accumulated as byte sequence to prevent UTF-8 multibyte boundary splits)
  final _rawBuffer = <int>[];

  /// Maximum buffer size (16 MB). If exceeded, the pending command is failed
  /// and the shell is restarted to prevent unbounded memory growth from hung
  /// commands that never produce an end marker. The biggest expected payload
  /// is scrollback history (capture-pane -p -N): at 10k lines × 270 cols
  /// that's ~2.6 MB without escapes. 16 MB provides ample headroom for wider
  /// panes, higher scrollback settings, and Unicode-heavy content.
  static const int _maxBufferSize = 16 * 1024 * 1024;

  /// Completer for the currently executing command
  Completer<String>? _pendingCommand;

  /// Cached position of the start marker once found, or -1 if not yet found.
  int _startMarkerIndex = -1;

  /// Offset into _rawBuffer from which to resume scanning for the start marker.
  /// Avoids rescanning already-processed bytes on each data chunk.
  int _scanOffset = 0;

  /// Whether the shell has been started
  bool get isStarted => _session != null;

  /// For detecting session disconnection
  bool _isClosed = false;

  /// stdout subscription
  StreamSubscription<Uint8List>? _stdoutSubscription;

  PersistentShell(
    this._sshClient, {
    void Function(int bytes)? onBytesReceived,
    void Function(int bytes)? onBytesSent,
  }) : _onBytesReceived = onBytesReceived,
       _onBytesSent = onBytesSent;

  /// Start the shell session
  Future<void> start() async {
    if (_session != null) {
      return; // Already started
    }

    _session = await _sshClient.shell(
      pty: SSHPtyConfig(
        type: 'dumb', // Minimal PTY (suppresses escape sequences)
        width: 200,
        height: 50,
      ),
    );

    _isClosed = false;

    // Start monitoring stdout
    _stdoutSubscription = _session!.stdout.listen(
      _onData,
      onDone: _onDone,
      onError: _onError,
    );

    // Wait for shell initialization (wait briefly until prompt is output)
    await Future.delayed(const Duration(milliseconds: 100));

    // Disable history recording (Bash/Zsh/fish compatible) and suppress prompt
    // - export HISTFILE=... : For Bash/Zsh (overrides after startup files)
    // - set fish_history ... : For fish (export causes syntax error in fish, so separate)
    // - 2>/dev/null suppresses errors on unsupported shells
    final initializationBytes = utf8.encode(
      'export HISTFILE=/dev/null HISTSIZE=0 HISTFILESIZE=0 SAVEHIST=0 2>/dev/null;'
      ' set fish_history "" 2>/dev/null; true;'
      ' export PS1="" PS2="" 2>/dev/null; stty -echo\n',
    );
    _onBytesSent?.call(initializationBytes.length);
    _session!.write(initializationBytes);
    await Future.delayed(const Duration(milliseconds: 100));

    // Clear buffer (discard initialization output)
    _rawBuffer.clear();
  }

  /// Execute a command and get the result
  ///
  /// [command] The command to execute
  /// [timeout] Timeout duration (default: 5 seconds)
  /// Returns: The command's standard output
  Future<String> exec(String command, {Duration? timeout}) async {
    if (_session == null) {
      throw PersistentShellError('Shell not started');
    }

    if (_isClosed) {
      throw PersistentShellError('Shell session is closed');
    }

    if (_pendingCommand != null && !_pendingCommand!.isCompleted) {
      throw PersistentShellError('Another command is already running');
    }

    _pendingCommand = Completer<String>();
    _rawBuffer.clear();
    _startMarkerIndex = -1;
    _scanOffset = 0;

    // Output markers using printf (containing \x01 byte)
    // Using printf instead of echo: shell echo-back displays literal '\x01' (4 chars),
    // but printf's actual output contains byte 0x01.
    // This reliably distinguishes markers in echo-back from markers in actual output.
    final commandWithMarkers =
        "printf '$_printfStartMarker\\n'; $command; printf '$_printfEndMarker\\n'\n";
    final commandBytes = utf8.encode(commandWithMarkers);
    _onBytesSent?.call(commandBytes.length);
    _session!.write(commandBytes);

    // Wait for result with timeout
    final effectiveTimeout = timeout ?? const Duration(seconds: 5);
    try {
      return await _pendingCommand!.future.timeout(effectiveTimeout);
    } on TimeoutException {
      _pendingCommand = null;
      _rawBuffer.clear();
      _startMarkerIndex = -1;
      _scanOffset = 0;
      // The timed-out command may still be running on the remote side,
      // consuming stdin. Restart the shell so subsequent exec() calls
      // get a clean session.
      unawaited(restart());
      throw PersistentShellError('Command execution timed out');
    }
  }

  /// Handler for stdout data reception
  void _onData(Uint8List data) {
    _onBytesReceived?.call(data.length);

    // Ignore if no pending command or already completed
    final pending = _pendingCommand;
    if (pending == null || pending.isCompleted) {
      return;
    }

    _rawBuffer.addAll(data);

    // Guard against unbounded growth from hung commands that produce output
    // but never emit an end marker.
    if (_rawBuffer.length > _maxBufferSize) {
      _pendingCommand = null;
      _rawBuffer.clear();
      _startMarkerIndex = -1;
      _scanOffset = 0;
      // Restart the shell so subsequent commands get a clean session —
      // the hung command may still be running and consuming stdin.
      unawaited(restart());
      pending.completeError(
        PersistentShellError('Buffer overflow (>${_maxBufferSize ~/ 1024} KB)'),
      );
      return;
    }

    // Incremental scanning: only search new bytes for markers.
    if (_startMarkerIndex == -1) {
      // Back up by marker length - 1 to catch markers that span chunks.
      final searchFrom = (_scanOffset - _startMarkerBytes.length + 1)
          .clamp(0, _rawBuffer.length);
      _startMarkerIndex = _indexOfBytes(
        _rawBuffer,
        _startMarkerBytes,
        start: searchFrom,
      );
      if (_startMarkerIndex == -1) {
        _scanOffset = _rawBuffer.length;
        return;
      }
    }

    final endSearchStart = _startMarkerIndex + _startMarkerBytes.length;
    // Resume end-marker search from where we left off last time.
    final endScanFrom = (_scanOffset > endSearchStart)
        ? (_scanOffset - _endMarkerBytes.length + 1)
            .clamp(endSearchStart, _rawBuffer.length)
        : endSearchStart;
    final endIndex = _indexOfBytes(
      _rawBuffer,
      _endMarkerBytes,
      start: endScanFrom,
    );

    if (endIndex == -1) {
      _scanOffset = _rawBuffer.length;
      return;
    }

    final resultBytes = _rawBuffer.sublist(endSearchStart, endIndex);
    var result = utf8.decode(resultBytes, allowMalformed: true);

    // Normalize because PTY output conversion may use \r\n or \r
    // Fact: on macOS PTY, newlines=0, CRs=19 (\n is converted to \r)
    result = result.replaceAll('\r\n', '\n').replaceAll('\r', '\n');

    // Remove leading and trailing newlines
    if (result.startsWith('\n')) {
      result = result.substring(1);
    }
    if (result.endsWith('\n')) {
      result = result.substring(0, result.length - 1);
    }

    // Set Completer to null before completing (prevents re-entry)
    _pendingCommand = null;
    _rawBuffer.clear();
    _startMarkerIndex = -1;
    _scanOffset = 0;
    pending.complete(result);
  }

  static int _indexOfBytes(
    List<int> source,
    List<int> pattern, {
    int start = 0,
  }) {
    if (pattern.isEmpty || start < 0 || start >= source.length) {
      return -1;
    }

    final maxStart = source.length - pattern.length;
    for (var index = start; index <= maxStart; index++) {
      var matches = true;
      for (var patternIndex = 0; patternIndex < pattern.length; patternIndex++) {
        if (source[index + patternIndex] != pattern[patternIndex]) {
          matches = false;
          break;
        }
      }
      if (matches) {
        return index;
      }
    }

    return -1;
  }

  /// Handler for session termination
  void _onDone() {
    _isClosed = true;
    if (_pendingCommand != null && !_pendingCommand!.isCompleted) {
      _pendingCommand!.completeError(PersistentShellError('Shell session closed'));
    }
  }

  /// Handler for error occurrence
  void _onError(Object error) {
    _isClosed = true;
    if (_pendingCommand != null && !_pendingCommand!.isCompleted) {
      _pendingCommand!.completeError(PersistentShellError('Shell error: $error'));
    }
  }

  /// Restart the shell session
  ///
  /// Called when the session has been disconnected
  Future<void> restart() async {
    await dispose();
    await start();
  }

  /// Release resources
  Future<void> dispose() async {
    _isClosed = true;

    if (_pendingCommand != null && !_pendingCommand!.isCompleted) {
      _pendingCommand!.completeError(PersistentShellError('Shell disposed'));
    }
    _pendingCommand = null;

    await _stdoutSubscription?.cancel();
    _stdoutSubscription = null;

    _session?.close();
    _session = null;

    _rawBuffer.clear();
    _startMarkerIndex = -1;
    _scanOffset = 0;
  }
}

/// Error for PersistentShell
class PersistentShellError implements Exception {
  final String message;

  PersistentShellError(this.message);

  @override
  String toString() => 'PersistentShellError: $message';
}
