import 'dart:developer' as developer;

import 'package:flutter/painting.dart';
import 'terminal_font_styles.dart';

/// Font size calculation result
typedef FontCalculateResult = ({double fontSize, bool needsScroll});

/// Terminal font size calculation service
///
/// Calculates the optimal font size from pane character width and screen width.
class FontCalculator {
  /// Default font size
  static const double defaultFontSize = 14.0;

  /// Character width ratio cache (font family -> ratio)
  static final Map<String, double> _charWidthRatioCache = {};

  /// Default pane width (in characters)
  static const int defaultPaneWidth = 80;

  /// Minimum pane width (in characters) - panes narrower than this are clamped to this value
  static const int minPaneWidth = 10;

  /// Calculate font size from screen width and pane character count
  ///
  /// [screenWidth] Available screen width (pixels)
  /// [paneCharWidth] Pane width (in characters)
  /// [fontFamily] Font family
  /// [minFontSize] Minimum font size (lower bound)
  ///
  /// Returns: (fontSize, needsScroll) Record
  static FontCalculateResult calculate({
    required double screenWidth,
    required int paneCharWidth,
    required String fontFamily,
    required double minFontSize,
  }) {
    // T031: Fall back to default 80 if pane width is 0 or less
    int effectivePaneWidth = paneCharWidth;
    if (paneCharWidth <= 0) {
      developer.log(
        'Invalid pane width ($paneCharWidth), using default: $defaultPaneWidth',
        name: 'FontCalculator',
      );
      effectivePaneWidth = defaultPaneWidth;
    }
    // T032: Clamp extremely narrow panes (less than 10 characters) to minimum
    else if (paneCharWidth < minPaneWidth) {
      developer.log(
        'Narrow pane ($paneCharWidth chars), clamping to minimum: $minPaneWidth',
        name: 'FontCalculator',
      );
      effectivePaneWidth = minPaneWidth;
    }

    // Return default value for invalid screen width
    if (screenWidth <= 0) {
      developer.log(
        'Invalid screen width ($screenWidth), returning default font size',
        name: 'FontCalculator',
      );
      return (fontSize: defaultFontSize, needsScroll: false);
    }

    // Measure character width ratio
    final charWidthRatio = measureCharWidthRatio(fontFamily);

    // Calculate: fontSize = screenWidth / (paneWidth x charWidthRatio)
    final calculatedSize = screenWidth / (effectivePaneWidth * charWidthRatio);

    final FontCalculateResult result;
    if (calculatedSize >= minFontSize) {
      result = (fontSize: calculatedSize, needsScroll: false);
    } else {
      // Horizontal scrolling is needed when below minimum font size
      result = (fontSize: minFontSize, needsScroll: true);
    }

    // T034: Log font size calculation result
    developer.log(
      'Calculated: screen=${screenWidth.toStringAsFixed(1)}px, '
      'pane=${effectivePaneWidth}chars, '
      'fontSize=${result.fontSize.toStringAsFixed(2)}pt, '
      'scroll=${result.needsScroll}',
      name: 'FontCalculator',
    );

    return result;
  }

  /// Measure character width ratio for a font family (uses cache)
  ///
  /// For monospace fonts, character width = fontSize x charWidthRatio
  /// Measures at a base font size of 100 and returns the ratio.
  /// For improved accuracy, measures the width of 10 characters and takes the average.
  static double measureCharWidthRatio(String fontFamily) {
    // Retrieve from cache
    if (_charWidthRatioCache.containsKey(fontFamily)) {
      return _charWidthRatioCache[fontFamily]!;
    }

    const baseFontSize = 100.0;
    // Even monospace fonts may have slightly different metrics for digits and letters,
    // so include typical patterns and take the average
    const testString = '0123456789';

    final painter = TextPainter(
      text: TextSpan(
        text: testString,
        style: TerminalFontStyles.getTextStyle(fontFamily, fontSize: baseFontSize),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    // Calculate average width
    // There were reports of a 0.8 character leftward shift (charWidth too small),
    // so we considered adding a tiny buffer (0.01%) to prevent calculated results from being too small,
    // but we expect natural correction by including not just 'M' (wide) but also '0' (standard).
    // If that's still insufficient, offset adjustment would be needed, but first we try changing the test characters.
    final ratio = (painter.width / testString.length) / baseFontSize;

    // Save to cache
    _charWidthRatioCache[fontFamily] = ratio;

    developer.log(
      'Cached char width ratio for "$fontFamily": $ratio',
      name: 'FontCalculator',
    );

    return ratio;
  }

  /// Clear cache (for testing or when font changes)
  static void clearCache() {
    _charWidthRatioCache.clear();
  }

  /// Calculate the terminal display width (pixels)
  ///
  /// Used for sizing the horizontal scroll container.
  static double calculateTerminalWidth({
    required int paneCharWidth,
    required double fontSize,
    required String fontFamily,
  }) {
    final charWidthRatio = measureCharWidthRatio(fontFamily);
    return paneCharWidth * charWidthRatio * fontSize;
  }

  /// Calculate the ideal column count to fit the available screen width.
  ///
  /// [availableWidth] Available screen width (pixels)
  /// [fontSize] The font size to use for measurement
  /// [fontFamily] Font family
  ///
  /// Returns the number of columns that fit, clamped to [20, 500].
  static int calculateFitColumns({
    required double availableWidth,
    required double fontSize,
    required String fontFamily,
  }) {
    final charWidth = measureCharWidth(fontFamily, fontSize);
    if (charWidth <= 0) return 80; // fallback
    return (availableWidth / charWidth).floor().clamp(20, 500);
  }

  /// Measure exact character width at the specified font size
  ///
  /// Accounts for non-linear scaling due to hinting and pixel alignment
  /// by measuring at the actual font size in use.
  static double measureCharWidth(String fontFamily, double fontSize) {
    const testString = '0123456789';
    final painter = TextPainter(
      text: TextSpan(
        text: testString,
        style: TerminalFontStyles.getTextStyle(fontFamily, fontSize: fontSize),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    return painter.width / testString.length;
  }

  /// Convert terminal column position (cursorX) to code unit offset
  ///
  /// Full-width characters (Japanese, Chinese, Korean, etc.) occupy 2 columns,
  /// so tmux's cursor_x (column position) differs from the character count.
  /// This function calculates the correct code unit offset from the column position.
  ///
  /// Also considers emoji variation selectors (VS16, etc.) and performs
  /// accurate conversion at the grapheme cluster level.
  ///
  /// Note: Characters outside the BMP (emoji, etc.) use 2 code units as
  /// surrogate pairs, so this returns code unit count rather than rune count.
  ///
  /// [text] The target text
  /// [columnPosition] Terminal column position (0-based)
  ///
  /// Returns: Code unit offset (value to pass to TextPosition)
  static int columnToCharOffset(String text, int columnPosition) {
    int currentColumn = 0;
    int codeUnitOffset = 0;
    final runes = text.runes.toList();

    int i = 0;
    while (i < runes.length) {
      if (currentColumn >= columnPosition) {
        break;
      }

      final rune = runes[i];
      // Look ahead to the next code point (for VS16 check)
      final nextRune = (i + 1 < runes.length) ? runes[i + 1] : null;

      final charWidth = getCharDisplayWidthWithContext(rune, nextRune);
      currentColumn += charWidth;
      // Characters outside BMP (U+10000+) use 2 code units, others use 1
      codeUnitOffset += _runeCodeUnitCount(rune);
      i++;
    }

    // Skip subsequent zero-width characters (VS16, combining characters, etc.)
    // These are rendered together with the preceding character, so TextPosition
    // needs to point after them
    while (i < runes.length) {
      final rune = runes[i];
      final nextRune = (i + 1 < runes.length) ? runes[i + 1] : null;
      if (getCharDisplayWidthWithContext(rune, nextRune) > 0) {
        break;
      }
      codeUnitOffset += _runeCodeUnitCount(rune);
      i++;
    }

    return codeUnitOffset;
  }

  /// Get the number of code units for a rune
  ///
  /// Characters within the BMP (Basic Multilingual Plane, U+0000-U+FFFF) use 1 code unit,
  /// characters outside the BMP (U+10000+, emoji, etc.) use 2 code units (surrogate pair).
  static int _runeCodeUnitCount(int rune) {
    return rune > 0xFFFF ? 2 : 1;
  }

  /// Get the terminal display width of a character (with context)
  ///
  /// If the next code point is VS16 (U+FE0F), returns width 2
  /// as emoji style.
  static int getCharDisplayWidthWithContext(int codePoint, int? nextCodePoint) {
    // Zero-width characters (combining characters, variation selectors, etc.)
    if (_isZeroWidthChar(codePoint)) {
      return 0;
    }

    // When followed by VS16 (emoji style), many characters become width 2
    if (nextCodePoint == 0xFE0F) {
      // Characters already width 2 stay as-is
      final baseWidth = getCharDisplayWidth(codePoint);
      if (baseWidth == 2) return 2;
      // Characters that become emoji display with VS16 are width 2
      if (_canBeEmoji(codePoint)) return 2;
    }

    return getCharDisplayWidth(codePoint);
  }

  /// Determine if a character is zero-width
  static bool _isZeroWidthChar(int codePoint) {
    // Control characters
    if (codePoint < 0x20) return true;
    if (codePoint >= 0x7F && codePoint < 0xA0) return true;

    // Variation Selectors
    if (codePoint >= 0xFE00 && codePoint <= 0xFE0F) return true;
    // Variation Selectors Supplement
    if (codePoint >= 0xE0100 && codePoint <= 0xE01EF) return true;

    // Zero Width Joiner / Non-Joiner
    if (codePoint == 0x200D || codePoint == 0x200C) return true;
    // Zero Width Space
    if (codePoint == 0x200B) return true;
    // Word Joiner
    if (codePoint == 0x2060) return true;

    // Combining Diacritical Marks
    if (codePoint >= 0x0300 && codePoint <= 0x036F) return true;
    // Combining Diacritical Marks Extended
    if (codePoint >= 0x1AB0 && codePoint <= 0x1AFF) return true;
    if (codePoint >= 0x1DC0 && codePoint <= 0x1DFF) return true;
    if (codePoint >= 0x20D0 && codePoint <= 0x20FF) return true;
    if (codePoint >= 0xFE20 && codePoint <= 0xFE2F) return true;

    // Skin tone modifiers for Regional Indicators
    if (codePoint >= 0x1F3FB && codePoint <= 0x1F3FF) return true;

    return false;
  }

  /// Determine if a character can become emoji display with VS16
  static bool _canBeEmoji(int codePoint) {
    // Miscellaneous Symbols
    if (codePoint >= 0x2600 && codePoint <= 0x26FF) return true;
    // Dingbats
    if (codePoint >= 0x2700 && codePoint <= 0x27BF) return true;
    // Miscellaneous Symbols and Pictographs
    if (codePoint >= 0x1F300 && codePoint <= 0x1F5FF) return true;
    // Emoticons
    if (codePoint >= 0x1F600 && codePoint <= 0x1F64F) return true;
    // Transport and Map Symbols
    if (codePoint >= 0x1F680 && codePoint <= 0x1F6FF) return true;
    // Supplemental Symbols and Pictographs
    if (codePoint >= 0x1F900 && codePoint <= 0x1F9FF) return true;
    // Symbols and Pictographs Extended-A
    if (codePoint >= 0x1FA00 && codePoint <= 0x1FA6F) return true;
    // Symbols and Pictographs Extended-B
    if (codePoint >= 0x1FA70 && codePoint <= 0x1FAFF) return true;
    // Other symbols that can become emoji
    if (codePoint >= 0x2300 && codePoint <= 0x23FF) return true; // Misc Technical
    if (codePoint >= 0x2B50 && codePoint <= 0x2B55) return true; // Stars etc
    // For number keycaps
    if (codePoint >= 0x0023 && codePoint <= 0x0039) return true; // # 0-9
    // Other dual text/emoji symbols
    if (codePoint == 0x00A9 || codePoint == 0x00AE) return true; // © ®
    if (codePoint == 0x2122) return true; // ™
    if (codePoint >= 0x2194 && codePoint <= 0x21AA) return true; // Arrows
    if (codePoint >= 0x231A && codePoint <= 0x231B) return true; // Watch, Hourglass
    if (codePoint >= 0x25AA && codePoint <= 0x25AB) return true; // Squares
    if (codePoint >= 0x25B6 && codePoint <= 0x25C0) return true; // Triangles
    if (codePoint >= 0x25FB && codePoint <= 0x25FE) return true; // Squares
    if (codePoint == 0x2614 || codePoint == 0x2615) return true; // Umbrella, Hot Beverage
    if (codePoint >= 0x2648 && codePoint <= 0x2653) return true; // Zodiac
    if (codePoint == 0x267F) return true; // Wheelchair
    if (codePoint == 0x2693) return true; // Anchor
    if (codePoint == 0x26A1) return true; // High Voltage
    if (codePoint >= 0x26AA && codePoint <= 0x26AB) return true; // Circles
    if (codePoint >= 0x26BD && codePoint <= 0x26BE) return true; // Sports
    if (codePoint >= 0x26C4 && codePoint <= 0x26C5) return true; // Weather
    if (codePoint == 0x26CE) return true; // Ophiuchus
    if (codePoint == 0x26D4) return true; // No Entry
    if (codePoint == 0x26EA) return true; // Church
    if (codePoint >= 0x26F2 && codePoint <= 0x26F3) return true; // Fountain, Golf
    if (codePoint == 0x26F5) return true; // Sailboat
    if (codePoint == 0x26FA) return true; // Tent
    if (codePoint == 0x26FD) return true; // Fuel Pump
    if (codePoint >= 0x2702 && codePoint <= 0x2709) return true; // Office items
    if (codePoint >= 0x270A && codePoint <= 0x270D) return true; // Hands
    if (codePoint == 0x270F) return true; // Pencil
    if (codePoint >= 0x2712 && codePoint <= 0x2714) return true; // Writing
    if (codePoint == 0x2716) return true; // X Mark
    if (codePoint >= 0x271D && codePoint <= 0x2721) return true; // Religious symbols
    if (codePoint == 0x2728) return true; // Sparkles
    if (codePoint >= 0x2733 && codePoint <= 0x2734) return true; // Asterisks
    if (codePoint == 0x2744) return true; // Snowflake
    if (codePoint == 0x2747) return true; // Sparkle
    if (codePoint >= 0x274C && codePoint <= 0x274E) return true; // X marks
    if (codePoint >= 0x2753 && codePoint <= 0x2755) return true; // Question marks
    if (codePoint == 0x2757) return true; // Exclamation
    if (codePoint >= 0x2763 && codePoint <= 0x2764) return true; // Hearts
    if (codePoint >= 0x2795 && codePoint <= 0x2797) return true; // Math
    if (codePoint == 0x27A1) return true; // Arrow
    if (codePoint == 0x27B0) return true; // Curly Loop
    if (codePoint == 0x27BF) return true; // Double Curly Loop
    if (codePoint >= 0x2934 && codePoint <= 0x2935) return true; // Arrows
    if (codePoint >= 0x2B05 && codePoint <= 0x2B07) return true; // Arrows
    if (codePoint >= 0x2B1B && codePoint <= 0x2B1C) return true; // Squares
    if (codePoint == 0x3030) return true; // Wavy Dash
    if (codePoint == 0x303D) return true; // Part Alternation Mark
    if (codePoint == 0x3297) return true; // Circled Ideograph Congratulation
    if (codePoint == 0x3299) return true; // Circled Ideograph Secret

    return false;
  }

  /// Get the terminal display width of a character (0, 1, or 2)
  ///
  /// Based on the Unicode East Asian Width property,
  /// returns 2 for full-width characters, 1 for half-width, and 0 for combining characters, etc.
  static int getCharDisplayWidth(int codePoint) {
    // Zero-width characters
    if (_isZeroWidthChar(codePoint)) {
      return 0;
    }

    // Full-width character detection (East Asian Width: F, W, some A)
    // CJK Unified Ideographs
    if (codePoint >= 0x4E00 && codePoint <= 0x9FFF) return 2;
    // CJK Unified Ideographs Extension A
    if (codePoint >= 0x3400 && codePoint <= 0x4DBF) return 2;
    // CJK Unified Ideographs Extension B-G
    if (codePoint >= 0x20000 && codePoint <= 0x3FFFF) return 2;
    // Hiragana
    if (codePoint >= 0x3040 && codePoint <= 0x309F) return 2;
    // Katakana
    if (codePoint >= 0x30A0 && codePoint <= 0x30FF) return 2;
    // Halfwidth and Fullwidth Forms (fullwidth portion)
    if (codePoint >= 0xFF01 && codePoint <= 0xFF60) return 2;
    if (codePoint >= 0xFFE0 && codePoint <= 0xFFE6) return 2;
    // Korean (Hangul Syllables)
    if (codePoint >= 0xAC00 && codePoint <= 0xD7AF) return 2;
    // Korean (Hangul Jamo)
    if (codePoint >= 0x1100 && codePoint <= 0x11FF) return 2;
    if (codePoint >= 0x3130 && codePoint <= 0x318F) return 2;
    // CJK Symbols and Punctuation
    if (codePoint >= 0x3000 && codePoint <= 0x303F) return 2;
    // CJK Compatibility Characters
    if (codePoint >= 0x3300 && codePoint <= 0x33FF) return 2;
    if (codePoint >= 0xFE30 && codePoint <= 0xFE4F) return 2;
    // Enclosed CJK Letters and Months
    if (codePoint >= 0x3200 && codePoint <= 0x32FF) return 2;
    // Emoji (generally width 2)
    if (codePoint >= 0x1F300 && codePoint <= 0x1F9FF) return 2;
    if (codePoint >= 0x1FA00 && codePoint <= 0x1FAFF) return 2;

    // Everything else is half-width
    return 1;
  }

  /// Calculate the terminal display width (column count) of text
  ///
  /// Performs accurate width calculation considering variation selectors (VS16, etc.).
  static int getTextDisplayWidth(String text) {
    int width = 0;
    final runes = text.runes.toList();

    for (int i = 0; i < runes.length; i++) {
      final rune = runes[i];
      final nextRune = (i + 1 < runes.length) ? runes[i + 1] : null;
      width += getCharDisplayWidthWithContext(rune, nextRune);
    }

    return width;
  }
}
