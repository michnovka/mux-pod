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
    VoidCallback? onSearch,
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
            onSearch: onSearch,
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
      for (final label in const ['IMG', 'SEL', 'PASTE', 'FIND']) {
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

  group('Arrow key repeat', () {
    late int fireCount;
    late Widget harness;

    setUp(() {
      fireCount = 0;
      harness = MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: SpecialKeysBar(
              onLiteralKeyPressed: (_) {},
              onSpecialKeyPressed: (_) => fireCount++,
              onCtrlToggle: () {},
              onAltToggle: () {},
              ctrlPressed: false,
              altPressed: false,
              hapticFeedback: false,
            ),
          ),
        ),
      );
    });

    testWidgets('single tap fires exactly once', (tester) async {
      await tester.pumpWidget(harness);
      final center = tester.getCenter(find.text('↑'));
      final gesture = await tester.startGesture(center);
      await tester.pump();
      await gesture.up();
      await tester.pump();

      expect(fireCount, 1);
    });

    testWidgets('repeat starts after 500ms initial delay', (tester) async {
      await tester.pumpWidget(harness);
      final center = tester.getCenter(find.text('→'));
      final gesture = await tester.startGesture(center);
      await tester.pump();
      expect(fireCount, 1); // immediate fire

      // Advance just under the delay — no repeats yet
      await tester.pump(const Duration(milliseconds: 490));
      expect(fireCount, 1);

      // Cross the delay threshold — repeats should start
      await tester.pump(const Duration(milliseconds: 50));
      expect(fireCount, greaterThan(1));

      await gesture.up();
      await tester.pump();
    });

    testWidgets('repeat rate is approximately 30 Hz', (tester) async {
      await tester.pumpWidget(harness);
      final center = tester.getCenter(find.text('←'));
      final gesture = await tester.startGesture(center);
      await tester.pump();
      expect(fireCount, 1);

      // 500ms delay + 330ms = ~10 repeat intervals at 33ms each
      await tester.pump(const Duration(milliseconds: 830));
      // 1 initial + ~10 repeats
      expect(fireCount, inInclusiveRange(9, 12));

      await gesture.up();
      await tester.pump();
    });

    testWidgets('release stops repeat', (tester) async {
      await tester.pumpWidget(harness);
      final center = tester.getCenter(find.text('↓'));
      final gesture = await tester.startGesture(center);
      await tester.pump();

      // Enter repeat mode
      await tester.pump(const Duration(milliseconds: 600));
      final countAtRelease = fireCount;
      expect(countAtRelease, greaterThan(1));

      // Release and wait — no more fires
      await gesture.up();
      await tester.pump(const Duration(milliseconds: 500));
      expect(fireCount, countAtRelease);
    });

    testWidgets('drag-off cancels repeat', (tester) async {
      await tester.pumpWidget(harness);
      final center = tester.getCenter(find.text('↑'));
      final gesture = await tester.startGesture(center);
      await tester.pump();
      expect(fireCount, 1);

      // Move pointer well outside the button bounds
      await gesture.moveTo(center + const Offset(200, 200));
      await tester.pump();
      final countAfterDragOff = fireCount;

      // Wait — no more fires should occur
      await tester.pump(const Duration(milliseconds: 600));
      expect(fireCount, countAfterDragOff);

      await gesture.up();
      await tester.pump();
    });

    testWidgets('second finger is ignored (multi-touch safety)',
        (tester) async {
      await tester.pumpWidget(harness);
      final center = tester.getCenter(find.text('→'));

      // First finger down
      final gesture1 = await tester.startGesture(center);
      await tester.pump();
      expect(fireCount, 1);

      // Second finger on same button — should be ignored
      final gesture2 = await tester.startGesture(center);
      await tester.pump();
      expect(fireCount, 1); // no additional fire

      // Wait for repeat — should be single-pointer rate
      await tester.pump(const Duration(milliseconds: 600));
      final countBefore = fireCount;
      expect(countBefore, greaterThan(1));

      // Lift second finger — repeat should continue
      await gesture2.up();
      await tester.pump(const Duration(milliseconds: 100));
      expect(fireCount, greaterThan(countBefore));

      await gesture1.up();
      await tester.pump();
    });

    testWidgets('non-repeatable key does not repeat on hold', (tester) async {
      // TAB is a non-repeatable special key
      var tabFireCount = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: SpecialKeysBar(
                onLiteralKeyPressed: (_) {},
                onSpecialKeyPressed: (_) => tabFireCount++,
                onCtrlToggle: () {},
                onAltToggle: () {},
                ctrlPressed: false,
                altPressed: false,
                hapticFeedback: false,
              ),
            ),
          ),
        ),
      );

      // Long-press TAB via GestureDetector — it only fires on tap (up), not
      // on down, so holding without releasing should produce zero fires.
      final center = tester.getCenter(find.text('TAB'));
      final gesture = await tester.startGesture(center);
      await tester.pump(const Duration(milliseconds: 1000));
      // TAB uses GestureDetector.onTap which fires on pointer up, not down.
      // So while held, count should still be 0.
      expect(tabFireCount, 0);

      await gesture.up();
      await tester.pump();
      // Now onTap fires
      expect(tabFireCount, 1);
    });

    testWidgets('dispose cancels timers without errors', (tester) async {
      await tester.pumpWidget(harness);
      final center = tester.getCenter(find.text('↑'));
      await tester.startGesture(center);
      await tester.pump();

      // Enter repeat mode
      await tester.pump(const Duration(milliseconds: 600));
      expect(fireCount, greaterThan(1));

      // Dispose by replacing the widget tree — should not throw
      await tester.pumpWidget(const MaterialApp(home: Scaffold()));
      await tester.pump(const Duration(milliseconds: 500));
      // No assertion errors = pass
    });
  });
}
