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
