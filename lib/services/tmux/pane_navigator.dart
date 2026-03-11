import 'dart:ui' show Offset;

import 'tmux_parser.dart';

/// Swipe direction
enum SwipeDirection { up, down, left, right }

/// Direction inversion for SwipeDirection
extension SwipeDirectionExtension on SwipeDirection {
  /// Returns the inverted direction (up<->down, left<->right)
  SwipeDirection get inverted => switch (this) {
    SwipeDirection.up => SwipeDirection.down,
    SwipeDirection.down => SwipeDirection.up,
    SwipeDirection.left => SwipeDirection.right,
    SwipeDirection.right => SwipeDirection.left,
  };
}

/// Spatial navigation between panes
///
/// Uses TmuxPane's left/top/width/height fields (in character units)
/// to identify adjacent panes.
///
/// Since there is a 1-column/1-row separator between tmux panes,
/// the adjacent pane's coordinate is `current.left + current.width + 1`.
/// Using `>=` for adjacency checks makes it independent of separator width.
class PaneNavigator {
  /// Find the adjacent pane in the specified direction
  ///
  /// [panes] All panes in the current window
  /// [current] Active pane
  /// [direction] Swipe direction
  /// Returns null if not found
  static TmuxPane? findAdjacentPane({
    required List<TmuxPane> panes,
    required TmuxPane current,
    required SwipeDirection direction,
  }) {
    if (panes.length <= 1) return null;

    final candidates = <TmuxPane>[];

    for (final pane in panes) {
      if (pane.id == current.id) continue;

      switch (direction) {
        case SwipeDirection.right:
          // Right: pane's left edge is at or beyond current pane's right edge + vertical overlap exists
          if (pane.left >= current.left + current.width &&
              _hasVerticalOverlap(current, pane)) {
            candidates.add(pane);
          }
        case SwipeDirection.left:
          // Left: pane's right edge is at or before current pane's left edge + vertical overlap exists
          if (pane.left + pane.width <= current.left &&
              _hasVerticalOverlap(current, pane)) {
            candidates.add(pane);
          }
        case SwipeDirection.down:
          // Down: pane's top edge is at or beyond current pane's bottom edge + horizontal overlap exists
          if (pane.top >= current.top + current.height &&
              _hasHorizontalOverlap(current, pane)) {
            candidates.add(pane);
          }
        case SwipeDirection.up:
          // Up: pane's bottom edge is at or before current pane's top edge + horizontal overlap exists
          if (pane.top + pane.height <= current.top &&
              _hasHorizontalOverlap(current, pane)) {
            candidates.add(pane);
          }
      }
    }

    if (candidates.isEmpty) return null;

    // Return the closest candidate (Manhattan distance between centroids)
    candidates.sort((a, b) {
      final distA = _manhattanDistance(current, a);
      final distB = _manhattanDistance(current, b);
      return distA.compareTo(distB);
    });

    return candidates.first;
  }

  /// Return a map of whether adjacent panes exist in each direction
  static Map<SwipeDirection, bool> getNavigableDirections({
    required List<TmuxPane> panes,
    required TmuxPane current,
  }) {
    return {
      for (final dir in SwipeDirection.values)
        dir: findAdjacentPane(
              panes: panes,
              current: current,
              direction: dir,
            ) !=
            null,
    };
  }

  /// Determine swipe direction from two-finger swipe delta (dx, dy)
  ///
  /// Returns null if the movement is less than [threshold]
  static SwipeDirection? detectSwipeDirection(
    Offset delta, {
    double threshold = 50.0,
  }) {
    final dx = delta.dx;
    final dy = delta.dy;
    if (dx.abs() > dy.abs()) {
      if (dx > threshold) return SwipeDirection.right;
      if (dx < -threshold) return SwipeDirection.left;
    } else {
      if (dy > threshold) return SwipeDirection.down;
      if (dy < -threshold) return SwipeDirection.up;
    }
    return null;
  }

  /// Whether there is vertical overlap (used for horizontal movement)
  static bool _hasVerticalOverlap(TmuxPane a, TmuxPane b) {
    return b.top < a.top + a.height && b.top + b.height > a.top;
  }

  /// Whether there is horizontal overlap (used for vertical movement)
  static bool _hasHorizontalOverlap(TmuxPane a, TmuxPane b) {
    return b.left < a.left + a.width && b.left + b.width > a.left;
  }

  /// Manhattan distance between centroids
  static double _manhattanDistance(TmuxPane a, TmuxPane b) {
    final aCenterX = a.left + a.width / 2.0;
    final aCenterY = a.top + a.height / 2.0;
    final bCenterX = b.left + b.width / 2.0;
    final bCenterY = b.top + b.height / 2.0;
    return (aCenterX - bCenterX).abs() + (aCenterY - bCenterY).abs();
  }
}
