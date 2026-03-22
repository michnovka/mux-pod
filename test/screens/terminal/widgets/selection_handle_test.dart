import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_muxpod/screens/terminal/widgets/selection_handle.dart';

void main() {
  group('SelectionHandle', () {
    testWidgets('renders CustomPaint', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Center(
              child: SelectionHandle(type: HandleType.left),
            ),
          ),
        ),
      );

      expect(find.byType(CustomPaint), findsWidgets);
      expect(find.byType(SelectionHandle), findsOneWidget);
    });

    testWidgets('has correct hit area size', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Center(
              child: SelectionHandle(type: HandleType.right),
            ),
          ),
        ),
      );

      final sizedBox = tester.widget<SizedBox>(
        find.descendant(
          of: find.byType(SelectionHandle),
          matching: find.byType(SizedBox),
        ),
      );
      expect(sizedBox.width, SelectionHandle.hitSize);
      expect(sizedBox.height, SelectionHandle.hitSize);
    });

    testWidgets('fires pan callbacks', (tester) async {
      var panStarted = false;
      var panUpdated = false;
      var panEnded = false;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SelectionHandle(
                type: HandleType.left,
                onPanStart: (_) => panStarted = true,
                onPanUpdate: (_) => panUpdated = true,
                onPanEnd: (_) => panEnded = true,
              ),
            ),
          ),
        ),
      );

      final center = tester.getCenter(find.byType(SelectionHandle));
      final gesture = await tester.startGesture(center);
      await tester.pump();
      await gesture.moveBy(const Offset(20, 0));
      await tester.pump();
      await gesture.up();
      await tester.pump();

      expect(panStarted, isTrue);
      expect(panUpdated, isTrue);
      expect(panEnded, isTrue);
    });
  });
}
