import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_muxpod/services/tmux/pane_navigator.dart';
import 'package:flutter_muxpod/services/tmux/tmux_parser.dart';

void main() {
  group('PaneNavigator', () {
    group('findAdjacentPane', () {
      test('horizontal 2-split left/right navigation', () {
        final panes = [
          const TmuxPane(index: 0, id: '%0', left: 0, top: 0, width: 40, height: 24),
          const TmuxPane(index: 1, id: '%1', left: 41, top: 0, width: 39, height: 24),
        ];

        // pane0 right -> pane1
        final right = PaneNavigator.findAdjacentPane(
          panes: panes,
          current: panes[0],
          direction: SwipeDirection.right,
        );
        expect(right?.id, '%1');

        // pane1 left -> pane0
        final left = PaneNavigator.findAdjacentPane(
          panes: panes,
          current: panes[1],
          direction: SwipeDirection.left,
        );
        expect(left?.id, '%0');

        // pane0 left -> null (edge)
        final noLeft = PaneNavigator.findAdjacentPane(
          panes: panes,
          current: panes[0],
          direction: SwipeDirection.left,
        );
        expect(noLeft, isNull);

        // pane1 right -> null (edge)
        final noRight = PaneNavigator.findAdjacentPane(
          panes: panes,
          current: panes[1],
          direction: SwipeDirection.right,
        );
        expect(noRight, isNull);
      });

      test('vertical 2-split up/down navigation', () {
        final panes = [
          const TmuxPane(index: 0, id: '%0', left: 0, top: 0, width: 80, height: 12),
          const TmuxPane(index: 1, id: '%1', left: 0, top: 13, width: 80, height: 11),
        ];

        // pane0 down -> pane1
        final down = PaneNavigator.findAdjacentPane(
          panes: panes,
          current: panes[0],
          direction: SwipeDirection.down,
        );
        expect(down?.id, '%1');

        // pane1 up -> pane0
        final up = PaneNavigator.findAdjacentPane(
          panes: panes,
          current: panes[1],
          direction: SwipeDirection.up,
        );
        expect(up?.id, '%0');

        // pane0 up -> null
        expect(
          PaneNavigator.findAdjacentPane(
            panes: panes,
            current: panes[0],
            direction: SwipeDirection.up,
          ),
          isNull,
        );
      });

      test('vertical 3-split returns closest pane', () {
        final panes = [
          const TmuxPane(index: 0, id: '%0', left: 0, top: 0, width: 80, height: 12),
          const TmuxPane(index: 1, id: '%1', left: 0, top: 13, width: 80, height: 12),
          const TmuxPane(index: 2, id: '%2', left: 0, top: 26, width: 80, height: 11),
        ];

        // pane0 down -> pane1 (closest pane1, not pane2)
        final down = PaneNavigator.findAdjacentPane(
          panes: panes,
          current: panes[0],
          direction: SwipeDirection.down,
        );
        expect(down?.id, '%1');

        // pane2 up -> pane1
        final up = PaneNavigator.findAdjacentPane(
          panes: panes,
          current: panes[2],
          direction: SwipeDirection.up,
        );
        expect(up?.id, '%1');
      });

      test('T-layout overlap condition works', () {
        // Top: one wide pane
        // Bottom: two panes left and right
        final panes = [
          const TmuxPane(index: 0, id: '%0', left: 0, top: 0, width: 80, height: 12),
          const TmuxPane(index: 1, id: '%1', left: 0, top: 13, width: 40, height: 11),
          const TmuxPane(index: 2, id: '%2', left: 41, top: 13, width: 39, height: 11),
        ];

        // pane0 down: pane1 or pane2 (both overlap, returns the closest)
        final down = PaneNavigator.findAdjacentPane(
          panes: panes,
          current: panes[0],
          direction: SwipeDirection.down,
        );
        expect(down, isNotNull);
        expect(['%1', '%2'], contains(down?.id));

        // pane1 up -> pane0 (overlap exists)
        final up = PaneNavigator.findAdjacentPane(
          panes: panes,
          current: panes[1],
          direction: SwipeDirection.up,
        );
        expect(up?.id, '%0');

        // pane1 right -> pane2
        final right = PaneNavigator.findAdjacentPane(
          panes: panes,
          current: panes[1],
          direction: SwipeDirection.right,
        );
        expect(right?.id, '%2');
      });

      test('L-layout returns null for non-overlapping directions', () {
        // Top-left: pane0
        // Top-right: pane1
        // Bottom-left: pane2 (no pane in bottom-right)
        final panes = [
          const TmuxPane(index: 0, id: '%0', left: 0, top: 0, width: 40, height: 12),
          const TmuxPane(index: 1, id: '%1', left: 41, top: 0, width: 39, height: 24),
          const TmuxPane(index: 2, id: '%2', left: 0, top: 13, width: 40, height: 11),
        ];

        // pane2 right -> pane1 (vertical overlap exists)
        final right = PaneNavigator.findAdjacentPane(
          panes: panes,
          current: panes[2],
          direction: SwipeDirection.right,
        );
        expect(right?.id, '%1');
      });

      test('single pane returns null for all directions', () {
        final panes = [
          const TmuxPane(index: 0, id: '%0', left: 0, top: 0, width: 80, height: 24),
        ];

        for (final direction in SwipeDirection.values) {
          expect(
            PaneNavigator.findAdjacentPane(
              panes: panes,
              current: panes[0],
              direction: direction,
            ),
            isNull,
          );
        }
      });

      test('empty pane list returns null', () {
        const current = TmuxPane(index: 0, id: '%0', left: 0, top: 0, width: 80, height: 24);
        for (final direction in SwipeDirection.values) {
          expect(
            PaneNavigator.findAdjacentPane(
              panes: const [],
              current: current,
              direction: direction,
            ),
            isNull,
          );
        }
      });
    });

    group('getNavigableDirections', () {
      test('horizontal 2-split returns correct direction map', () {
        final panes = [
          const TmuxPane(index: 0, id: '%0', left: 0, top: 0, width: 40, height: 24),
          const TmuxPane(index: 1, id: '%1', left: 41, top: 0, width: 39, height: 24),
        ];

        final dirs = PaneNavigator.getNavigableDirections(
          panes: panes,
          current: panes[0],
        );

        expect(dirs[SwipeDirection.right], isTrue);
        expect(dirs[SwipeDirection.left], isFalse);
        expect(dirs[SwipeDirection.up], isFalse);
        expect(dirs[SwipeDirection.down], isFalse);
      });

      test('single pane returns false for all directions', () {
        final panes = [
          const TmuxPane(index: 0, id: '%0', left: 0, top: 0, width: 80, height: 24),
        ];

        final dirs = PaneNavigator.getNavigableDirections(
          panes: panes,
          current: panes[0],
        );

        for (final dir in SwipeDirection.values) {
          expect(dirs[dir], isFalse);
        }
      });
    });

    group('detectSwipeDirection', () {
      test('detects right swipe', () {
        expect(
          PaneNavigator.detectSwipeDirection(const Offset(60, 10)),
          SwipeDirection.right,
        );
      });

      test('detects left swipe', () {
        expect(
          PaneNavigator.detectSwipeDirection(const Offset(-60, -10)),
          SwipeDirection.left,
        );
      });

      test('detects down swipe', () {
        expect(
          PaneNavigator.detectSwipeDirection(const Offset(10, 60)),
          SwipeDirection.down,
        );
      });

      test('detects up swipe', () {
        expect(
          PaneNavigator.detectSwipeDirection(const Offset(-10, -60)),
          SwipeDirection.up,
        );
      });

      test('movement below threshold returns null', () {
        expect(
          PaneNavigator.detectSwipeDirection(const Offset(30, 10)),
          isNull,
        );
        expect(
          PaneNavigator.detectSwipeDirection(const Offset(10, 30)),
          isNull,
        );
        expect(
          PaneNavigator.detectSwipeDirection(Offset.zero),
          isNull,
        );
      });

      test('detects with custom threshold', () {
        // Not detected with default threshold (50), but detected with threshold 20
        expect(
          PaneNavigator.detectSwipeDirection(const Offset(30, 5)),
          isNull,
        );
        expect(
          PaneNavigator.detectSwipeDirection(const Offset(30, 5), threshold: 20),
          SwipeDirection.right,
        );
      });

      test('vertical direction takes priority when dx == dy', () {
        // When abs(dx) == abs(dy), falls into the dy side else branch
        expect(
          PaneNavigator.detectSwipeDirection(const Offset(60, 60)),
          SwipeDirection.down,
        );
        expect(
          PaneNavigator.detectSwipeDirection(const Offset(-60, -60)),
          SwipeDirection.up,
        );
      });
    });

    group('SwipeDirectionExtension.inverted', () {
      test('up inverted is down', () {
        expect(SwipeDirection.up.inverted, SwipeDirection.down);
      });

      test('down inverted is up', () {
        expect(SwipeDirection.down.inverted, SwipeDirection.up);
      });

      test('left inverted is right', () {
        expect(SwipeDirection.left.inverted, SwipeDirection.right);
      });

      test('right inverted is left', () {
        expect(SwipeDirection.right.inverted, SwipeDirection.left);
      });

      test('double inversion returns to original', () {
        for (final dir in SwipeDirection.values) {
          expect(dir.inverted.inverted, dir);
        }
      });
    });
  });
}
