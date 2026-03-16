import 'package:xterm/xterm.dart';

/// A single search match within the terminal buffer.
class TerminalSearchMatch {
  /// Cell-based start position (x=column, y=absolute row).
  final CellOffset start;

  /// Inclusive end cell position.
  final CellOffset end;

  const TerminalSearchMatch({required this.start, required this.end});

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TerminalSearchMatch &&
          start == other.start &&
          end == other.end;

  @override
  int get hashCode => Object.hash(start, end);

  @override
  String toString() => 'TerminalSearchMatch($start, $end)';
}

/// Character-to-cell mapping entry used during search.
class _CharMapping {
  final int row;
  final int startCell;
  final int endCell;

  const _CharMapping({
    required this.row,
    required this.startCell,
    required this.endCell,
  });
}

/// Full-text search engine for the terminal buffer.
///
/// Scans buffer lines (handling wrapped lines) and returns matches with
/// cell-based coordinates suitable for creating highlights.
class TerminalSearchEngine {
  /// Scan buffer for matches. Returns list sorted top-to-bottom.
  ///
  /// Throws [FormatException] on invalid regex when [regex] is true.
  static List<TerminalSearchMatch> search(
    Buffer buffer, {
    required String query,
    bool caseSensitive = false,
    bool regex = false,
  }) {
    if (query.isEmpty) return const [];

    final lines = buffer.lines;
    final lineCount = lines.length;
    if (lineCount == 0) return const [];

    // Compile the pattern once.
    final Pattern pattern;
    if (regex) {
      try {
        pattern = RegExp(query, caseSensitive: caseSensitive);
      } on FormatException {
        rethrow;
      }
    } else {
      pattern = RegExp(
        RegExp.escape(query),
        caseSensitive: caseSensitive,
      );
    }

    final results = <TerminalSearchMatch>[];
    var i = 0;

    while (i < lineCount) {
      // Collect a logical line (possibly spanning multiple wrapped lines).
      final charMappings = <_CharMapping>[];
      final textBuf = StringBuffer();

      // Process lines in the wrapped group.
      _buildCharMappings(lines[i], i, charMappings, textBuf);
      i++;

      while (i < lineCount && lines[i].isWrapped) {
        _buildCharMappings(lines[i], i, charMappings, textBuf);
        i++;
      }

      final joinedText = textBuf.toString();
      if (joinedText.isEmpty) continue;

      // Find all matches in the joined text.
      for (final match in (pattern as RegExp).allMatches(joinedText)) {
        // Skip zero-length matches (from ^, \b, lookarounds, etc.)
        if (match.start == match.end) continue;

        final firstCharIdx = match.start;
        final lastCharIdx = match.end - 1; // inclusive

        if (firstCharIdx >= charMappings.length ||
            lastCharIdx >= charMappings.length) {
          continue;
        }

        final startMapping = charMappings[firstCharIdx];
        final endMapping = charMappings[lastCharIdx];

        results.add(TerminalSearchMatch(
          start: CellOffset(startMapping.startCell, startMapping.row),
          end: CellOffset(endMapping.endCell, endMapping.row),
        ));
      }
    }

    return results;
  }

  /// Build char-to-cell mappings for a single buffer line, mirroring the
  /// logic of `BufferLine.getText()` exactly (see line.dart:335).
  static void _buildCharMappings(
    BufferLine line,
    int absoluteRow,
    List<_CharMapping> charMappings,
    StringBuffer textBuf,
  ) {
    final trimmedLen = line.getTrimmedLength();
    var lastVisibleCell = 0;

    for (var cell = 0; cell < trimmedLen; cell++) {
      final codePoint = line.getCodePoint(cell);
      final width = line.getWidth(cell);

      if (codePoint != 0 && cell + width <= trimmedLen) {
        // This char will be emitted by getText() — matches line.dart:338.
        if (width > 0) lastVisibleCell = cell;

        // For width-0 combining marks: highlight span starts at the previous
        // visible cell (the base character), so the combined glyph is covered.
        final startCell = width == 0 ? lastVisibleCell : cell;
        final endCell = cell + (width > 1 ? width - 1 : 0);

        charMappings.add(_CharMapping(
          row: absoluteRow,
          startCell: startCell,
          endCell: endCell,
        ));
        textBuf.writeCharCode(codePoint);
      }
    }
  }
}
