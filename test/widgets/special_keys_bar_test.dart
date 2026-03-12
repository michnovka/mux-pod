import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_muxpod/widgets/special_keys_bar.dart';
import 'package:google_fonts/google_fonts.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  GoogleFonts.config.allowRuntimeFetching = false;

  Widget buildHarness({
    required void Function(String key) onLiteralKeyPressed,
    required void Function(String key) onSpecialKeyPressed,
    required VoidCallback onCtrlToggle,
    required VoidCallback onAltToggle,
    bool ctrlPressed = false,
    bool altPressed = false,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.bottomCenter,
          child: SpecialKeysBar(
            onLiteralKeyPressed: onLiteralKeyPressed,
            onSpecialKeyPressed: onSpecialKeyPressed,
            onCtrlToggle: onCtrlToggle,
            onAltToggle: onAltToggle,
            ctrlPressed: ctrlPressed,
            altPressed: altPressed,
          ),
        ),
      ),
    );
  }

  group('SpecialKeysBar', () {
    testWidgets('renders the Termux-style key layout', (tester) async {
      await tester.pumpWidget(
        buildHarness(
          onLiteralKeyPressed: (_) {},
          onSpecialKeyPressed: (_) {},
          onCtrlToggle: () {},
          onAltToggle: () {},
        ),
      );

      for (final label in const [
        'ESC',
        '/',
        '-',
        'HOME',
        '↑',
        'END',
        'PGUP',
        'TAB',
        'CTRL',
        'ALT',
        '←',
        '↓',
        '→',
        'PGDN',
      ]) {
        expect(find.text(label), findsOneWidget);
      }

      expect(find.text('SHIFT'), findsNothing);
      expect(find.text('RET'), findsNothing);
      expect(find.text('S-RET'), findsNothing);
      expect(find.text('Input...'), findsNothing);
    });

    testWidgets('dispatches literal, special, and modifier taps', (
      tester,
    ) async {
      final literalKeys = <String>[];
      final specialKeys = <String>[];
      var ctrlToggleCount = 0;
      var altToggleCount = 0;

      await tester.pumpWidget(
        buildHarness(
          onLiteralKeyPressed: literalKeys.add,
          onSpecialKeyPressed: specialKeys.add,
          onCtrlToggle: () => ctrlToggleCount += 1,
          onAltToggle: () => altToggleCount += 1,
        ),
      );

      await tester.tap(find.text('/'));
      await tester.tap(find.text('ESC'));
      await tester.tap(find.text('CTRL'));
      await tester.tap(find.text('ALT'));
      await tester.pump();

      expect(literalKeys, ['/']);
      expect(specialKeys, ['Escape']);
      expect(ctrlToggleCount, 1);
      expect(altToggleCount, 1);
    });
  });
}
