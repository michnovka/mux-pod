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

  /// Flush the 500ms URL scan debounce timer.
  Future<void> flushTimers(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 600));
  }

  group('PaneTerminalView keyboard behavior', () {
    testWidgets('single tap opens keyboard via onSingleTapUp', (
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

      // Close keyboard opened by autofocus
      terminalViewState.closeKeyboard();
      await tester.pumpAndSettle();
      expect(terminalViewState.hasInputConnection, isFalse);

      // Single tap should open keyboard (via onSingleTapUp)
      await tester.tap(find.byType(TerminalView));
      await tester.pumpAndSettle();

      expect(terminalViewState.hasInputConnection, isTrue);
      await flushTimers(tester);
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

      // Keyboard already open from autofocus
      expect(terminalViewState.hasInputConnection, isTrue);

      // Tap should keep it open
      await tester.tap(find.byType(TerminalView));
      await tester.pumpAndSettle();
      expect(terminalViewState.hasInputConnection, isTrue);

      await flushTimers(tester);
    });

    testWidgets('long-press does not open keyboard', (tester) async {
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

      // Long-press should NOT open keyboard
      await tester.longPress(find.byType(TerminalView));
      await tester.pumpAndSettle();

      expect(terminalViewState.hasInputConnection, isFalse);
      await flushTimers(tester);
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
      await flushTimers(tester);
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

      await flushTimers(tester);
    });
  });
}
