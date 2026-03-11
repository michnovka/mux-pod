import 'package:flutter/painting.dart';
import 'package:google_fonts/google_fonts.dart';

/// Monospace font styles for terminal
///
/// Provides a unified way to retrieve Google Fonts monospace fonts
/// and bundled Japanese-compatible fonts.
class TerminalFontStyles {
  TerminalFontStyles._();

  /// Family names of bundled fonts (Japanese-compatible)
  static const List<String> _bundledFontFamilies = [
    'HackGen Console',
    'UDEV Gothic NF',
  ];

  /// Font fallback (for special symbols and emoji)
  /// Falls back to fonts that support Nerd Fonts and symbols
  static const List<String> _fontFamilyFallback = [
    'Noto Sans Symbols 2',
    'Noto Color Emoji',
    'Symbols Nerd Font',
    'Noto Sans Symbols',
  ];

  /// List of supported font families
  static const List<String> supportedFontFamilies = [
    'JetBrains Mono',
    'Fira Code',
    'Source Code Pro',
    'Roboto Mono',
    'Ubuntu Mono',
    'Inconsolata',
    'HackGen Console',
    'UDEV Gothic NF',
  ];

  /// Default font family
  static const String defaultFontFamily = 'JetBrains Mono';

  /// Mapping from display names to bundled font names
  static const Map<String, String> _bundledFontMap = {
    'HackGen Console': 'HackGenConsole',
    'UDEV Gothic NF': 'UDEVGothicNF',
  };

  /// Get TextStyle from font family name
  ///
  /// [fontFamily] Font family name
  /// [fontSize] Font size
  /// [height] Line height ratio
  /// [color] Text color
  /// [backgroundColor] Background color
  /// [fontWeight] Font weight
  /// [fontStyle] Font style (italic, etc.)
  /// [decoration] Text decoration (underline, strikethrough, etc.)
  static TextStyle getTextStyle(
    String fontFamily, {
    double? fontSize,
    double? height,
    Color? color,
    Color? backgroundColor,
    FontWeight? fontWeight,
    FontStyle? fontStyle,
    TextDecoration? decoration,
  }) {
    // For bundled fonts (Japanese-compatible)
    if (_bundledFontFamilies.contains(fontFamily)) {
      return TextStyle(
        inherit: false, // Disable style inheritance to stabilize metrics
        fontFamily: _bundledFontMap[fontFamily],
        fontFamilyFallback: _fontFamilyFallback,
        fontSize: fontSize,
        height: height,
        color: color,
        backgroundColor: backgroundColor,
        fontWeight: fontWeight,
        fontStyle: fontStyle,
        decoration: decoration,
      );
    }

    // For Google Fonts
    TextStyle baseStyle;
    switch (fontFamily) {
      case 'JetBrains Mono':
        baseStyle = GoogleFonts.jetBrainsMono(
          fontSize: fontSize,
          height: height,
          color: color,
          backgroundColor: backgroundColor,
          fontWeight: fontWeight,
          fontStyle: fontStyle,
          decoration: decoration,
        );
        break;
      case 'Fira Code':
        baseStyle = GoogleFonts.firaCode(
          fontSize: fontSize,
          height: height,
          color: color,
          backgroundColor: backgroundColor,
          fontWeight: fontWeight,
          fontStyle: fontStyle,
          decoration: decoration,
        );
        break;
      case 'Source Code Pro':
        baseStyle = GoogleFonts.sourceCodePro(
          fontSize: fontSize,
          height: height,
          color: color,
          backgroundColor: backgroundColor,
          fontWeight: fontWeight,
          fontStyle: fontStyle,
          decoration: decoration,
        );
        break;
      case 'Roboto Mono':
        baseStyle = GoogleFonts.robotoMono(
          fontSize: fontSize,
          height: height,
          color: color,
          backgroundColor: backgroundColor,
          fontWeight: fontWeight,
          fontStyle: fontStyle,
          decoration: decoration,
        );
        break;
      case 'Ubuntu Mono':
        baseStyle = GoogleFonts.ubuntuMono(
          fontSize: fontSize,
          height: height,
          color: color,
          backgroundColor: backgroundColor,
          fontWeight: fontWeight,
          fontStyle: fontStyle,
          decoration: decoration,
        );
        break;
      case 'Inconsolata':
        baseStyle = GoogleFonts.inconsolata(
          fontSize: fontSize,
          height: height,
          color: color,
          backgroundColor: backgroundColor,
          fontWeight: fontWeight,
          fontStyle: fontStyle,
          decoration: decoration,
        );
        break;
      default:
        // Default is JetBrains Mono
        baseStyle = GoogleFonts.jetBrainsMono(
          fontSize: fontSize,
          height: height,
          color: color,
          backgroundColor: backgroundColor,
          fontWeight: fontWeight,
          fontStyle: fontStyle,
          decoration: decoration,
        );
    }

    // Add font fallback and disable inheritance
    return baseStyle.copyWith(
      fontFamilyFallback: _fontFamilyFallback,
      inherit: false,
    );
  }
}
