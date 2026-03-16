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

/// Maps a UTF-16 code unit offset back to a cell position.
///
/// One entry per code unit (not per code point). Astral-plane characters
/// (code point > 0xFFFF) produce two entries — one for the high surrogate
/// and one for the low surrogate — both pointing to the same cell range.
class _Utf16CellMapping {
  final int row;
  final int startCell;
  final int endCell;

  const _Utf16CellMapping({
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
      final utf16Mappings = <_Utf16CellMapping>[];
      final textBuf = StringBuffer();

      // Process lines in the wrapped group.
      _buildUtf16Mappings(lines[i], i, utf16Mappings, textBuf);
      i++;

      while (i < lineCount && lines[i].isWrapped) {
        _buildUtf16Mappings(lines[i], i, utf16Mappings, textBuf);
        i++;
      }

      final joinedText = textBuf.toString();
      if (joinedText.isEmpty) continue;

      // Find all matches in the joined text.
      // RegExpMatch.start/end are UTF-16 code unit offsets, which is what
      // our utf16Mappings array is indexed by.
      for (final match in (pattern as RegExp).allMatches(joinedText)) {
        // Skip zero-length matches (from ^, \b, lookarounds, etc.)
        if (match.start == match.end) continue;

        final firstUtf16Idx = match.start;
        final lastUtf16Idx = match.end - 1; // inclusive

        if (firstUtf16Idx >= utf16Mappings.length ||
            lastUtf16Idx >= utf16Mappings.length) {
          continue;
        }

        final startMapping = utf16Mappings[firstUtf16Idx];
        final endMapping = utf16Mappings[lastUtf16Idx];

        results.add(TerminalSearchMatch(
          start: CellOffset(startMapping.startCell, startMapping.row),
          end: CellOffset(endMapping.endCell, endMapping.row),
        ));
      }
    }

    return results;
  }

  /// Build UTF-16-code-unit-to-cell mappings for a single buffer line.
  ///
  /// Mirrors the emit logic of `BufferLine.getText()` (line.dart:335) but
  /// extends past `getTrimmedLength()` to include trailing width-0 combining
  /// marks that xterm's trimmed-length calculation excludes.
  ///
  /// For each code point emitted, we append one [_Utf16CellMapping] per
  /// UTF-16 code unit the code point produces (1 for BMP, 2 for astral).
  /// This ensures `RegExpMatch` offsets (which are UTF-16 code unit offsets)
  /// index directly into the mapping array.
  static void _buildUtf16Mappings(
    BufferLine line,
    int absoluteRow,
    List<_Utf16CellMapping> mappings,
    StringBuffer textBuf,
  ) {
    final trimmedLen = line.getTrimmedLength();

    // Extend scan past trimmedLen to include trailing width-0 combining
    // marks.  getTrimmedLength() returns `i + width` for the last non-zero
    // cell; a trailing combining mark (width=0) at cell N gives N+0=N,
    // which excludes that cell from the trimmed range.
    var scanLen = trimmedLen;
    final lineLen = line.length;
    while (scanLen < lineLen) {
      final cp = line.getCodePoint(scanLen);
      final w = line.getWidth(scanLen);
      if (cp != 0 && w == 0) {
        scanLen++;
      } else {
        break;
      }
    }

    var lastVisibleCell = 0;

    for (var cell = 0; cell < scanLen; cell++) {
      final codePoint = line.getCodePoint(cell);
      final width = line.getWidth(cell);

      // For cells within trimmedLen, mirror getText()'s condition exactly.
      // For cells beyond trimmedLen (trailing combining marks), they always
      // have width==0, so cell + 0 <= scanLen is always true.
      if (codePoint != 0 && cell + width <= scanLen) {
        if (width > 0) lastVisibleCell = cell;

        // For width-0 combining marks: highlight span starts at the previous
        // visible cell (the base character), so the combined glyph is covered.
        final startCell = width == 0 ? lastVisibleCell : cell;
        final endCell = cell + (width > 1 ? width - 1 : 0);

        final mapping = _Utf16CellMapping(
          row: absoluteRow,
          startCell: startCell,
          endCell: endCell,
        );

        // Astral-plane code points (> 0xFFFF) encode as a surrogate pair
        // (2 UTF-16 code units) in Dart strings, but occupy one cell in the
        // buffer.  Add one mapping entry per code unit so that
        // RegExpMatch.start/end (which are UTF-16 offsets) index correctly.
        if (codePoint > 0xFFFF) {
          mappings.add(mapping); // high surrogate
          mappings.add(mapping); // low surrogate
        } else {
          mappings.add(mapping);
        }

        textBuf.writeCharCode(codePoint);
      }
    }
  }
}
