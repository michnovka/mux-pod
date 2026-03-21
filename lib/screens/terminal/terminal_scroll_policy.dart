import 'package:flutter/foundation.dart';

/// Shared scroll suppression policy for short terminal content when the
/// keyboard reduces the viewport.
class TerminalScrollPolicy {
  static const double nearTopThreshold = 2.0;

  static bool shouldSuppressStickToBottom({
    required bool suppressScrollToMax,
    required double pixels,
    required double maxScrollExtent,
    required double viewportShrinkBudget,
  }) {
    if (!suppressScrollToMax || pixels > nearTopThreshold) {
      return false;
    }

    return maxScrollExtent <= viewportShrinkBudget;
  }

  @visibleForTesting
  static bool shouldKeepShortContentAnchored({
    required double pixels,
    required double maxScrollExtent,
    required double viewportShrinkBudget,
  }) {
    return shouldSuppressStickToBottom(
      suppressScrollToMax: true,
      pixels: pixels,
      maxScrollExtent: maxScrollExtent,
      viewportShrinkBudget: viewportShrinkBudget,
    );
  }

  /// Whether correctForNewDimensions should block the framework's
  /// adjustPositionForNewDimensions when the keyboard opens.
  ///
  /// Unlike [shouldSuppressStickToBottom] this deliberately skips the
  /// viewportShrinkBudget check: even if there's lots of scrollback
  /// history, a viewport near the top should stay at the top when the
  /// keyboard opens.
  static bool shouldSuppressDimensionCorrection({
    required bool suppressScrollToMax,
    required double pixels,
    required double oldMaxScrollExtent,
    required double newMaxScrollExtent,
  }) {
    return suppressScrollToMax &&
        pixels <= nearTopThreshold &&
        newMaxScrollExtent > oldMaxScrollExtent;
  }

  /// Whether the keyboard-appearance scroll-to-bottom should be skipped
  /// because the viewport is anchored near the top.
  static bool shouldSuppressKeyboardScrollToBottom({
    required double pixels,
  }) {
    return pixels <= nearTopThreshold;
  }
}
