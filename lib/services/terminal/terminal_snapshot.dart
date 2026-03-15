import 'package:xterm/xterm.dart';

/// A full terminal snapshot used to reseed the emulator after reconnects or pane switches.
class TerminalSnapshotFrame {
  final String content;
  final String mainContent;
  final bool alternateScreen;
  final int paneWidth;
  final int paneHeight;
  final int cursorX;
  final int cursorY;
  final bool insertMode;
  final bool cursorKeysMode;
  final bool appKeypadMode;
  final bool autoWrapMode;
  final bool pendingWrap;
  final bool cursorVisible;
  final bool originMode;
  final int? scrollRegionUpper;
  final int? scrollRegionLower;

  const TerminalSnapshotFrame({
    this.content = '',
    this.mainContent = '',
    this.alternateScreen = false,
    this.paneWidth = 80,
    this.paneHeight = 24,
    this.cursorX = 0,
    this.cursorY = 0,
    this.insertMode = false,
    this.cursorKeysMode = false,
    this.appKeypadMode = false,
    this.autoWrapMode = true,
    this.pendingWrap = false,
    this.cursorVisible = true,
    this.originMode = false,
    this.scrollRegionUpper,
    this.scrollRegionLower,
  });

  TerminalSnapshotFrame copyWith({
    String? content,
    String? mainContent,
    bool? alternateScreen,
    int? paneWidth,
    int? paneHeight,
    int? cursorX,
    int? cursorY,
    bool? insertMode,
    bool? cursorKeysMode,
    bool? appKeypadMode,
    bool? autoWrapMode,
    bool? pendingWrap,
    bool? cursorVisible,
    bool? originMode,
    int? scrollRegionUpper,
    int? scrollRegionLower,
  }) {
    return TerminalSnapshotFrame(
      content: content ?? this.content,
      mainContent: mainContent ?? this.mainContent,
      alternateScreen: alternateScreen ?? this.alternateScreen,
      paneWidth: paneWidth ?? this.paneWidth,
      paneHeight: paneHeight ?? this.paneHeight,
      cursorX: cursorX ?? this.cursorX,
      cursorY: cursorY ?? this.cursorY,
      insertMode: insertMode ?? this.insertMode,
      cursorKeysMode: cursorKeysMode ?? this.cursorKeysMode,
      appKeypadMode: appKeypadMode ?? this.appKeypadMode,
      autoWrapMode: autoWrapMode ?? this.autoWrapMode,
      pendingWrap: pendingWrap ?? this.pendingWrap,
      cursorVisible: cursorVisible ?? this.cursorVisible,
      originMode: originMode ?? this.originMode,
      scrollRegionUpper: scrollRegionUpper ?? this.scrollRegionUpper,
      scrollRegionLower: scrollRegionLower ?? this.scrollRegionLower,
    );
  }
}

Terminal createTerminalFromSnapshot({
  required TerminalSnapshotFrame frame,
  required int maxLines,
  required bool showCursor,
  required void Function(String data) onOutput,
  required TerminalController controller,
}) {
  final terminal = Terminal(maxLines: maxLines, reflowEnabled: false)
    ..onOutput = onOutput;

  applySnapshotToTerminal(
    terminal: terminal,
    controller: controller,
    frame: frame,
    showCursor: showCursor,
  );

  return terminal;
}

void applySnapshotToTerminal({
  required Terminal terminal,
  required TerminalController controller,
  required TerminalSnapshotFrame frame,
  required bool showCursor,
}) {
  terminal.resize(frame.paneWidth, frame.paneHeight);
  controller.clearSelection();
  _applyTerminalModes(
    terminal,
    frame,
    showCursor: showCursor,
    beforeWrite: true,
  );

  terminal.useMainBuffer();
  terminal.mainBuffer.clear();
  terminal.altBuffer.clear();

  terminal.write(
    _buildBufferFrame(
      frame.alternateScreen ? frame.mainContent : frame.content,
    ),
  );

  if (frame.alternateScreen) {
    terminal.useAltBuffer();
    terminal.write(_buildBufferFrame(frame.content));
  } else {
    terminal.useMainBuffer();
  }

  _applyTerminalModes(
    terminal,
    frame,
    showCursor: showCursor,
    beforeWrite: false,
  );
}

void _applyTerminalModes(
  Terminal terminal,
  TerminalSnapshotFrame frame, {
  required bool showCursor,
  required bool beforeWrite,
}) {
  if (beforeWrite) {
    terminal.setAutoWrapMode(frame.autoWrapMode);
    return;
  }

  terminal.setInsertMode(frame.insertMode);
  terminal.setCursorKeysMode(frame.cursorKeysMode);
  terminal.setAppKeypadMode(frame.appKeypadMode);
  terminal.setAutoWrapMode(frame.autoWrapMode);
  terminal.setCursorVisibleMode(showCursor && frame.cursorVisible);

  final scrollRegionUpper = frame.scrollRegionUpper;
  final scrollRegionLower = frame.scrollRegionLower;
  if (scrollRegionUpper != null &&
      scrollRegionLower != null &&
      scrollRegionUpper >= 0 &&
      scrollRegionLower >= scrollRegionUpper &&
      scrollRegionLower < frame.paneHeight) {
    terminal.setMargins(scrollRegionUpper, scrollRegionLower);
  } else {
    terminal.setMargins(0, frame.paneHeight - 1);
  }

  terminal.setOriginMode(false);
  if (frame.alternateScreen) {
    terminal.useAltBuffer();
  } else {
    terminal.useMainBuffer();
  }
  terminal.setCursor(frame.cursorX, frame.cursorY);
  if (frame.pendingWrap) {
    terminal.buffer.cursorGoForward();
  }
  terminal.setOriginMode(frame.originMode);
}

String _buildBufferFrame(String content) {
  final normalizedContent = _normalizeCapturedContent(content);

  return '\x1b[?25l\x1b[H\x1b[2J\x1b[3J$normalizedContent';
}

String _normalizeCapturedContent(String content) {
  if (!content.contains('\n')) {
    return content;
  }

  return content.replaceAll('\r\n', '\n').replaceAll('\n', '\r\n');
}
