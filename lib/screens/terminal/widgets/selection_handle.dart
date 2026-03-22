import 'package:flutter/material.dart';

import '../../../theme/design_colors.dart';

enum HandleType { left, right }

class SelectionHandle extends StatelessWidget {
  final HandleType type;
  final GestureDragStartCallback? onPanStart;
  final GestureDragUpdateCallback? onPanUpdate;
  final GestureDragEndCallback? onPanEnd;

  static const double _circleRadius = 6;
  static const double _stemLength = 12;
  static const double _stemWidth = 2;
  static const double visualWidth = _circleRadius * 2;
  static const double visualHeight = _circleRadius + _stemLength;

  /// Total hit area size (padded around the visual handle).
  static const double hitSize = 44;

  const SelectionHandle({
    super.key,
    required this.type,
    this.onPanStart,
    this.onPanUpdate,
    this.onPanEnd,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanStart: onPanStart,
      onPanUpdate: onPanUpdate,
      onPanEnd: onPanEnd,
      child: SizedBox(
        width: hitSize,
        height: hitSize,
        child: CustomPaint(
          painter: _HandlePainter(
            type: type,
            color: DesignColors.primary,
          ),
        ),
      ),
    );
  }
}

class _HandlePainter extends CustomPainter {
  final HandleType type;
  final Color color;

  const _HandlePainter({required this.type, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    // The handle attaches at the top-center of the hit area for the
    // "connection point" (the cell corner), with the teardrop hanging below.
    final cx = size.width / 2;
    const topY = (SelectionHandle.hitSize - SelectionHandle.visualHeight) / 2;

    // Stem: vertical line from the circle down
    final stemTop = topY + SelectionHandle._circleRadius;
    canvas.drawRect(
      Rect.fromLTWH(
        cx - SelectionHandle._stemWidth / 2,
        stemTop,
        SelectionHandle._stemWidth,
        SelectionHandle._stemLength,
      ),
      paint,
    );

    // Circle at the top
    canvas.drawCircle(Offset(cx, topY + SelectionHandle._circleRadius), SelectionHandle._circleRadius, paint);

    // Small directional indicator: a tiny triangle on the circle
    // pointing left for HandleType.left, right for HandleType.right
    final indicatorPath = Path();
    const indicatorSize = 3.0;
    if (type == HandleType.left) {
      indicatorPath.moveTo(cx - SelectionHandle._circleRadius + 1, topY + SelectionHandle._circleRadius);
      indicatorPath.lineTo(cx - SelectionHandle._circleRadius + 1 + indicatorSize, topY + SelectionHandle._circleRadius - indicatorSize);
      indicatorPath.lineTo(cx - SelectionHandle._circleRadius + 1 + indicatorSize, topY + SelectionHandle._circleRadius + indicatorSize);
    } else {
      indicatorPath.moveTo(cx + SelectionHandle._circleRadius - 1, topY + SelectionHandle._circleRadius);
      indicatorPath.lineTo(cx + SelectionHandle._circleRadius - 1 - indicatorSize, topY + SelectionHandle._circleRadius - indicatorSize);
      indicatorPath.lineTo(cx + SelectionHandle._circleRadius - 1 - indicatorSize, topY + SelectionHandle._circleRadius + indicatorSize);
    }
    indicatorPath.close();
    canvas.drawPath(
      indicatorPath,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.8)
        ..style = PaintingStyle.fill,
    );
  }

  @override
  bool shouldRepaint(_HandlePainter oldDelegate) =>
      type != oldDelegate.type || color != oldDelegate.color;
}
