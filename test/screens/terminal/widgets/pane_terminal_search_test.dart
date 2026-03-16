import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_muxpod/providers/settings_provider.dart';
import 'package:flutter_muxpod/screens/terminal/widgets/pane_terminal_view.dart';
import 'package:flutter_muxpod/services/terminal/terminal_search_engine.dart';
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

  late TerminalController terminalController;

  Widget buildHarness({
    required Terminal terminal,
    required TerminalController controller,
    Key? paneKey,
    PaneTerminalMode mode = PaneTerminalMode.normal,
  }) {
    return ProviderScope(
      overrides: [
        settingsProvider.overrideWith(() => _TestSettingsNotifier()),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 480,
            height: 360,
            child: PaneTerminalView(
              key: paneKey,
              terminal: terminal,
              terminalController: controller,
              paneWidth: 80,
              paneHeight: 24,
              backgroundColor: Colors.black,
              foregroundColor: Colors.white,
              mode: mode,
            ),
          ),
        ),
      ),
    );
  }

  /// Pump long enough for the 500ms URL scan debounce to fire.
  Future<void> pumpForUrlScan(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 550));
    await tester.pump();
  }

  setUp(() {
    terminalController = TerminalController();
  });

  group('PaneTerminalView search mode', () {
    testWidgets('search mode sets correct TerminalView props', (
      tester,
    ) async {
      final terminal = Terminal(maxLines: 100, reflowEnabled: false);

      await tester.pumpWidget(
        buildHarness(
          terminal: terminal,
          controller: terminalController,
          mode: PaneTerminalMode.search,
        ),
      );
      await tester.pumpAndSettle();

      final terminalView = tester.widget<TerminalView>(
        find.byType(TerminalView),
      );

      // In search mode: readOnly=true, hardwareKeyboardOnly=true, autofocus=false
      expect(terminalView.readOnly, isTrue);
      expect(terminalView.hardwareKeyboardOnly, isTrue);
      expect(terminalView.autofocus, isFalse);
      await pumpForUrlScan(tester);
    });

    testWidgets('normal mode sets correct TerminalView props', (
      tester,
    ) async {
      final terminal = Terminal(maxLines: 100, reflowEnabled: false);

      await tester.pumpWidget(
        buildHarness(
          terminal: terminal,
          controller: terminalController,
          mode: PaneTerminalMode.normal,
        ),
      );
      await tester.pumpAndSettle();

      final terminalView = tester.widget<TerminalView>(
        find.byType(TerminalView),
      );

      expect(terminalView.readOnly, isFalse);
      expect(terminalView.autofocus, isTrue);
      await pumpForUrlScan(tester);
    });

    testWidgets('search highlights are created and disposed correctly', (
      tester,
    ) async {
      final terminal = Terminal(maxLines: 100, reflowEnabled: false);
      terminal.write('hello world hello\r\n');
      final paneKey = GlobalKey<PaneTerminalViewState>();

      await tester.pumpWidget(
        buildHarness(
          terminal: terminal,
          controller: terminalController,
          paneKey: paneKey,
          mode: PaneTerminalMode.search,
        ),
      );
      await tester.pumpAndSettle();

      // Apply search highlights.
      final matches = TerminalSearchEngine.search(
        terminal.mainBuffer,
        query: 'hello',
      );
      expect(matches, hasLength(2));

      paneKey.currentState!.applySearchHighlights(matches, 0);
      await tester.pump();

      // 2 search highlights should be present.
      expect(terminalController.highlights, hasLength(2));

      // Clear them.
      paneKey.currentState!.clearSearchHighlights();
      await tester.pump();

      expect(terminalController.highlights, isEmpty);
      await pumpForUrlScan(tester);
    });

    testWidgets('search highlights cleared on terminal swap', (
      tester,
    ) async {
      final terminal1 = Terminal(maxLines: 100, reflowEnabled: false);
      terminal1.write('hello world\r\n');
      final paneKey = GlobalKey<PaneTerminalViewState>();

      await tester.pumpWidget(
        buildHarness(
          terminal: terminal1,
          controller: terminalController,
          paneKey: paneKey,
          mode: PaneTerminalMode.search,
        ),
      );
      await tester.pumpAndSettle();

      // Apply search highlights on terminal1.
      final matches = TerminalSearchEngine.search(
        terminal1.mainBuffer,
        query: 'hello',
      );
      paneKey.currentState!.applySearchHighlights(matches, 0);
      await tester.pump();
      expect(terminalController.highlights, hasLength(1));

      // Swap to a different terminal.
      final terminal2 = Terminal(maxLines: 100, reflowEnabled: false);
      await tester.pumpWidget(
        buildHarness(
          terminal: terminal2,
          controller: terminalController,
          paneKey: paneKey,
          mode: PaneTerminalMode.search,
        ),
      );
      await tester.pumpAndSettle();

      // Search highlights should have been cleared by didUpdateWidget.
      expect(terminalController.highlights, isEmpty);
      await pumpForUrlScan(tester);
    });

    testWidgets('URL detection suppressed in search mode', (tester) async {
      final terminal = Terminal(maxLines: 100, reflowEnabled: false);

      await tester.pumpWidget(
        buildHarness(
          terminal: terminal,
          controller: terminalController,
          mode: PaneTerminalMode.search,
        ),
      );
      await tester.pumpAndSettle();

      terminal.write('https://example.com\r\n');
      await pumpForUrlScan(tester);

      // No URL highlights should be created in search mode.
      expect(terminalController.highlights, isEmpty);
    });

    testWidgets('URL highlights cleared when entering search mode', (
      tester,
    ) async {
      final terminal = Terminal(maxLines: 100, reflowEnabled: false);
      final paneKey = GlobalKey<PaneTerminalViewState>();

      // Start in normal mode with URL detection active.
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            settingsProvider.overrideWith(() => _TestSettingsNotifier()),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 480,
                height: 360,
                child: PaneTerminalView(
                  key: paneKey,
                  terminal: terminal,
                  terminalController: terminalController,
                  paneWidth: 80,
                  paneHeight: 24,
                  backgroundColor: Colors.black,
                  foregroundColor: Colors.white,
                  mode: PaneTerminalMode.normal,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      terminal.write('https://example.com\r\n');
      await pumpForUrlScan(tester);
      expect(terminalController.highlights, isNotEmpty);

      // Switch to search mode.
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            settingsProvider.overrideWith(() => _TestSettingsNotifier()),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 480,
                height: 360,
                child: PaneTerminalView(
                  key: paneKey,
                  terminal: terminal,
                  terminalController: terminalController,
                  paneWidth: 80,
                  paneHeight: 24,
                  backgroundColor: Colors.black,
                  foregroundColor: Colors.white,
                  mode: PaneTerminalMode.search,
                ),
              ),
            ),
          ),
        ),
      );
      await pumpForUrlScan(tester);

      // URL highlights should be cleared.
      expect(terminalController.highlights, isEmpty);
    });

    testWidgets('URL tap handler is inert in search mode', (tester) async {
      final terminal = Terminal(maxLines: 100, reflowEnabled: false);

      await tester.pumpWidget(
        buildHarness(
          terminal: terminal,
          controller: terminalController,
          mode: PaneTerminalMode.search,
        ),
      );
      await tester.pumpAndSettle();

      // Tap should not crash even with URLs in buffer.
      terminal.write('https://example.com\r\n');
      await pumpForUrlScan(tester);

      // Just verify it doesn't throw — URL tap is suppressed.
      await tester.tap(find.byType(TerminalView));
      await tester.pumpAndSettle();
      await pumpForUrlScan(tester);
    });

    testWidgets('simulateScroll enabled in search mode', (tester) async {
      final terminal = Terminal(maxLines: 100, reflowEnabled: false);

      await tester.pumpWidget(
        buildHarness(
          terminal: terminal,
          controller: terminalController,
          mode: PaneTerminalMode.search,
        ),
      );
      await tester.pumpAndSettle();

      final terminalView = tester.widget<TerminalView>(
        find.byType(TerminalView),
      );

      // Search mode should allow scrolling (simulateScroll=true),
      // unlike select mode where it's false.
      expect(terminalView.simulateScroll, isTrue);
      await pumpForUrlScan(tester);
    });
  });
}
