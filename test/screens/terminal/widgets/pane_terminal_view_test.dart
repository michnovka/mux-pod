import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_muxpod/providers/settings_provider.dart';
import 'package:flutter_muxpod/screens/terminal/widgets/pane_terminal_view.dart';
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
    VoidCallback? onRequestHistoryMode,
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
              onRequestHistoryMode: onRequestHistoryMode,
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

    testWidgets('requests history mode when overscrolling above live tail', (
      tester,
    ) async {
      final terminal = Terminal(maxLines: 200, reflowEnabled: false);
      final paneKey = GlobalKey<PaneTerminalViewState>();
      final verticalScrollController = ScrollController();
      var requestCount = 0;

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
          onRequestHistoryMode: () {
            requestCount += 1;
          },
        ),
      );
      await tester.pumpAndSettle();

      await tester.dragFrom(
        tester.getCenter(find.byType(PaneTerminalView)),
        const Offset(0, 240),
      );
      await tester.pumpAndSettle();

      expect(paneKey.currentState?.shouldAutoFollow, isFalse);

      verticalScrollController.jumpTo(
        verticalScrollController.position.minScrollExtent,
      );
      await tester.pumpAndSettle();

      final paneRect = tester.getRect(find.byType(PaneTerminalView));
      await tester.dragFrom(
        Offset(paneRect.center.dx, paneRect.top + 4),
        const Offset(0, 120),
      );
      await tester.pumpAndSettle();

      expect(requestCount, greaterThanOrEqualTo(1));
    });
  });
}
