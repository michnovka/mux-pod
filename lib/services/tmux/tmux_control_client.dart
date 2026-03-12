import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../ssh/ssh_client.dart';

class TmuxControlClientError implements Exception {
  final String message;

  TmuxControlClientError(this.message);

  @override
  String toString() => 'TmuxControlClientError: $message';
}

class TmuxControlNotification {
  final String name;
  final List<String> arguments;
  final String rawLine;

  const TmuxControlNotification({
    required this.name,
    required this.arguments,
    required this.rawLine,
  });
}

class TmuxControlClient {
  final SshClient _sshClient;
  final void Function(String paneId, String data)? onPaneOutput;
  final void Function(TmuxControlNotification notification)? onNotification;
  final void Function(Object error)? onError;
  final void Function()? onClosed;

  Completer<String>? _pendingCommand;
  _CommandResponseBuffer? _commandResponseBuffer;
  String _pendingLine = '';
  late ByteConversionSink _utf8Sink;
  bool _isStarted = false;
  bool _isStopped = false;

  TmuxControlClient(
    this._sshClient, {
    this.onPaneOutput,
    this.onNotification,
    this.onError,
    this.onClosed,
  }) {
    _resetDecoder();
  }

  bool get isStarted => _isStarted;

  Future<void> start({
    required String sessionName,
    required int cols,
    required int rows,
  }) async {
    if (_isStopped) {
      throw TmuxControlClientError('Client has been disposed');
    }

    await stop();
    _resetDecoder();

    final startupCommand = _buildStartupCommand(
      tmuxBinary: _sshClient.tmuxPath ?? 'tmux',
      sessionName: sessionName,
    );

    await _sshClient.startStreamingShell(
      startupCommand: startupCommand,
      onData: _handleBytes,
      onDone: _handleDone,
      onError: _handleStreamError,
      options: ShellOptions(term: 'dumb', cols: cols, rows: rows),
    );

    _isStarted = true;

    try {
      await sendCommand(
        'refresh-client -C ${cols}x$rows',
        timeout: const Duration(seconds: 1),
      );
    } catch (_) {
      // Best effort: the PTY size is already correct, and some older tmux
      // setups may reject explicit refresh-client sizing.
    }
  }

  @visibleForTesting
  static String debugBuildStartupCommand({
    required String tmuxBinary,
    required String sessionName,
  }) {
    return _buildStartupCommand(
      tmuxBinary: tmuxBinary,
      sessionName: sessionName,
    );
  }

  Future<void> stop() async {
    _isStarted = false;
    if (_pendingCommand != null && !_pendingCommand!.isCompleted) {
      _pendingCommand!.completeError(
        TmuxControlClientError('Control session stopped'),
      );
    }
    _pendingCommand = null;
    _commandResponseBuffer = null;
    _pendingLine = '';
    _resetDecoder();
    await _sshClient.stopStreamingShell();
  }

  Future<void> dispose() async {
    if (_isStopped) {
      return;
    }
    _isStopped = true;
    await stop();
  }

  Future<String> sendCommand(
    String command, {
    Duration timeout = const Duration(seconds: 2),
  }) async {
    if (!_isStarted || !_sshClient.isStreamingShellActive) {
      throw TmuxControlClientError('Control session is not running');
    }
    if (_pendingCommand != null && !_pendingCommand!.isCompleted) {
      throw TmuxControlClientError(
        'Another control command is already running',
      );
    }

    final completer = Completer<String>();
    _pendingCommand = completer;
    _sshClient.writeStreamingShell(
      command.endsWith('\n') ? command : '$command\n',
    );

    try {
      return await completer.future.timeout(timeout);
    } on TimeoutException {
      if (_pendingCommand == completer) {
        _pendingCommand = null;
        _commandResponseBuffer = null;
      }
      throw TmuxControlClientError('Control command timed out');
    }
  }

  @visibleForTesting
  void debugAddBytes(Uint8List data) {
    _handleBytes(data);
  }

  @visibleForTesting
  Future<String> debugPrimePendingCommand() {
    final completer = Completer<String>();
    _pendingCommand = completer;
    return completer.future;
  }

  void _handleBytes(Uint8List data) {
    _utf8Sink.add(data);
  }

  void _handleTextChunk(String chunk) {
    // Process lines by scanning for newlines with an offset rather than
    // repeatedly slicing _pendingLine (which allocates a new String for the
    // remainder on every line).
    final text = _pendingLine.isEmpty ? chunk : '$_pendingLine$chunk';
    var start = 0;

    while (true) {
      final newlineIndex = text.indexOf('\n', start);
      if (newlineIndex == -1) {
        _pendingLine = start == 0 ? text : text.substring(start);
        return;
      }

      var end = newlineIndex;
      if (end > start && text.codeUnitAt(end - 1) == 0x0D) {
        end--;
      }
      _handleLine(text.substring(start, end));
      start = newlineIndex + 1;
    }
  }

  void _handleLine(String line) {
    if (line.isEmpty && _commandResponseBuffer == null) {
      return;
    }

    if (line.startsWith('%begin ')) {
      _commandResponseBuffer = _CommandResponseBuffer(
        completer: _pendingCommand,
      );
      return;
    }

    if (line.startsWith('%end ') || line.startsWith('%error ')) {
      final responseBuffer = _commandResponseBuffer;
      if (responseBuffer == null) {
        return;
      }

      final response = responseBuffer.lines.join('\n');
      final completer = responseBuffer.completer;
      _commandResponseBuffer = null;
      _pendingCommand = null;

      if (completer == null || completer.isCompleted) {
        return;
      }

      if (line.startsWith('%error ')) {
        completer.completeError(TmuxControlClientError(response));
      } else {
        completer.complete(response);
      }
      return;
    }

    if (_commandResponseBuffer != null) {
      _commandResponseBuffer!.lines.add(line);
      return;
    }

    if (line.startsWith('%output ')) {
      final parsed = _parseOutputLine(line);
      if (parsed == null) {
        return;
      }

      final paneId = parsed.paneId;
      final payload = _unescapeControlPayload(parsed.payload);
      onPaneOutput?.call(paneId, payload);
      return;
    }

    if (line.startsWith('%extended-output ')) {
      final parsed = _parseExtendedOutputLine(line);
      if (parsed == null) {
        return;
      }

      final paneId = parsed.paneId;
      final payload = _unescapeControlPayload(parsed.payload);
      onPaneOutput?.call(paneId, payload);
      return;
    }

    if (!line.startsWith('%')) {
      return;
    }

    final firstSpace = line.indexOf(' ');
    final name = firstSpace == -1
        ? line.substring(1)
        : line.substring(1, firstSpace);
    final arguments = firstSpace == -1
        ? const <String>[]
        : line.substring(firstSpace + 1).split(' ');

    onNotification?.call(
      TmuxControlNotification(name: name, arguments: arguments, rawLine: line),
    );
  }

  void _handleStreamError(Object error) {
    onError?.call(error);
  }

  void _handleDone() {
    _isStarted = false;
    if (_pendingCommand != null && !_pendingCommand!.isCompleted) {
      _pendingCommand!.completeError(
        TmuxControlClientError('Control session closed'),
      );
    }
    _pendingCommand = null;
    _commandResponseBuffer = null;
    onClosed?.call();
  }

  void _resetDecoder() {
    _pendingLine = '';
    _utf8Sink = utf8.decoder.startChunkedConversion(
      StringConversionSink.fromStringSink(
        _StreamingStringSink(_handleTextChunk),
      ),
    );
  }

  static String _escapeShellArg(String value) {
    final escaped = value.replaceAll("'", "'\"'\"'");
    return "'$escaped'";
  }

  static String _buildStartupCommand({
    required String tmuxBinary,
    required String sessionName,
  }) {
    final escapedTmuxBinary = _escapeShellArg(tmuxBinary);
    final escapedSessionName = _escapeShellArg(sessionName);
    return 'export PS1="" PS2="" 2>/dev/null; '
        'stty -echo 2>/dev/null; '
        'exec $escapedTmuxBinary -C attach-session -f ignore-size -t $escapedSessionName';
  }

  static _ParsedPaneOutput? _parseOutputLine(String line) {
    const prefix = '%output ';
    if (!line.startsWith(prefix)) {
      return null;
    }

    final body = line.substring(prefix.length);
    final separatorIndex = body.indexOf(' ');
    if (separatorIndex <= 0) {
      return null;
    }

    return _ParsedPaneOutput(
      paneId: body.substring(0, separatorIndex),
      payload: body.substring(separatorIndex + 1),
    );
  }

  static _ParsedPaneOutput? _parseExtendedOutputLine(String line) {
    const prefix = '%extended-output ';
    if (!line.startsWith(prefix)) {
      return null;
    }

    final body = line.substring(prefix.length);
    final paneSeparatorIndex = body.indexOf(' ');
    if (paneSeparatorIndex <= 0) {
      return null;
    }

    final paneId = body.substring(0, paneSeparatorIndex);
    final remainder = body.substring(paneSeparatorIndex + 1);
    final metadataSeparatorIndex = remainder.indexOf(': ');
    if (metadataSeparatorIndex == -1) {
      return null;
    }

    return _ParsedPaneOutput(
      paneId: paneId,
      payload: remainder.substring(metadataSeparatorIndex + 2),
    );
  }

  static String _unescapeControlPayload(String escaped) {
    // Fast path: no backslash means nothing to unescape.
    if (!escaped.contains(r'\')) return escaped;

    final length = escaped.length;
    // Pre-allocate output buffer. Octal escapes (\nnn = 4 chars) compress
    // to 1 byte and ASCII is 1:1. tmux octal-escapes all non-ASCII bytes,
    // so output is always ≤ input length. We add a small margin for safety.
    var bytes = Uint8List(length + 4);
    var writePos = 0;

    for (var index = 0; index < length; index++) {
      final cu = escaped.codeUnitAt(index);

      // Check for octal escape: backslash followed by exactly 3 octal digits.
      if (cu == 0x5C && // '\'
          index + 3 < length &&
          _isOctalDigit(escaped.codeUnitAt(index + 1)) &&
          _isOctalDigit(escaped.codeUnitAt(index + 2)) &&
          _isOctalDigit(escaped.codeUnitAt(index + 3))) {
        bytes[writePos++] = ((escaped.codeUnitAt(index + 1) - 0x30) << 6) |
            ((escaped.codeUnitAt(index + 2) - 0x30) << 3) |
            (escaped.codeUnitAt(index + 3) - 0x30);
        index += 3;
        continue;
      }

      // ASCII: copy byte directly (common case for terminal output).
      if (cu < 0x80) {
        bytes[writePos++] = cu;
      } else {
        // Non-ASCII code unit — encode to UTF-8 manually.
        // This is rare since tmux octal-escapes non-ASCII bytes.
        if (cu < 0x800) {
          bytes[writePos++] = 0xC0 | (cu >> 6);
          bytes[writePos++] = 0x80 | (cu & 0x3F);
        } else if (cu >= 0xD800 && cu <= 0xDBFF && index + 1 < length) {
          // Surrogate pair
          final lo = escaped.codeUnitAt(index + 1);
          if (lo >= 0xDC00 && lo <= 0xDFFF) {
            final codePoint = 0x10000 + ((cu - 0xD800) << 10) + (lo - 0xDC00);
            bytes[writePos++] = 0xF0 | (codePoint >> 18);
            bytes[writePos++] = 0x80 | ((codePoint >> 12) & 0x3F);
            bytes[writePos++] = 0x80 | ((codePoint >> 6) & 0x3F);
            bytes[writePos++] = 0x80 | (codePoint & 0x3F);
            index++;
          } else {
            bytes[writePos++] = 0xE0 | (cu >> 12);
            bytes[writePos++] = 0x80 | ((cu >> 6) & 0x3F);
            bytes[writePos++] = 0x80 | (cu & 0x3F);
          }
        } else {
          bytes[writePos++] = 0xE0 | (cu >> 12);
          bytes[writePos++] = 0x80 | ((cu >> 6) & 0x3F);
          bytes[writePos++] = 0x80 | (cu & 0x3F);
        }
      }
    }

    return utf8.decode(
      bytes.buffer.asUint8List(0, writePos),
      allowMalformed: true,
    );
  }

  static bool _isOctalDigit(int codeUnit) =>
      codeUnit >= 0x30 && codeUnit <= 0x37;
}

class _CommandResponseBuffer {
  final Completer<String>? completer;
  final List<String> lines = [];

  _CommandResponseBuffer({required this.completer});
}

class _ParsedPaneOutput {
  final String paneId;
  final String payload;

  const _ParsedPaneOutput({required this.paneId, required this.payload});
}

class _StreamingStringSink implements StringSink {
  final void Function(String chunk) onChunk;

  _StreamingStringSink(this.onChunk);

  @override
  void write(Object? obj) {
    if (obj != null) {
      onChunk(obj.toString());
    }
  }

  @override
  void writeAll(Iterable<Object?> objects, [String separator = '']) {
    if (objects.isEmpty) {
      return;
    }
    onChunk(objects.map((obj) => obj?.toString() ?? '').join(separator));
  }

  @override
  void writeCharCode(int charCode) {
    onChunk(String.fromCharCode(charCode));
  }

  @override
  void writeln([Object? obj = '']) {
    onChunk('${obj ?? ''}\n');
  }
}
