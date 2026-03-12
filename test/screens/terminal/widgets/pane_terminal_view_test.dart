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
  });
}
