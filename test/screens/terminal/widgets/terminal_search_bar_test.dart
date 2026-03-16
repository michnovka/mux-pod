import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:flutter_muxpod/screens/terminal/widgets/terminal_search_bar.dart';
import 'package:flutter_muxpod/services/terminal/terminal_search_state.dart';
import 'package:flutter_muxpod/services/terminal/terminal_search_engine.dart';
import 'package:xterm/xterm.dart';

/// Creates dummy [TerminalSearchMatch] instances for testing.
TerminalSearchMatch _dummyMatch(int row, int startCol, int endCol) {
  return TerminalSearchMatch(
    start: CellOffset(startCol, row),
    end: CellOffset(endCol, row),
  );
}

Widget buildHarness({
  TerminalSearchState? searchState,
  FocusNode? focusNode,
  ValueChanged<String>? onQueryChanged,
  VoidCallback? onNextMatch,
  VoidCallback? onPreviousMatch,
  VoidCallback? onClose,
  VoidCallback? onToggleCaseSensitive,
  VoidCallback? onToggleRegex,
}) {
  return MaterialApp(
    home: Scaffold(
      body: TerminalSearchBar(
        searchState: searchState ?? const TerminalSearchState(),
        focusNode: focusNode ?? FocusNode(),
        onQueryChanged: onQueryChanged ?? (_) {},
        onNextMatch: onNextMatch ?? () {},
        onPreviousMatch: onPreviousMatch ?? () {},
        onClose: onClose ?? () {},
        onToggleCaseSensitive: onToggleCaseSensitive ?? () {},
        onToggleRegex: onToggleRegex ?? () {},
      ),
    ),
  );
}

void main() {
  GoogleFonts.config.allowRuntimeFetching = false;

  group('TerminalSearchBar', () {
    testWidgets('TextField receives focus on focusNode.requestFocus()',
        (tester) async {
      final focusNode = FocusNode();

      await tester.pumpWidget(buildHarness(focusNode: focusNode));
      await tester.pumpAndSettle();

      expect(focusNode.hasFocus, isFalse);

      focusNode.requestFocus();
      await tester.pumpAndSettle();

      expect(focusNode.hasFocus, isTrue);

      focusNode.dispose();
    });

    testWidgets('onQueryChanged fires on text input', (tester) async {
      String? receivedQuery;

      await tester.pumpWidget(
        buildHarness(onQueryChanged: (value) => receivedQuery = value),
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'hello');
      await tester.pump();

      expect(receivedQuery, 'hello');
    });

    testWidgets('Match count label shows "No results" when 0 matches',
        (tester) async {
      final state = TerminalSearchState(
        query: 'missing',
        matches: const [],
        currentMatchIndex: -1,
        isActive: true,
      );

      await tester.pumpWidget(buildHarness(searchState: state));
      await tester.pumpAndSettle();

      expect(find.text('No results'), findsOneWidget);
    });

    testWidgets('Match count label shows "N of M" when matches exist',
        (tester) async {
      final matches = [
        _dummyMatch(0, 0, 3),
        _dummyMatch(1, 5, 8),
        _dummyMatch(2, 10, 13),
      ];
      final state = TerminalSearchState(
        query: 'test',
        matches: matches,
        currentMatchIndex: 2,
        isActive: true,
      );

      await tester.pumpWidget(buildHarness(searchState: state));
      await tester.pumpAndSettle();

      expect(find.text('3 of 3'), findsOneWidget);
    });

    testWidgets('Match count label shows "Invalid regex" on regex error',
        (tester) async {
      final state = TerminalSearchState(
        query: '[invalid',
        regexEnabled: true,
        regexError: 'Unterminated character class',
        matches: const [],
        currentMatchIndex: -1,
        isActive: true,
      );

      await tester.pumpWidget(buildHarness(searchState: state));
      await tester.pumpAndSettle();

      expect(find.text('Invalid regex'), findsOneWidget);
    });

    testWidgets('All buttons call correct callbacks', (tester) async {
      bool caseSensitiveCalled = false;
      bool regexCalled = false;
      bool previousCalled = false;
      bool nextCalled = false;
      bool closeCalled = false;

      // Provide matches so navigation buttons are enabled.
      final matches = [_dummyMatch(0, 0, 3)];
      final state = TerminalSearchState(
        query: 'test',
        matches: matches,
        currentMatchIndex: 0,
        isActive: true,
      );

      await tester.pumpWidget(
        buildHarness(
          searchState: state,
          onToggleCaseSensitive: () => caseSensitiveCalled = true,
          onToggleRegex: () => regexCalled = true,
          onPreviousMatch: () => previousCalled = true,
          onNextMatch: () => nextCalled = true,
          onClose: () => closeCalled = true,
        ),
      );
      await tester.pumpAndSettle();

      // Tap "Aa" toggle (case sensitive).
      await tester.tap(find.text('Aa'));
      await tester.pump();
      expect(caseSensitiveCalled, isTrue);

      // Tap ".*" toggle (regex).
      await tester.tap(find.text('.*'));
      await tester.pump();
      expect(regexCalled, isTrue);

      // Tap up arrow (previous match).
      await tester.tap(find.byIcon(Icons.keyboard_arrow_up));
      await tester.pump();
      expect(previousCalled, isTrue);

      // Tap down arrow (next match).
      await tester.tap(find.byIcon(Icons.keyboard_arrow_down));
      await tester.pump();
      expect(nextCalled, isTrue);

      // Tap close button.
      await tester.tap(find.byIcon(Icons.close));
      await tester.pump();
      expect(closeCalled, isTrue);
    });

    testWidgets('Navigation buttons disabled when no matches',
        (tester) async {
      bool previousCalled = false;
      bool nextCalled = false;

      final state = TerminalSearchState(
        query: 'nope',
        matches: const [],
        currentMatchIndex: -1,
        isActive: true,
      );

      await tester.pumpWidget(
        buildHarness(
          searchState: state,
          onPreviousMatch: () => previousCalled = true,
          onNextMatch: () => nextCalled = true,
        ),
      );
      await tester.pumpAndSettle();

      // Tap up arrow — should not fire callback because onPressed is null.
      await tester.tap(find.byIcon(Icons.keyboard_arrow_up));
      await tester.pump();
      expect(previousCalled, isFalse);

      // Tap down arrow — should not fire callback because onPressed is null.
      await tester.tap(find.byIcon(Icons.keyboard_arrow_down));
      await tester.pump();
      expect(nextCalled, isFalse);
    });

    testWidgets('Toggle visual state for case-sensitive active',
        (tester) async {
      final state = TerminalSearchState(
        query: 'test',
        caseSensitive: true,
        isActive: true,
      );

      await tester.pumpWidget(buildHarness(searchState: state));
      await tester.pumpAndSettle();

      // When caseSensitive is active, the "Aa" button's parent IconButton
      // should have a non-null style with a background color.
      final aaTextWidget = find.text('Aa');
      expect(aaTextWidget, findsOneWidget);

      // Walk up to find the IconButton wrapping the "Aa" text.
      final iconButton = find.ancestor(
        of: aaTextWidget,
        matching: find.byType(IconButton),
      );
      expect(iconButton, findsOneWidget);

      final iconButtonWidget = tester.widget<IconButton>(iconButton);
      // When active, style is set with a background color.
      expect(iconButtonWidget.style, isNotNull);
    });
  });
}
