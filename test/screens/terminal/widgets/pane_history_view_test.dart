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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  GoogleFonts.config.allowRuntimeFetching = false;

  Widget buildHarness({
    required String content,
    required int paneWidth,
    required ScrollController verticalScrollController,
    required ScrollController horizontalScrollController,
    required bool hasMoreAbove,
    required bool isLoadingOlder,
    VoidCallback? onLoadOlder,
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
              hasMoreAbove: hasMoreAbove,
              isLoadingOlder: isLoadingOlder,
              onLoadOlder: onLoadOlder,
            ),
          ),
        ),
      ),
    );
  }

  group('PaneHistoryView', () {
    testWidgets('renders history content', (tester) async {
      final verticalController = ScrollController();
      final horizontalController = ScrollController();

      await tester.pumpWidget(
        buildHarness(
          content: 'alpha\nbeta\ngamma',
          paneWidth: 80,
          verticalScrollController: verticalController,
          horizontalScrollController: horizontalController,
          hasMoreAbove: false,
          isLoadingOlder: false,
        ),
      );

      expect(find.textContaining('alpha'), findsOneWidget);
      expect(find.textContaining('gamma'), findsOneWidget);
    });

    testWidgets('requests older history when overscrolling at the top', (
      tester,
    ) async {
      final verticalController = ScrollController();
      final horizontalController = ScrollController();
      var loadOlderCount = 0;
      final content = List.generate(120, (index) => 'line $index').join('\n');

      await tester.pumpWidget(
        buildHarness(
          content: content,
          paneWidth: 120,
          verticalScrollController: verticalController,
          horizontalScrollController: horizontalController,
          hasMoreAbove: true,
          isLoadingOlder: false,
          onLoadOlder: () {
            loadOlderCount += 1;
          },
        ),
      );
      await tester.pumpAndSettle();

      verticalController.jumpTo(verticalController.position.minScrollExtent);
      await tester.pumpAndSettle();

      final historyRect = tester.getRect(find.byType(PaneHistoryView));
      await tester.dragFrom(
        Offset(historyRect.center.dx, historyRect.top + 4),
        const Offset(0, 260),
      );
      await tester.pumpAndSettle();

      expect(loadOlderCount, greaterThanOrEqualTo(1));
    });
  });
}
