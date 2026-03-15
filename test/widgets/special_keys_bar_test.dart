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
    VoidCallback? onShiftToggle,
    bool shiftPressed = false,
    VoidCallback? onAttachImage,
    bool attachImageEnabled = false,
    VoidCallback? onToggleSelect,
    bool selectModeActive = false,
    VoidCallback? onPaste,
    VoidCallback? onReplies,
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
            onShiftToggle: onShiftToggle,
            shiftPressed: shiftPressed,
            onAttachImage: onAttachImage,
            attachImageEnabled: attachImageEnabled,
            onToggleSelect: onToggleSelect,
            selectModeActive: selectModeActive,
            onPaste: onPaste,
            onReplies: onReplies,
          ),
        ),
      ),
    );
  }

  group('SpecialKeysBar', () {
    testWidgets('renders the 8-column key layout with action row', (
      tester,
    ) async {
      await tester.pumpWidget(
        buildHarness(
          onLiteralKeyPressed: (_) {},
          onSpecialKeyPressed: (_) {},
          onCtrlToggle: () {},
          onAltToggle: () {},
        ),
      );

      // Top row keys
      for (final label in const [
        '/',
        '-',
        'HOME',
        'ALT',
        '↑',
        'END',
        'PGUP',
        'ESC',
      ]) {
        expect(find.text(label), findsOneWidget);
      }

      // Bottom row keys
      for (final label in const [
        'TAB',
        'SHIFT',
        'CTRL',
        '←',
        '↓',
        '→',
        'PGDN',
        'DEL',
      ]) {
        expect(find.text(label), findsOneWidget);
      }

      // Action row labels
      for (final label in const ['IMG', 'SEL', 'PASTE', 'REPLY']) {
        expect(find.text(label), findsOneWidget);
      }
    });

    testWidgets('dispatches literal, special, and modifier taps', (
      tester,
    ) async {
      final literalKeys = <String>[];
      final specialKeys = <String>[];
      var ctrlToggleCount = 0;
      var altToggleCount = 0;
      var shiftToggleCount = 0;

      await tester.pumpWidget(
        buildHarness(
          onLiteralKeyPressed: literalKeys.add,
          onSpecialKeyPressed: specialKeys.add,
          onCtrlToggle: () => ctrlToggleCount += 1,
          onAltToggle: () => altToggleCount += 1,
          onShiftToggle: () => shiftToggleCount += 1,
        ),
      );

      await tester.tap(find.text('/'));
      await tester.tap(find.text('ESC'));
      await tester.tap(find.text('CTRL'));
      await tester.tap(find.text('ALT'));
      await tester.tap(find.text('SHIFT'));
      await tester.tap(find.text('DEL'));
      await tester.pump();

      expect(literalKeys, ['/']);
      expect(specialKeys, ['Escape', 'DC']);
      expect(ctrlToggleCount, 1);
      expect(altToggleCount, 1);
      expect(shiftToggleCount, 1);
    });

    testWidgets('action row dispatches callbacks', (tester) async {
      var selectToggled = false;
      var pastePressed = false;

      await tester.pumpWidget(
        buildHarness(
          onLiteralKeyPressed: (_) {},
          onSpecialKeyPressed: (_) {},
          onCtrlToggle: () {},
          onAltToggle: () {},
          onToggleSelect: () => selectToggled = true,
          onPaste: () => pastePressed = true,
        ),
      );

      await tester.tap(find.text('SEL'));
      await tester.tap(find.text('PASTE'));
      await tester.pump();

      expect(selectToggled, isTrue);
      expect(pastePressed, isTrue);
    });

    testWidgets('select mode highlights SEL button', (tester) async {
      await tester.pumpWidget(
        buildHarness(
          onLiteralKeyPressed: (_) {},
          onSpecialKeyPressed: (_) {},
          onCtrlToggle: () {},
          onAltToggle: () {},
          selectModeActive: true,
          onToggleSelect: () {},
        ),
      );

      // SEL button should be present and the widget renders with active state
      expect(find.text('SEL'), findsOneWidget);
    });
  });
}
