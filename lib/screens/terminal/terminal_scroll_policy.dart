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
}
