import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_muxpod/screens/terminal/terminal_scroll_policy.dart';

void main() {
  group('TerminalScrollPolicy.shouldSuppressStickToBottom', () {
    test('returns false when suppression is disabled', () {
      expect(
        TerminalScrollPolicy.shouldSuppressStickToBottom(
          suppressScrollToMax: false,
          pixels: 0,
          maxScrollExtent: 260,
          viewportShrinkBudget: 320,
        ),
        isFalse,
      );
    });

    test('returns true when content exactly matches the shrink budget', () {
      expect(
        TerminalScrollPolicy.shouldSuppressStickToBottom(
          suppressScrollToMax: true,
          pixels: 0,
          maxScrollExtent: 320,
          viewportShrinkBudget: 320,
        ),
        isTrue,
      );
    });
  });

  group('TerminalScrollPolicy.shouldSuppressDimensionCorrection', () {
    // Scenario: fresh window with content at top, scrollback history
    // prepended.  Keyboard opens → viewport shrinks → maxScrollExtent
    // grows.  The old code only had shouldSuppressStickToBottom which
    // requires maxScrollExtent ≤ viewportShrinkBudget — this FAILED
    // when scrollback was present, letting the framework scroll the
    // user's top-anchored content off-screen.

    test('suppresses when near top, even with large scrollback (was broken)', () {
      // Before fix: shouldSuppressStickToBottom returned false here
      // because maxScrollExtent (4000) > viewportShrinkBudget (420).
      expect(
        TerminalScrollPolicy.shouldSuppressStickToBottom(
          suppressScrollToMax: true,
          pixels: 0,
          maxScrollExtent: 4000,
          viewportShrinkBudget: 420,
        ),
        isFalse, // OLD behavior: would NOT suppress → content scrolls off
      );

      // After fix: shouldSuppressDimensionCorrection catches this case.
      expect(
        TerminalScrollPolicy.shouldSuppressDimensionCorrection(
          suppressScrollToMax: true,
          pixels: 0,
          oldMaxScrollExtent: 3700,
          newMaxScrollExtent: 4000,
        ),
        isTrue, // NEW behavior: suppresses → content stays at top
      );
    });

    test('suppresses for short content near top (keyboard opens)', () {
      expect(
        TerminalScrollPolicy.shouldSuppressDimensionCorrection(
          suppressScrollToMax: true,
          pixels: 0,
          oldMaxScrollExtent: 0,
          newMaxScrollExtent: 300,
        ),
        isTrue,
      );
    });

    test('does not suppress when keyboard is not visible', () {
      expect(
        TerminalScrollPolicy.shouldSuppressDimensionCorrection(
          suppressScrollToMax: false,
          pixels: 0,
          oldMaxScrollExtent: 0,
          newMaxScrollExtent: 300,
        ),
        isFalse,
      );
    });

    test('does not suppress when user has scrolled away from top', () {
      expect(
        TerminalScrollPolicy.shouldSuppressDimensionCorrection(
          suppressScrollToMax: true,
          pixels: 500,
          oldMaxScrollExtent: 3700,
          newMaxScrollExtent: 4000,
        ),
        isFalse,
      );
    });

    test('does not suppress when maxScrollExtent shrinks (keyboard closing)', () {
      expect(
        TerminalScrollPolicy.shouldSuppressDimensionCorrection(
          suppressScrollToMax: true,
          pixels: 0,
          oldMaxScrollExtent: 300,
          newMaxScrollExtent: 0,
        ),
        isFalse,
      );
    });
  });

  group('TerminalScrollPolicy.shouldSuppressKeyboardScrollToBottom', () {
    // Scenario: _syncKeyboardViewportState calls scrollToBottom() in a
    // post-frame callback when the keyboard opens.  The old code only
    // checked shouldPreserveTopAnchorForShortContent which used the
    // viewportShrinkBudget — failed with scrollback, letting the
    // callback scroll to bottom on a top-anchored viewport.

    test('suppresses when viewport is at the top (was broken)', () {
      expect(
        TerminalScrollPolicy.shouldSuppressKeyboardScrollToBottom(pixels: 0),
        isTrue,
      );
    });

    test('suppresses when viewport is within threshold of top', () {
      expect(
        TerminalScrollPolicy.shouldSuppressKeyboardScrollToBottom(pixels: 1.5),
        isTrue,
      );
    });

    test('does not suppress when user has scrolled down', () {
      expect(
        TerminalScrollPolicy.shouldSuppressKeyboardScrollToBottom(pixels: 50),
        isFalse,
      );
    });
  });

  group('TerminalScrollPolicy.shouldKeepShortContentAnchored', () {
    test('returns true for short content near the top', () {
      expect(
        TerminalScrollPolicy.shouldKeepShortContentAnchored(
          pixels: 0,
          maxScrollExtent: 260,
          viewportShrinkBudget: 320,
        ),
        isTrue,
      );
    });

    test('returns false once the user is away from the top', () {
      expect(
        TerminalScrollPolicy.shouldKeepShortContentAnchored(
          pixels: 8,
          maxScrollExtent: 260,
          viewportShrinkBudget: 320,
        ),
        isFalse,
      );
    });

    test('returns false for genuinely long content', () {
      expect(
        TerminalScrollPolicy.shouldKeepShortContentAnchored(
          pixels: 0,
          maxScrollExtent: 520,
          viewportShrinkBudget: 320,
        ),
        isFalse,
      );
    });
  });
}
