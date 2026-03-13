import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/settings_provider.dart';
import '../../../services/terminal/font_calculator.dart';
import '../../../services/terminal/terminal_font_styles.dart';

class PaneHistoryView extends ConsumerWidget {
  final String content;
  final int paneWidth;
  final Color backgroundColor;
  final Color foregroundColor;
  final double zoomScale;
  final ScrollController verticalScrollController;
  final ScrollController horizontalScrollController;
  final bool hasMoreAbove;
  final bool isLoadingOlder;
  final VoidCallback? onLoadOlder;

  const PaneHistoryView({
    super.key,
    required this.content,
    required this.paneWidth,
    required this.backgroundColor,
    required this.foregroundColor,
    required this.zoomScale,
    required this.verticalScrollController,
    required this.horizontalScrollController,
    required this.hasMoreAbove,
    required this.isLoadingOlder,
    this.onLoadOlder,
  });

  bool _handleScrollNotification(ScrollNotification notification) {
    if (notification.metrics.axis != Axis.vertical) {
      return false;
    }
    if (!hasMoreAbove || isLoadingOlder || onLoadOlder == null) {
      return false;
    }

    final isNearTop =
        notification.metrics.pixels <=
        notification.metrics.minScrollExtent + 32;
    if (!isNearTop) {
      return false;
    }

    final shouldLoadOlder =
        (notification is OverscrollNotification &&
            notification.dragDetails != null) ||
        (notification is ScrollUpdateNotification &&
            notification.dragDetails != null);

    if (shouldLoadOlder) {
      onLoadOlder?.call();
    }

    return false;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);

    return LayoutBuilder(
      builder: (context, constraints) {
        final baseFontSize = settings.autoFitEnabled
            ? FontCalculator.calculate(
                screenWidth: constraints.maxWidth,
                paneCharWidth: paneWidth,
                fontFamily: settings.fontFamily,
                minFontSize: settings.minFontSize,
              ).fontSize
            : settings.fontSize;

        final fontSize = baseFontSize * zoomScale;
        final terminalWidth = FontCalculator.calculateTerminalWidth(
          paneCharWidth: paneWidth,
          fontSize: fontSize,
          fontFamily: settings.fontFamily,
        );
        final needsHorizontalScroll = terminalWidth > constraints.maxWidth;

        Widget historyContent = ConstrainedBox(
          constraints: BoxConstraints(
            minWidth: needsHorizontalScroll
                ? terminalWidth
                : constraints.maxWidth,
          ),
          child: SelectionArea(
            child: SingleChildScrollView(
              controller: verticalScrollController,
              physics: const ClampingScrollPhysics(),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 18),
              child: Text(
                content.isEmpty ? ' ' : content,
                softWrap: false,
                style: TerminalFontStyles.getTextStyle(
                  settings.fontFamily,
                  fontSize: fontSize,
                  height: 1.4,
                  color: foregroundColor,
                ),
              ),
            ),
          ),
        );

        if (needsHorizontalScroll) {
          historyContent = SingleChildScrollView(
            controller: horizontalScrollController,
            scrollDirection: Axis.horizontal,
            physics: const ClampingScrollPhysics(),
            child: historyContent,
          );
        }

        return NotificationListener<ScrollNotification>(
          onNotification: _handleScrollNotification,
          child: ColoredBox(color: backgroundColor, child: historyContent),
        );
      },
    );
  }
}
