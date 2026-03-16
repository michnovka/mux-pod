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
    required Terminal terminal,
    required TerminalController controller,
  }) {
    return ProviderScope(
      overrides: [settingsProvider.overrideWith(() => _TestSettingsNotifier())],
      child: MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 480,
            height: 360,
            child: PaneTerminalView(
              terminal: terminal,
              terminalController: controller,
              paneWidth: 80,
              paneHeight: 24,
              backgroundColor: Colors.black,
              foregroundColor: Colors.white,
            ),
          ),
        ),
      ),
    );
  }

  group('PaneTerminalView keyboard behavior', () {
    testWidgets('tap re-opens keyboard after it was closed', (tester) async {
      final terminal = Terminal(maxLines: 100, reflowEnabled: false);
      final controller = TerminalController();

      await tester.pumpWidget(
        buildHarness(terminal: terminal, controller: controller),
      );
      await tester.pumpAndSettle();

      final terminalViewState = tester.state<TerminalViewState>(
        find.byType(TerminalView),
      );

      // Autofocus opens connection — close it to simulate hidden keyboard
      terminalViewState.closeKeyboard();
      await tester.pumpAndSettle();
      expect(terminalViewState.hasInputConnection, isFalse);

      // Tap should reopen
      await tester.tap(find.byType(TerminalView));
      await tester.pumpAndSettle();

      expect(terminalViewState.hasInputConnection, isTrue);

      // Flush URL scan debounce timer
      await tester.pump(const Duration(milliseconds: 600));
    });

    testWidgets('tap keeps keyboard open when already connected', (
      tester,
    ) async {
      final terminal = Terminal(maxLines: 100, reflowEnabled: false);
      final controller = TerminalController();

      await tester.pumpWidget(
        buildHarness(terminal: terminal, controller: controller),
      );
      await tester.pumpAndSettle();

      final terminalViewState = tester.state<TerminalViewState>(
        find.byType(TerminalView),
      );

      // Keyboard is already open from autofocus
      expect(terminalViewState.hasInputConnection, isTrue);

      // Tap should keep it open
      await tester.tap(find.byType(TerminalView));
      await tester.pumpAndSettle();
      expect(terminalViewState.hasInputConnection, isTrue);

      await tester.pump(const Duration(milliseconds: 600));
    });

    testWidgets('long-press closes keyboard that was opened by tap-down', (
      tester,
    ) async {
      final terminal = Terminal(maxLines: 100, reflowEnabled: false);
      final controller = TerminalController();

      await tester.pumpWidget(
        buildHarness(terminal: terminal, controller: controller),
      );
      await tester.pumpAndSettle();

      final terminalViewState = tester.state<TerminalViewState>(
        find.byType(TerminalView),
      );

      // Close keyboard to simulate hidden state
      terminalViewState.closeKeyboard();
      await tester.pumpAndSettle();
      expect(terminalViewState.hasInputConnection, isFalse);

      // Long-press: tap-down re-opens keyboard, but long-press handler
      // should close it because it was hidden before tap-down
      await tester.longPress(find.byType(TerminalView));
      await tester.pumpAndSettle();

      expect(terminalViewState.hasInputConnection, isFalse);

      await tester.pump(const Duration(milliseconds: 600));
    });

    testWidgets('long-press keeps keyboard when it was already open', (
      tester,
    ) async {
      final terminal = Terminal(maxLines: 100, reflowEnabled: false);
      final controller = TerminalController();

      await tester.pumpWidget(
        buildHarness(terminal: terminal, controller: controller),
      );
      await tester.pumpAndSettle();

      final terminalViewState = tester.state<TerminalViewState>(
        find.byType(TerminalView),
      );

      // Keyboard already open from autofocus
      expect(terminalViewState.hasInputConnection, isTrue);

      // Long-press should NOT close the keyboard
      await tester.longPress(find.byType(TerminalView));
      await tester.pumpAndSettle();

      expect(terminalViewState.hasInputConnection, isTrue);

      await tester.pump(const Duration(milliseconds: 600));
    });

    testWidgets('onTapUp and onLongPressStart are wired for URL detection', (
      tester,
    ) async {
      final terminal = Terminal(maxLines: 100, reflowEnabled: false);
      final controller = TerminalController();

      await tester.pumpWidget(
        buildHarness(terminal: terminal, controller: controller),
      );
      await tester.pumpAndSettle();

      final terminalView = tester.widget<TerminalView>(
        find.byType(TerminalView),
      );
      expect(terminalView.onTapUp, isNotNull);
      expect(terminalView.onLongPressStart, isNotNull);
    });
  });
}
