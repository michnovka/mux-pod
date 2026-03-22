import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_muxpod/providers/settings_provider.dart';
import 'package:flutter_muxpod/screens/terminal/widgets/pane_terminal_view.dart';
import 'package:flutter_muxpod/screens/terminal/widgets/selection_handle.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:xterm/xterm.dart';

class _TestSettingsNotifier extends SettingsNotifier {
  @override
  AppSettings build() {
    return const AppSettings(fontFamily: 'HackGen Console');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  GoogleFonts.config.allowRuntimeFetching = false;

  Widget buildHarness({
    required int paneWidth,
    required int paneHeight,
    required Terminal terminal,
    Key? paneKey,
    ScrollController? verticalScrollController,
    bool verticalScrollEnabled = true,
    bool readOnly = false,
    ValueChanged<bool>? onFollowBottomChanged,
  }) {
    return ProviderScope(
      overrides: [settingsProvider.overrideWith(() => _TestSettingsNotifier())],
      child: MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 240,
            height: 180,
            child: PaneTerminalView(
              key: paneKey,
              terminal: terminal,
              terminalController: TerminalController(),
              paneWidth: paneWidth,
              paneHeight: paneHeight,
              backgroundColor: Colors.black,
              foregroundColor: Colors.white,
              verticalScrollController: verticalScrollController,
              verticalScrollEnabled: verticalScrollEnabled,
              readOnly: readOnly,
              onFollowBottomChanged: onFollowBottomChanged,
            ),
          ),
        ),
      ),
    );
  }

  group('PaneTerminalView', () {
    testWidgets('renders the xterm terminal surface', (tester) async {
      final terminal = Terminal(maxLines: 100, reflowEnabled: false);
      terminal.write('hello world');

      await tester.pumpWidget(
        buildHarness(paneWidth: 80, paneHeight: 24, terminal: terminal),
      );

      expect(find.byType(TerminalView), findsOneWidget);
    });

    testWidgets('enables delete detection for mobile soft keyboards', (
      tester,
    ) async {
      final terminal = Terminal(maxLines: 100, reflowEnabled: false);

      await tester.pumpWidget(
        buildHarness(paneWidth: 80, paneHeight: 24, terminal: terminal),
      );

      final terminalView = tester.widget<TerminalView>(
        find.byType(TerminalView),
      );

      expect(terminalView.deleteDetection, isTrue);
    });

    testWidgets('wraps wide panes in a horizontal scroll view', (tester) async {
      final terminal = Terminal(maxLines: 100, reflowEnabled: false);
      terminal.write('wide content');

      await tester.pumpWidget(
        buildHarness(paneWidth: 240, paneHeight: 24, terminal: terminal),
      );

      expect(find.byType(TerminalView), findsOneWidget);
      expect(find.byType(SingleChildScrollView), findsOneWidget);
    });

    testWidgets('stops auto-following when the user scrolls up', (
      tester,
    ) async {
      final terminal = Terminal(maxLines: 200, reflowEnabled: false);
      final paneKey = GlobalKey<PaneTerminalViewState>();
      final verticalScrollController = ScrollController();

      for (var index = 0; index < 80; index += 1) {
        terminal.write('line $index\r\n');
      }

      await tester.pumpWidget(
        buildHarness(
          paneWidth: 80,
          paneHeight: 24,
          terminal: terminal,
          paneKey: paneKey,
          verticalScrollController: verticalScrollController,
        ),
      );
      await tester.pumpAndSettle();

      expect(verticalScrollController.position.maxScrollExtent, greaterThan(0));
      expect(paneKey.currentState?.shouldAutoFollow, isTrue);

      await tester.dragFrom(
        tester.getCenter(find.byType(PaneTerminalView)),
        const Offset(0, 140),
      );
      await tester.pumpAndSettle();

      expect(
        verticalScrollController.position.pixels,
        lessThan(verticalScrollController.position.maxScrollExtent),
      );
      expect(paneKey.currentState?.shouldAutoFollow, isFalse);

      paneKey.currentState?.scrollToBottom();
      await tester.pumpAndSettle();

      expect(paneKey.currentState?.shouldAutoFollow, isTrue);
    });

    testWidgets('disables on-screen keyboard when scrolled into history', (
      tester,
    ) async {
      final terminal = Terminal(maxLines: 200, reflowEnabled: false);
      final paneKey = GlobalKey<PaneTerminalViewState>();
      final verticalScrollController = ScrollController();

      for (var index = 0; index < 80; index += 1) {
        terminal.write('line $index\r\n');
      }

      await tester.pumpWidget(
        buildHarness(
          paneWidth: 80,
          paneHeight: 24,
          terminal: terminal,
          paneKey: paneKey,
          verticalScrollController: verticalScrollController,
        ),
      );
      await tester.pumpAndSettle();

      // At live tail: keyboard should be enabled
      var terminalView = tester.widget<TerminalView>(
        find.byType(TerminalView),
      );
      expect(terminalView.hardwareKeyboardOnly, isFalse);

      // Scroll up into history
      await tester.dragFrom(
        tester.getCenter(find.byType(PaneTerminalView)),
        const Offset(0, 140),
      );
      await tester.pumpAndSettle();

      // In history: keyboard should be disabled
      terminalView = tester.widget<TerminalView>(
        find.byType(TerminalView),
      );
      expect(terminalView.hardwareKeyboardOnly, isTrue);

      // Scroll back to bottom
      paneKey.currentState?.scrollToBottom();
      await tester.pumpAndSettle();

      // Back at live tail: keyboard should be enabled again
      terminalView = tester.widget<TerminalView>(
        find.byType(TerminalView),
      );
      expect(terminalView.hardwareKeyboardOnly, isFalse);
    });

    testWidgets('captures and restores viewport state', (tester) async {
      final terminal = Terminal(maxLines: 300, reflowEnabled: false);
      final paneKey = GlobalKey<PaneTerminalViewState>();
      final verticalScrollController = ScrollController();

      for (var index = 0; index < 120; index += 1) {
        terminal.write('line $index\r\n');
      }

      await tester.pumpWidget(
        buildHarness(
          paneWidth: 220,
          paneHeight: 24,
          terminal: terminal,
          paneKey: paneKey,
          verticalScrollController: verticalScrollController,
        ),
      );
      await tester.pumpAndSettle();

      await tester.dragFrom(
        tester.getCenter(find.byType(PaneTerminalView)),
        const Offset(0, 140),
      );
      await tester.pumpAndSettle();

      await tester.drag(
        find.byType(SingleChildScrollView),
        const Offset(-120, 0),
      );
      await tester.pumpAndSettle();

      final savedState = paneKey.currentState!.captureViewportState();
      expect(savedState.followBottom, isFalse);
      expect(savedState.verticalDistanceFromBottom, greaterThan(0));
      expect(savedState.horizontalOffset, greaterThan(0));

      paneKey.currentState!.scrollToBottom();
      await tester.pumpAndSettle();

      await tester.drag(
        find.byType(SingleChildScrollView),
        const Offset(120, 0),
      );
      await tester.pumpAndSettle();

      paneKey.currentState!.restoreViewportState(savedState);
      await tester.pumpAndSettle();

      final restoredState = paneKey.currentState!.captureViewportState();
      expect(restoredState.followBottom, isFalse);
      expect(
        restoredState.verticalDistanceFromBottom,
        closeTo(savedState.verticalDistanceFromBottom, 4),
      );
      expect(
        restoredState.horizontalOffset,
        closeTo(savedState.horizontalOffset, 4),
      );
    });

    testWidgets('restores zoom from cached viewport state', (tester) async {
      final terminal = Terminal(maxLines: 100, reflowEnabled: false);
      final paneKey = GlobalKey<PaneTerminalViewState>();

      await tester.pumpWidget(
        buildHarness(
          paneWidth: 80,
          paneHeight: 24,
          terminal: terminal,
          paneKey: paneKey,
        ),
      );
      await tester.pumpAndSettle();

      paneKey.currentState!.restoreViewportState(
        const PaneTerminalViewportState(zoomScale: 1.6),
      );
      await tester.pumpAndSettle();

      final restoredState = paneKey.currentState!.captureViewportState();
      expect(restoredState.zoomScale, closeTo(1.6, 0.01));
    });

    testWidgets('disables vertical scrolling when configured off', (
      tester,
    ) async {
      final terminal = Terminal(maxLines: 200, reflowEnabled: false);

      await tester.pumpWidget(
        buildHarness(
          paneWidth: 80,
          paneHeight: 24,
          terminal: terminal,
          verticalScrollEnabled: false,
        ),
      );

      final terminalView = tester.widget<TerminalView>(
        find.byType(TerminalView),
      );

      expect(terminalView.scrollPhysics, isA<NeverScrollableScrollPhysics>());
    });

    testWidgets('reports follow-bottom changes to the parent', (tester) async {
      final terminal = Terminal(maxLines: 200, reflowEnabled: false);
      final verticalScrollController = ScrollController();
      final followStates = <bool>[];

      for (var index = 0; index < 80; index += 1) {
        terminal.write('line $index\r\n');
      }

      await tester.pumpWidget(
        buildHarness(
          paneWidth: 80,
          paneHeight: 24,
          terminal: terminal,
          verticalScrollController: verticalScrollController,
          onFollowBottomChanged: followStates.add,
        ),
      );
      await tester.pumpAndSettle();

      await tester.dragFrom(
        tester.getCenter(find.byType(PaneTerminalView)),
        const Offset(0, 140),
      );
      await tester.pumpAndSettle();

      expect(followStates, contains(false));
    });

    testWidgets('keeps follow-bottom enabled for a small near-bottom drag', (
      tester,
    ) async {
      final terminal = Terminal(maxLines: 200, reflowEnabled: false);
      final paneKey = GlobalKey<PaneTerminalViewState>();
      final verticalScrollController = ScrollController();
      final followStates = <bool>[];

      for (var index = 0; index < 80; index += 1) {
        terminal.write('line $index\r\n');
      }

      await tester.pumpWidget(
        buildHarness(
          paneWidth: 80,
          paneHeight: 24,
          terminal: terminal,
          paneKey: paneKey,
          verticalScrollController: verticalScrollController,
          onFollowBottomChanged: followStates.add,
        ),
      );
      await tester.pumpAndSettle();

      await tester.dragFrom(
        tester.getCenter(find.byType(PaneTerminalView)),
        const Offset(0, 12),
      );
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 350));

      expect(
        verticalScrollController.position.maxScrollExtent -
            verticalScrollController.position.pixels,
        lessThanOrEqualTo(32),
      );
      expect(paneKey.currentState?.shouldAutoFollow, isTrue);
      expect(followStates, isNot(contains(false)));
    });

    testWidgets('coalesces repeated bottom snaps into one pending callback', (
      tester,
    ) async {
      final terminal = Terminal(maxLines: 200, reflowEnabled: false);
      final paneKey = GlobalKey<PaneTerminalViewState>();
      final verticalScrollController = ScrollController();

      for (var index = 0; index < 80; index += 1) {
        terminal.write('line $index\r\n');
      }

      await tester.pumpWidget(
        buildHarness(
          paneWidth: 80,
          paneHeight: 24,
          terminal: terminal,
          paneKey: paneKey,
          verticalScrollController: verticalScrollController,
        ),
      );
      await tester.pumpAndSettle();

      await tester.dragFrom(
        tester.getCenter(find.byType(PaneTerminalView)),
        const Offset(0, 140),
      );
      await tester.pumpAndSettle();

      expect(paneKey.currentState?.hasPendingBottomSnap, isFalse);

      paneKey.currentState!.scrollToBottom();
      final callbackCountAfterFirstSnap = tester.binding.transientCallbackCount;
      paneKey.currentState!.scrollToBottom();
      paneKey.currentState!.scrollToBottom();

      expect(paneKey.currentState?.hasPendingBottomSnap, isTrue);
      expect(
        tester.binding.transientCallbackCount,
        callbackCountAfterFirstSnap,
      );

      await tester.pumpAndSettle();

      expect(paneKey.currentState?.shouldAutoFollow, isTrue);
    });
  });

  group('Selection handles', () {
    Widget buildSelectHarness({
      required Terminal terminal,
      required TerminalController controller,
      PaneTerminalMode mode = PaneTerminalMode.select,
    }) {
      return ProviderScope(
        overrides: [
          settingsProvider.overrideWith(() => _TestSettingsNotifier()),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 320,
              height: 240,
              child: PaneTerminalView(
                terminal: terminal,
                terminalController: controller,
                paneWidth: 40,
                paneHeight: 10,
                backgroundColor: Colors.black,
                foregroundColor: Colors.white,
                mode: mode,
              ),
            ),
          ),
        ),
      );
    }

    testWidgets('selection overlay visible in select mode with selection', (
      tester,
    ) async {
      final terminal = Terminal(maxLines: 100, reflowEnabled: false);
      terminal.write('hello world\r\nline two');
      final controller = TerminalController();

      await tester.pumpWidget(
        buildSelectHarness(
          terminal: terminal,
          controller: controller,
          mode: PaneTerminalMode.select,
        ),
      );
      await tester.pumpAndSettle();

      // Create a selection
      controller.setSelection(
        terminal.buffer.createAnchorFromOffset(const CellOffset(0, 0)),
        terminal.buffer.createAnchorFromOffset(const CellOffset(5, 0)),
      );
      await tester.pumpAndSettle();

      // Copy/Clear action buttons should appear in the overlay
      expect(find.text('Copy'), findsOneWidget);
      expect(find.text('Clear'), findsOneWidget);
    });

    testWidgets('handles hidden in normal mode', (tester) async {
      final terminal = Terminal(maxLines: 100, reflowEnabled: false);
      terminal.write('hello world');
      final controller = TerminalController();

      await tester.pumpWidget(
        buildSelectHarness(
          terminal: terminal,
          controller: controller,
          mode: PaneTerminalMode.normal,
        ),
      );
      await tester.pumpAndSettle();

      controller.setSelection(
        terminal.buffer.createAnchorFromOffset(const CellOffset(0, 0)),
        terminal.buffer.createAnchorFromOffset(const CellOffset(5, 0)),
      );
      await tester.pumpAndSettle();

      expect(find.byType(SelectionHandle), findsNothing);
    });

    testWidgets('handles hidden with no selection', (tester) async {
      final terminal = Terminal(maxLines: 100, reflowEnabled: false);
      terminal.write('hello world');
      final controller = TerminalController();

      await tester.pumpWidget(
        buildSelectHarness(
          terminal: terminal,
          controller: controller,
          mode: PaneTerminalMode.select,
        ),
      );
      await tester.pumpAndSettle();

      // No selection set
      expect(find.byType(SelectionHandle), findsNothing);
    });
  });
}
