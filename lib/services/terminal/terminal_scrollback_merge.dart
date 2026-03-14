import 'dart:math' as math;

import 'package:xterm/xterm.dart';

BufferLine cloneTerminalBufferLine(BufferLine source) {
  final clone = BufferLine(source.length, isWrapped: source.isWrapped);
  if (source.length > 0) {
    clone.copyFrom(source, 0, 0, source.length);
  }
  return clone;
}

List<BufferLine> cloneTerminalBufferLines(Iterable<BufferLine> source) {
  return source.map(cloneTerminalBufferLine).toList(growable: false);
}

int findTerminalScrollbackOverlap({
  required List<BufferLine> olderLines,
  required List<BufferLine> newerLines,
  int maxLinesToCheck = 200,
}) {
  if (olderLines.isEmpty || newerLines.isEmpty) {
    return 0;
  }

  final maxOverlap = math.min(
    math.min(olderLines.length, newerLines.length),
    maxLinesToCheck,
  );

  for (var overlap = maxOverlap; overlap >= 1; overlap--) {
    var matches = true;
    final olderStart = olderLines.length - overlap;
    for (var index = 0; index < overlap; index++) {
      if (!_sameBufferLine(
        olderLines[olderStart + index],
        newerLines[index],
      )) {
        matches = false;
        break;
      }
    }
    if (matches) {
      return overlap;
    }
  }

  return 0;
}

bool prependTerminalScrollback({
  required Terminal terminal,
  required List<BufferLine> fullSnapshotLines,
  int maxLinesToCheck = 200,
}) {
  if (fullSnapshotLines.isEmpty) {
    return false;
  }

  final currentLines = cloneTerminalBufferLines(terminal.mainBuffer.lines.toList());
  if (currentLines.isEmpty) {
    terminal.mainBuffer.lines.replaceWith(
      cloneTerminalBufferLines(fullSnapshotLines),
    );
    return true;
  }

  final normalizedSnapshotLines = cloneTerminalBufferLines(fullSnapshotLines);
  final overlap = findTerminalScrollbackOverlap(
    olderLines: normalizedSnapshotLines,
    newerLines: currentLines,
    maxLinesToCheck: maxLinesToCheck,
  );
  if (overlap <= 0) {
    return false;
  }

  final prefixCount = normalizedSnapshotLines.length - overlap;
  if (prefixCount <= 0) {
    return false;
  }

  final mergedLines = <BufferLine>[
    ...normalizedSnapshotLines.take(prefixCount),
    ...currentLines,
  ];
  terminal.mainBuffer.lines.replaceWith(mergedLines);
  return true;
}

String debugTerminalBufferLineText(BufferLine line) {
  return line.getText(0, line.length);
}

bool _sameBufferLine(BufferLine left, BufferLine right) {
  return left.isWrapped == right.isWrapped &&
      left.length == right.length &&
      left.getText(0, left.length) == right.getText(0, right.length);
}

BufferLine debugCreateTerminalBufferLine(
  String text, {
  bool wrapped = false,
}) {
  final line = BufferLine(math.max(text.length, 1), isWrapped: wrapped);
  final cursor = CursorStyle.empty;
  for (var index = 0; index < text.length; index++) {
    line.setCell(index, text.codeUnitAt(index), 1, cursor);
  }
  return line;
}
