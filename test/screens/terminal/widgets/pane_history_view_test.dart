import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_muxpod/providers/settings_provider.dart';
import 'package:flutter_muxpod/screens/terminal/widgets/pane_history_view.dart';
import 'package:google_fonts/google_fonts.dart';

class _TestSettingsNotifier extends SettingsNotifier {
  @override
  AppSettings build() {
    return const AppSettings(fontFamily: 'HackGen Console');
  }
}

InlineSpan? _findSpanByText(InlineSpan span, String text) {
  if (span is TextSpan) {
    if (span.text == text) {
      return span;
    }
    for (final child in span.children ?? const <InlineSpan>[]) {
      final found = _findSpanByText(child, text);
      if (found != null) {
        return found;
      }
    }
  }
  return null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  GoogleFonts.config.allowRuntimeFetching = false;

  Widget buildHarness({
    required String content,
    required int paneWidth,
    required ScrollController verticalScrollController,
    required ScrollController horizontalScrollController,
    required bool isLoading,
    required bool alternateScreen,
    required bool isSeedOnly,
    required bool reachedHistoryStart,
    required int loadedLineCount,
    required int retainedLineLimit,
  }) {
    return ProviderScope(
      overrides: [settingsProvider.overrideWith(() => _TestSettingsNotifier())],
      child: MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 260,
            height: 200,
            child: PaneHistoryView(
              content: content,
              paneWidth: paneWidth,
              backgroundColor: Colors.black,
              foregroundColor: Colors.white,
              zoomScale: 1.0,
              verticalScrollController: verticalScrollController,
              horizontalScrollController: horizontalScrollController,
              isLoading: isLoading,
              alternateScreen: alternateScreen,
              isSeedOnly: isSeedOnly,
              reachedHistoryStart: reachedHistoryStart,
              loadedLineCount: loadedLineCount,
              retainedLineLimit: retainedLineLimit,
            ),
          ),
        ),
      ),
    );
  }

  group('PaneHistoryView', () {
    testWidgets('renders ansi history content inside the unified surface', (
      tester,
    ) async {
      final verticalController = ScrollController();
      final horizontalController = ScrollController();

      await tester.pumpWidget(
        buildHarness(
          content: List.generate(
            24,
            (index) => index == 5 ? 'plain \x1b[31mred\x1b[0m' : 'line $index',
          ).join('\n'),
          paneWidth: 80,
          verticalScrollController: verticalController,
          horizontalScrollController: horizontalController,
          isLoading: false,
          alternateScreen: false,
          isSeedOnly: false,
          reachedHistoryStart: true,
          loadedLineCount: 321,
          retainedLineLimit: 1000,
        ),
      );

      final richText = tester.widget<RichText>(find.byType(RichText).last);
      final redSpan = _findSpanByText(richText.text, 'red');
      expect(redSpan, isA<TextSpan>());
      expect((redSpan as TextSpan).style?.color, const Color(0xFFCD3131));
    });

    testWidgets('shows a seed-only loading message while full history loads', (
      tester,
    ) async {
      final verticalController = ScrollController();
      final horizontalController = ScrollController();

      await tester.pumpWidget(
        buildHarness(
          content: 'tail line',
          paneWidth: 80,
          verticalScrollController: verticalController,
          horizontalScrollController: horizontalController,
          isLoading: true,
          alternateScreen: false,
          isSeedOnly: true,
          reachedHistoryStart: false,
          loadedLineCount: 1,
          retainedLineLimit: 10000,
        ),
      );

      expect(find.byType(RichText), findsOneWidget);
    });
  });
}
