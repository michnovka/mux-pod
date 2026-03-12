final RegExp _cursorPositionReportPattern = RegExp(r'\x1b\[(\d+);(\d+)R');

/// Normalizes terminal responses emitted by the local emulator before they are
/// forwarded to the remote pane.
///
/// xterm 4.0.0 emits cursor position reports using zero-based row and column
/// values even though CPR (`CSI 6n`) is specified as one-based. Interactive
/// prompt layers such as Claude's prompt-toolkit UI depend on CPR for redraws,
/// so fix that here without patching the package in-place.
String normalizeTerminalOutput(String data) {
  if (!_cursorPositionReportPattern.hasMatch(data)) {
    return data;
  }

  return data.replaceAllMapped(_cursorPositionReportPattern, (match) {
    final row = int.tryParse(match.group(1)!);
    final col = int.tryParse(match.group(2)!);
    if (row == null || col == null) {
      return match.group(0)!;
    }

    return '\x1b[${row + 1};${col + 1}R';
  });
}
