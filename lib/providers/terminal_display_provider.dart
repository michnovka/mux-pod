import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/terminal/font_calculator.dart';
import '../services/tmux/tmux_parser.dart';
import 'settings_provider.dart';

/// Terminal display state
///
/// Manages font size, scroll state, and zoom state.
class TerminalDisplayState {
  /// Pane width (in characters)
  final int paneWidth;

  /// Pane height (in lines)
  final int paneHeight;

  /// Available screen width (in pixels)
  final double screenWidth;

  /// Calculated font size
  final double calculatedFontSize;

  /// Whether horizontal scroll is needed
  final bool needsHorizontalScroll;

  /// Horizontal scroll offset
  final double horizontalScrollOffset;

  /// Pinch zoom scale (1.0 = original size)
  final double zoomScale;

  /// Whether a zoom operation is in progress
  final bool isZooming;

  const TerminalDisplayState({
    this.paneWidth = 80,
    this.paneHeight = 24,
    this.screenWidth = 0.0,
    this.calculatedFontSize = 14.0,
    this.needsHorizontalScroll = false,
    this.horizontalScrollOffset = 0.0,
    this.zoomScale = 1.0,
    this.isZooming = false,
  });

  /// Effective font size actually applied
  double get effectiveFontSize {
    if (isZooming) {
      return calculatedFontSize * zoomScale;
    }
    return calculatedFontSize;
  }

  TerminalDisplayState copyWith({
    int? paneWidth,
    int? paneHeight,
    double? screenWidth,
    double? calculatedFontSize,
    bool? needsHorizontalScroll,
    double? horizontalScrollOffset,
    double? zoomScale,
    bool? isZooming,
  }) {
    return TerminalDisplayState(
      paneWidth: paneWidth ?? this.paneWidth,
      paneHeight: paneHeight ?? this.paneHeight,
      screenWidth: screenWidth ?? this.screenWidth,
      calculatedFontSize: calculatedFontSize ?? this.calculatedFontSize,
      needsHorizontalScroll: needsHorizontalScroll ?? this.needsHorizontalScroll,
      horizontalScrollOffset: horizontalScrollOffset ?? this.horizontalScrollOffset,
      zoomScale: zoomScale ?? this.zoomScale,
      isZooming: isZooming ?? this.isZooming,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TerminalDisplayState &&
          runtimeType == other.runtimeType &&
          paneWidth == other.paneWidth &&
          paneHeight == other.paneHeight &&
          screenWidth == other.screenWidth &&
          calculatedFontSize == other.calculatedFontSize &&
          needsHorizontalScroll == other.needsHorizontalScroll &&
          horizontalScrollOffset == other.horizontalScrollOffset &&
          zoomScale == other.zoomScale &&
          isZooming == other.isZooming;

  @override
  int get hashCode => Object.hash(
        paneWidth,
        paneHeight,
        screenWidth,
        calculatedFontSize,
        needsHorizontalScroll,
        horizontalScrollOffset,
        zoomScale,
        isZooming,
      );
}

/// Notifier that manages terminal display state
class TerminalDisplayNotifier extends Notifier<TerminalDisplayState> {
  /// Maximum font size
  static const double maxFontSize = 48.0;

  @override
  TerminalDisplayState build() => const TerminalDisplayState();

  /// Update pane information
  ///
  /// Called when a pane is selected; recalculates font size.
  void updatePane(TmuxPane pane) {
    // Reset zoom state
    state = state.copyWith(
      paneWidth: pane.width,
      paneHeight: pane.height,
      zoomScale: 1.0,
      isZooming: false,
      horizontalScrollOffset: 0.0, // Also reset scroll position
    );
    _recalculateFontSize();
  }

  /// Update screen width
  ///
  /// Called from LayoutBuilder.
  void updateScreenWidth(double width) {
    if (state.screenWidth == width) return; // No-op if unchanged
    state = state.copyWith(screenWidth: width);
    _recalculateFontSize();
  }

  /// Update horizontal scroll offset
  void updateHorizontalScrollOffset(double offset) {
    state = state.copyWith(horizontalScrollOffset: offset);
  }

  /// Start pinch zoom
  void startZoom() {
    state = state.copyWith(isZooming: true);
  }

  /// Update pinch zoom
  void updateZoom(double scale) {
    state = state.copyWith(zoomScale: scale);
  }

  /// End pinch zoom
  ///
  /// Finalizes the font size after zoom and resets the scale.
  void endZoom() {
    final settings = ref.read(settingsProvider);
    final newFontSize = state.calculatedFontSize * state.zoomScale;

    state = state.copyWith(
      calculatedFontSize: newFontSize.clamp(settings.minFontSize, maxFontSize),
      zoomScale: 1.0,
      isZooming: false,
    );

    // Recalculate horizontal scroll requirement
    _updateScrollRequirement();
  }

  /// Recalculate font size
  void _recalculateFontSize() {
    final settings = ref.read(settingsProvider);

    final result = FontCalculator.calculate(
      screenWidth: state.screenWidth,
      paneCharWidth: state.paneWidth,
      fontFamily: settings.fontFamily,
      minFontSize: settings.minFontSize,
    );

    state = state.copyWith(
      calculatedFontSize: result.fontSize,
      needsHorizontalScroll: result.needsScroll,
    );
  }

  /// Update horizontal scroll requirement
  void _updateScrollRequirement() {
    final settings = ref.read(settingsProvider);
    final terminalWidth = FontCalculator.calculateTerminalWidth(
      paneCharWidth: state.paneWidth,
      fontSize: state.calculatedFontSize,
      fontFamily: settings.fontFamily,
    );

    state = state.copyWith(
      needsHorizontalScroll: terminalWidth > state.screenWidth,
    );
  }

  /// Force recalculation when settings change
  void onSettingsChanged() {
    _recalculateFontSize();
  }
}

/// Terminal display provider
final terminalDisplayProvider =
    NotifierProvider<TerminalDisplayNotifier, TerminalDisplayState>(
  () => TerminalDisplayNotifier(),
);
