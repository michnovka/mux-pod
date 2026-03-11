import 'package:flutter/material.dart';

import 'terminal_font_styles.dart';

/// ANSI text style
class AnsiStyle {
  final Color? foreground;
  final Color? background;
  final bool bold;
  final bool italic;
  final bool underline;
  final bool strikethrough;
  final bool dim;
  final bool inverse;

  const AnsiStyle({
    this.foreground,
    this.background,
    this.bold = false,
    this.italic = false,
    this.underline = false,
    this.strikethrough = false,
    this.dim = false,
    this.inverse = false,
  });

  AnsiStyle copyWith({
    Color? foreground,
    Color? background,
    bool? bold,
    bool? italic,
    bool? underline,
    bool? strikethrough,
    bool? dim,
    bool? inverse,
    bool clearForeground = false,
    bool clearBackground = false,
  }) {
    return AnsiStyle(
      foreground: clearForeground ? null : (foreground ?? this.foreground),
      background: clearBackground ? null : (background ?? this.background),
      bold: bold ?? this.bold,
      italic: italic ?? this.italic,
      underline: underline ?? this.underline,
      strikethrough: strikethrough ?? this.strikethrough,
      dim: dim ?? this.dim,
      inverse: inverse ?? this.inverse,
    );
  }

  static const AnsiStyle defaultStyle = AnsiStyle();
}

/// ANSI text segment
class AnsiSegment {
  final String text;
  final AnsiStyle style;

  const AnsiSegment(this.text, this.style);
}

/// Parsed line data
class ParsedLine {
  /// Line number (0-based)
  final int index;

  /// List of segments for this line
  final List<AnsiSegment> segments;

  /// Style at the end of this line (carried over to the next line)
  final AnsiStyle endStyle;

  const ParsedLine({
    required this.index,
    required this.segments,
    required this.endStyle,
  });

  /// Whether this is an empty line
  bool get isEmpty => segments.isEmpty || segments.every((s) => s.text.isEmpty);
}

/// ANSI escape sequence parser
///
/// Parser for converting capture-pane -e output (ANSI color text)
/// into TextSpan.
class AnsiParser {
  /// SGR (Select Graphic Rendition) pattern: ESC[...m
  static final _sgrRegex = RegExp(r'\x1b\[([0-9;]*)m');

  /// Standard 8 colors (normal)
  static const List<Color> standardColors = [
    Color(0xFF000000), // 0: Black
    Color(0xFFCD3131), // 1: Red
    Color(0xFF0DBC79), // 2: Green
    Color(0xFFE5E510), // 3: Yellow
    Color(0xFF2472C8), // 4: Blue
    Color(0xFFBC3FBC), // 5: Magenta
    Color(0xFF11A8CD), // 6: Cyan
    Color(0xFFE5E5E5), // 7: White
  ];

  /// Standard 8 colors (bright)
  static const List<Color> brightColors = [
    Color(0xFF666666), // 8: Bright Black
    Color(0xFFF14C4C), // 9: Bright Red
    Color(0xFF23D18B), // 10: Bright Green
    Color(0xFFF5F543), // 11: Bright Yellow
    Color(0xFF3B8EEA), // 12: Bright Blue
    Color(0xFFD670D6), // 13: Bright Magenta
    Color(0xFF29B8DB), // 14: Bright Cyan
    Color(0xFFFFFFFF), // 15: Bright White
  ];

  /// Default foreground color
  final Color defaultForeground;

  /// Default background color
  final Color defaultBackground;

  AnsiParser({
    this.defaultForeground = const Color(0xFFD4D4D4),
    this.defaultBackground = const Color(0xFF1E1E1E),
  });

  /// Decompose ANSI text into segments
  List<AnsiSegment> parse(String input) {
    final segments = <AnsiSegment>[];
    var currentStyle = AnsiStyle.defaultStyle;
    var lastEnd = 0;

    for (final match in _sgrRegex.allMatches(input)) {
      // Add text before the match
      if (match.start > lastEnd) {
        final text = input.substring(lastEnd, match.start);
        if (text.isNotEmpty) {
          segments.add(AnsiSegment(text, currentStyle));
        }
      }

      // Parse SGR parameters and update style
      final params = match.group(1) ?? '';
      currentStyle = _parseSgr(params, currentStyle);
      lastEnd = match.end;
    }

    // Add remaining text
    if (lastEnd < input.length) {
      final text = input.substring(lastEnd);
      if (text.isNotEmpty) {
        segments.add(AnsiSegment(text, currentStyle));
      }
    }

    return segments;
  }

  /// Parse SGR parameters and update style
  AnsiStyle _parseSgr(String params, AnsiStyle current) {
    if (params.isEmpty) {
      return AnsiStyle.defaultStyle;
    }

    final codes = params.split(';').map((s) => int.tryParse(s) ?? 0).toList();
    var style = current;
    var i = 0;

    while (i < codes.length) {
      final code = codes[i];

      switch (code) {
        case 0: // Reset
          style = AnsiStyle.defaultStyle;
          break;
        case 1: // Bold
          style = style.copyWith(bold: true);
          break;
        case 2: // Dim
          style = style.copyWith(dim: true);
          break;
        case 3: // Italic
          style = style.copyWith(italic: true);
          break;
        case 4: // Underline
          style = style.copyWith(underline: true);
          break;
        case 7: // Inverse
          style = style.copyWith(inverse: true);
          break;
        case 9: // Strikethrough
          style = style.copyWith(strikethrough: true);
          break;
        case 21: // Bold off (some terminals)
        case 22: // Bold and dim off
          style = style.copyWith(bold: false, dim: false);
          break;
        case 23: // Italic off
          style = style.copyWith(italic: false);
          break;
        case 24: // Underline off
          style = style.copyWith(underline: false);
          break;
        case 27: // Inverse off
          style = style.copyWith(inverse: false);
          break;
        case 29: // Strikethrough off
          style = style.copyWith(strikethrough: false);
          break;
        case 30:
        case 31:
        case 32:
        case 33:
        case 34:
        case 35:
        case 36:
        case 37:
          // Standard foreground color (30-37)
          style = style.copyWith(foreground: standardColors[code - 30]);
          break;
        case 38:
          // Extended foreground color
          if (i + 1 < codes.length) {
            if (codes[i + 1] == 5 && i + 2 < codes.length) {
              // 256-color mode: 38;5;n
              style = style.copyWith(foreground: _get256Color(codes[i + 2]));
              i += 2;
            } else if (codes[i + 1] == 2 && i + 4 < codes.length) {
              // 24-bit color: 38;2;r;g;b
              style = style.copyWith(
                foreground: Color.fromARGB(
                  255,
                  codes[i + 2].clamp(0, 255),
                  codes[i + 3].clamp(0, 255),
                  codes[i + 4].clamp(0, 255),
                ),
              );
              i += 4;
            }
          }
          break;
        case 39: // Default foreground color
          style = style.copyWith(clearForeground: true);
          break;
        case 40:
        case 41:
        case 42:
        case 43:
        case 44:
        case 45:
        case 46:
        case 47:
          // Standard background color (40-47)
          style = style.copyWith(background: standardColors[code - 40]);
          break;
        case 48:
          // Extended background color
          if (i + 1 < codes.length) {
            if (codes[i + 1] == 5 && i + 2 < codes.length) {
              // 256-color mode: 48;5;n
              style = style.copyWith(background: _get256Color(codes[i + 2]));
              i += 2;
            } else if (codes[i + 1] == 2 && i + 4 < codes.length) {
              // 24-bit color: 48;2;r;g;b
              style = style.copyWith(
                background: Color.fromARGB(
                  255,
                  codes[i + 2].clamp(0, 255),
                  codes[i + 3].clamp(0, 255),
                  codes[i + 4].clamp(0, 255),
                ),
              );
              i += 4;
            }
          }
          break;
        case 49: // Default background color
          style = style.copyWith(clearBackground: true);
          break;
        case 90:
        case 91:
        case 92:
        case 93:
        case 94:
        case 95:
        case 96:
        case 97:
          // Bright foreground color (90-97)
          style = style.copyWith(foreground: brightColors[code - 90]);
          break;
        case 100:
        case 101:
        case 102:
        case 103:
        case 104:
        case 105:
        case 106:
        case 107:
          // Bright background color (100-107)
          style = style.copyWith(background: brightColors[code - 100]);
          break;
      }
      i++;
    }

    return style;
  }

  /// Get color from the 256-color palette
  Color _get256Color(int index) {
    if (index < 0 || index > 255) {
      return defaultForeground;
    }

    // 0-7: Standard colors
    if (index < 8) {
      return standardColors[index];
    }

    // 8-15: Bright colors
    if (index < 16) {
      return brightColors[index - 8];
    }

    // 16-231: 6x6x6 color cube
    if (index < 232) {
      final n = index - 16;
      final r = (n ~/ 36) % 6;
      final g = (n ~/ 6) % 6;
      final b = n % 6;
      return Color.fromARGB(
        255,
        r > 0 ? (r * 40 + 55) : 0,
        g > 0 ? (g * 40 + 55) : 0,
        b > 0 ? (b * 40 + 55) : 0,
      );
    }

    // 232-255: Grayscale
    final gray = (index - 232) * 10 + 8;
    return Color.fromARGB(255, gray, gray, gray);
  }

  /// Convert segments to TextSpan
  TextSpan toTextSpan(
    List<AnsiSegment> segments, {
    required double fontSize,
    required String fontFamily,
  }) {
    return TextSpan(
      children: segments.map((segment) {
        final style = segment.style;
        var fg = style.foreground ?? defaultForeground;
        var bg = style.background ?? defaultBackground;

        // Inverse
        if (style.inverse) {
          final temp = fg;
          fg = bg;
          bg = temp;
        }

        // Dim
        if (style.dim) {
          fg = fg.withValues(alpha: 0.5);
        }

        // Replace spaces with No-Break Space when inverted, as background color may not render for spaces
        String text = segment.text;
        if (style.inverse) {
          text = text.replaceAll(' ', '\u00A0');
        }

        return TextSpan(
          text: text,
          style: TerminalFontStyles.getTextStyle(
            fontFamily,
            fontSize: fontSize,
            color: fg,
            backgroundColor: (style.inverse || bg != defaultBackground) ? bg : null,
            fontWeight: style.bold ? FontWeight.bold : FontWeight.normal,
            fontStyle: style.italic ? FontStyle.italic : FontStyle.normal,
            decoration: TextDecoration.combine([
              if (style.underline) TextDecoration.underline,
              if (style.strikethrough) TextDecoration.lineThrough,
            ]),
          ),
        );
      }).toList(),
    );
  }

  /// Convert ANSI text directly to TextSpan
  TextSpan parseToTextSpan(
    String input, {
    required double fontSize,
    required String fontFamily,
  }) {
    final segments = parse(input);
    return toTextSpan(segments, fontSize: fontSize, fontFamily: fontFamily);
  }

  /// Parse line by line (for virtual scrolling)
  ///
  /// Parses each line individually and carries styles over to the next line.
  /// The returned [ParsedLine] list is used for line-by-line rendering in virtual scrolling.
  List<ParsedLine> parseLines(String input) {
    final lines = input.split('\n');
    final parsedLines = <ParsedLine>[];
    var currentStyle = AnsiStyle.defaultStyle;

    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      final result = _parseLineWithStyle(line, currentStyle);
      parsedLines.add(ParsedLine(
        index: i,
        segments: result.segments,
        endStyle: result.endStyle,
      ));
      currentStyle = result.endStyle;
    }

    return parsedLines;
  }

  /// Parse a single line and return segments and end style
  ({List<AnsiSegment> segments, AnsiStyle endStyle}) _parseLineWithStyle(
    String line,
    AnsiStyle startStyle,
  ) {
    final segments = <AnsiSegment>[];
    var currentStyle = startStyle;
    var lastEnd = 0;

    for (final match in _sgrRegex.allMatches(line)) {
      // Add text before the match
      if (match.start > lastEnd) {
        final text = line.substring(lastEnd, match.start);
        if (text.isNotEmpty) {
          segments.add(AnsiSegment(text, currentStyle));
        }
      }

      // Parse SGR parameters and update style
      final params = match.group(1) ?? '';
      currentStyle = _parseSgr(params, currentStyle);
      lastEnd = match.end;
    }

    // Add remaining text
    if (lastEnd < line.length) {
      final text = line.substring(lastEnd);
      if (text.isNotEmpty) {
        segments.add(AnsiSegment(text, currentStyle));
      }
    }

    return (segments: segments, endStyle: currentStyle);
  }

  /// Convert ParsedLine to TextSpan
  TextSpan lineToTextSpan(
    ParsedLine line, {
    required double fontSize,
    required String fontFamily,
  }) {
    return toTextSpan(line.segments, fontSize: fontSize, fontFamily: fontFamily);
  }
}
