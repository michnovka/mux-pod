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

  Future<void> start({required String sessionName}) async {
    if (_isStopped) {
      throw TmuxControlClientError('Client has been disposed');
    }

    await stop();
    _resetDecoder();

    final tmuxBinary = _escapeShellArg(_sshClient.tmuxPath ?? 'tmux');
    final targetSession = _escapeShellArg(sessionName);
    final startupCommand =
        'export PS1="" PS2="" 2>/dev/null; '
        'stty -echo 2>/dev/null; '
        'exec $tmuxBinary -C attach-session -t $targetSession';

    await _sshClient.startStreamingShell(
      startupCommand: startupCommand,
      onData: _handleBytes,
      onDone: _handleDone,
      onError: _handleStreamError,
    );

    _isStarted = true;
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
      throw TmuxControlClientError('Another control command is already running');
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
    _pendingLine += chunk;

    while (true) {
      final newlineIndex = _pendingLine.indexOf('\n');
      if (newlineIndex == -1) {
        return;
      }

      var line = _pendingLine.substring(0, newlineIndex);
      _pendingLine = _pendingLine.substring(newlineIndex + 1);
      if (line.endsWith('\r')) {
        line = line.substring(0, line.length - 1);
      }
      _handleLine(line);
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
      final match = RegExp(r'^%output\s+(\S+)\s+(.*)$').firstMatch(line);
      if (match == null) {
        return;
      }

      final paneId = match.group(1)!;
      final payload = _unescapeControlPayload(match.group(2)!);
      onPaneOutput?.call(paneId, payload);
      return;
    }

    if (line.startsWith('%extended-output ')) {
      final match = RegExp(r'^%extended-output\s+(\S+)\s+.*?:\s(.*)$')
          .firstMatch(line);
      if (match == null) {
        return;
      }

      final paneId = match.group(1)!;
      final payload = _unescapeControlPayload(match.group(2)!);
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
      TmuxControlNotification(
        name: name,
        arguments: arguments,
        rawLine: line,
      ),
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

  static String _unescapeControlPayload(String escaped) {
    final bytes = <int>[];
    for (var index = 0; index < escaped.length; index++) {
      final char = escaped[index];
      if (char == r'\' &&
          index + 3 < escaped.length &&
          _isOctalDigit(escaped.codeUnitAt(index + 1)) &&
          _isOctalDigit(escaped.codeUnitAt(index + 2)) &&
          _isOctalDigit(escaped.codeUnitAt(index + 3))) {
        final value = int.parse(
          escaped.substring(index + 1, index + 4),
          radix: 8,
        );
        bytes.add(value);
        index += 3;
        continue;
      }

      bytes.addAll(utf8.encode(char));
    }

    return utf8.decode(bytes, allowMalformed: true);
  }

  static bool _isOctalDigit(int codeUnit) =>
      codeUnit >= 0x30 && codeUnit <= 0x37;
}

class _CommandResponseBuffer {
  final Completer<String>? completer;
  final List<String> lines = [];

  _CommandResponseBuffer({required this.completer});
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
