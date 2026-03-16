import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_muxpod/providers/settings_provider.dart';
import 'package:flutter_muxpod/screens/terminal/widgets/pane_terminal_view.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:xterm/xterm.dart';

class _TestSettingsNotifier extends SettingsNotifier {
  bool urlDetection;

  _TestSettingsNotifier({this.urlDetection = true});

  @override
  AppSettings build() {
    return AppSettings(
      fontFamily: 'HackGen Console',
      enableUrlDetection: urlDetection,
    );
  }

  void toggleUrlDetection(bool value) {
    state = state.copyWith(enableUrlDetection: value);
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
    bool enableUrlDetection = true,
  }) {
    return ProviderScope(
      overrides: [
        settingsProvider.overrideWith(
          () => _TestSettingsNotifier(urlDetection: enableUrlDetection),
        ),
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

  group('PaneTerminalView URL detection', () {
    testWidgets('creates highlights for URLs in terminal output', (
      tester,
    ) async {
      final terminal = Terminal(maxLines: 100, reflowEnabled: false);

      await tester.pumpWidget(
        buildHarness(terminal: terminal, controller: terminalController),
      );
      await tester.pumpAndSettle();

      terminal.write('Visit https://example.com for info\r\n');
      await pumpForUrlScan(tester);

      expect(terminalController.highlights, isNotEmpty);
      expect(terminalController.highlights.length, 1);
    });

    testWidgets('creates one highlight per URL', (tester) async {
      final terminal = Terminal(maxLines: 100, reflowEnabled: false);

      await tester.pumpWidget(
        buildHarness(terminal: terminal, controller: terminalController),
      );
      await tester.pumpAndSettle();

      terminal.write('https://a.com and https://b.com\r\n');
      await pumpForUrlScan(tester);

      expect(terminalController.highlights.length, 2);
    });

    testWidgets('does not highlight plain text', (tester) async {
      final terminal = Terminal(maxLines: 100, reflowEnabled: false);

      await tester.pumpWidget(
        buildHarness(terminal: terminal, controller: terminalController),
      );
      await tester.pumpAndSettle();

      terminal.write('no urls here, just plain text\r\n');
      await pumpForUrlScan(tester);

      expect(terminalController.highlights, isEmpty);
    });

    testWidgets('clears highlights when URL detection is disabled', (
      tester,
    ) async {
      final terminal = Terminal(maxLines: 100, reflowEnabled: false);
      final notifier = _TestSettingsNotifier();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            settingsProvider.overrideWith(() => notifier),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 480,
                height: 360,
                child: PaneTerminalView(
                  terminal: terminal,
                  terminalController: terminalController,
                  paneWidth: 80,
                  paneHeight: 24,
                  backgroundColor: Colors.black,
                  foregroundColor: Colors.white,
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

      // Toggle detection off within the same provider scope
      notifier.toggleUrlDetection(false);
      await pumpForUrlScan(tester);

      expect(terminalController.highlights, isEmpty);
    });

    testWidgets('does not create highlights in select mode', (tester) async {
      final terminal = Terminal(maxLines: 100, reflowEnabled: false);

      await tester.pumpWidget(
        buildHarness(
          terminal: terminal,
          controller: terminalController,
          mode: PaneTerminalMode.select,
        ),
      );
      await tester.pumpAndSettle();

      terminal.write('https://example.com\r\n');
      await pumpForUrlScan(tester);

      expect(terminalController.highlights, isEmpty);
    });

    testWidgets('updates highlights when terminal content changes', (
      tester,
    ) async {
      final terminal = Terminal(maxLines: 100, reflowEnabled: false);

      await tester.pumpWidget(
        buildHarness(terminal: terminal, controller: terminalController),
      );
      await tester.pumpAndSettle();

      terminal.write('https://first.com\r\n');
      await pumpForUrlScan(tester);
      expect(terminalController.highlights.length, 1);

      terminal.write('https://second.com\r\n');
      await pumpForUrlScan(tester);
      expect(terminalController.highlights.length, 2);
    });

    testWidgets('highlights have underline enabled', (tester) async {
      final terminal = Terminal(maxLines: 100, reflowEnabled: false);

      await tester.pumpWidget(
        buildHarness(terminal: terminal, controller: terminalController),
      );
      await tester.pumpAndSettle();

      terminal.write('https://example.com\r\n');
      await pumpForUrlScan(tester);

      expect(terminalController.highlights, hasLength(1));
      expect(terminalController.highlights.first.underline, isTrue);
    });

    testWidgets('clears highlights when terminal is swapped', (tester) async {
      final terminal1 = Terminal(maxLines: 100, reflowEnabled: false);

      await tester.pumpWidget(
        buildHarness(terminal: terminal1, controller: terminalController),
      );
      await tester.pumpAndSettle();

      terminal1.write('https://example.com\r\n');
      await pumpForUrlScan(tester);
      expect(terminalController.highlights, isNotEmpty);

      // Swap to a terminal without URLs
      final terminal2 = Terminal(maxLines: 100, reflowEnabled: false);

      await tester.pumpWidget(
        buildHarness(terminal: terminal2, controller: terminalController),
      );
      await tester.pumpAndSettle();

      terminal2.write('no urls here\r\n');
      await pumpForUrlScan(tester);

      expect(terminalController.highlights, isEmpty);
    });

    testWidgets('detects URLs across multiple lines', (tester) async {
      final terminal = Terminal(maxLines: 100, reflowEnabled: false);

      await tester.pumpWidget(
        buildHarness(terminal: terminal, controller: terminalController),
      );
      await tester.pumpAndSettle();

      terminal.write('line 1 https://a.com\r\n');
      terminal.write('line 2 no url\r\n');
      terminal.write('line 3 https://b.com\r\n');
      await pumpForUrlScan(tester);

      expect(terminalController.highlights.length, 2);
    });

    testWidgets('handles empty terminal buffer', (tester) async {
      final terminal = Terminal(maxLines: 100, reflowEnabled: false);

      await tester.pumpWidget(
        buildHarness(terminal: terminal, controller: terminalController),
      );
      await tester.pumpAndSettle();
      await pumpForUrlScan(tester);

      expect(terminalController.highlights, isEmpty);
    });
  });
}
