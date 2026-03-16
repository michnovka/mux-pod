import 'package:xterm/xterm.dart';

/// A URL detected in terminal buffer content.
class DetectedUrl {
  final String url;
  final CellOffset start;
  final CellOffset end;

  const DetectedUrl({
    required this.url,
    required this.start,
    required this.end,
  });

  BufferRangeLine get range => BufferRangeLine(start, end);

  bool containsOffset(CellOffset offset) => range.contains(offset);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DetectedUrl &&
          url == other.url &&
          start == other.start &&
          end == other.end;

  @override
  int get hashCode => Object.hash(url, start, end);
}

/// Scans terminal buffer lines for URLs.
class TerminalUrlDetector {
  /// Matches http:// and https:// URLs.
  /// Excludes surrounding quotes, brackets, and trailing punctuation.
  static final _urlPattern = RegExp(
    r'https?://[^\s<>"' "'" r'{}\[\]|\\^`]+[^\s<>"' "'" r'{}\[\]|\\^`.,;:!?\-)}\]]',
  );

  /// Expose pattern for testing.
  static RegExp get urlPattern => _urlPattern;

  /// Scan a range of buffer lines for URLs.
  ///
  /// [buffer] is the terminal buffer.
  /// [firstLine] and [lastLine] are inclusive absolute row indices.
  /// Handles wrapped lines by joining them before scanning.
  static List<DetectedUrl> scanLines(
    Buffer buffer,
    int firstLine,
    int lastLine,
  ) {
    final lines = buffer.lines;
    final lineCount = lines.length;
    if (lineCount == 0 || firstLine > lastLine) return const [];

    final effectFirst = firstLine.clamp(0, lineCount - 1);
    final effectLast = lastLine.clamp(0, lineCount - 1);

    final results = <DetectedUrl>[];
    var i = effectFirst;

    // Walk backward from effectFirst to find the start of a wrapped-line group
    // that begins above the viewport.
    while (i > 0 && lines[i].isWrapped) {
      i--;
    }

    while (i <= effectLast) {
      // Collect a logical line (possibly spanning multiple wrapped lines).
      final groupStart = i;
      final lineTexts = <String>[];
      final lineLengths = <int>[];

      // First line of the group.
      final firstLineText = _getLineText(lines[i]);
      lineTexts.add(firstLineText);
      lineLengths.add(firstLineText.length);
      i++;

      // Continue through wrapped continuation lines.
      while (i < lineCount && lines[i].isWrapped) {
        final text = _getLineText(lines[i]);
        lineTexts.add(text);
        lineLengths.add(text.length);
        i++;
      }

      // Join all lines in the group into a single string for regex scanning.
      final joinedText = lineTexts.join();
      if (joinedText.isEmpty) continue;

      // Find all URL matches.
      for (final match in _urlPattern.allMatches(joinedText)) {
        final url = match.group(0)!;
        final startChar = match.start;
        final endChar = match.end - 1; // inclusive

        final startPos = _charOffsetToCell(startChar, lineLengths, groupStart);
        final endPos = _charOffsetToCell(endChar, lineLengths, groupStart);

        results.add(DetectedUrl(url: url, start: startPos, end: endPos));
      }
    }

    return results;
  }

  /// Scan a plain text string for URLs. Useful for testing the regex
  /// without constructing a Buffer.
  static List<DetectedUrl> scanText(String text, {int row = 0}) {
    final results = <DetectedUrl>[];
    for (final match in _urlPattern.allMatches(text)) {
      final url = match.group(0)!;
      results.add(DetectedUrl(
        url: url,
        start: CellOffset(match.start, row),
        end: CellOffset(match.end - 1, row),
      ));
    }
    return results;
  }

  /// Returns the URL at [offset], or null if none.
  static DetectedUrl? getUrlAt(List<DetectedUrl> urls, CellOffset offset) {
    for (final url in urls) {
      if (url.containsOffset(offset)) return url;
    }
    return null;
  }

  /// Extract text from a buffer line using getTrimmedLength for accurate width.
  static String _getLineText(BufferLine line) {
    final len = line.getTrimmedLength();
    if (len == 0) return '';
    return line.getText(0, len);
  }

  /// Convert a character offset within a joined multi-line string back to
  /// a (col, row) CellOffset.
  static CellOffset _charOffsetToCell(
    int charOffset,
    List<int> lineLengths,
    int groupStartRow,
  ) {
    var remaining = charOffset;
    for (var lineIdx = 0; lineIdx < lineLengths.length; lineIdx++) {
      if (remaining < lineLengths[lineIdx] || lineIdx == lineLengths.length - 1) {
        return CellOffset(remaining, groupStartRow + lineIdx);
      }
      remaining -= lineLengths[lineIdx];
    }
    // Fallback (should not reach here).
    return CellOffset(charOffset, groupStartRow);
  }
}
