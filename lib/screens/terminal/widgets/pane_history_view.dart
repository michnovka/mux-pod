import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/settings_provider.dart';
import '../../../services/terminal/ansi_parser.dart';
import '../../../services/terminal/font_calculator.dart';

class PaneHistoryView extends ConsumerWidget {
  final String content;
  final int paneWidth;
  final Color backgroundColor;
  final Color foregroundColor;
  final double zoomScale;
  final bool renderContent;
  final ScrollController verticalScrollController;
  final ScrollController horizontalScrollController;
  final bool isLoading;
  final bool alternateScreen;
  final bool isSeedOnly;
  final bool reachedHistoryStart;
  final int loadedLineCount;
  final int retainedLineLimit;

  const PaneHistoryView({
    super.key,
    required this.content,
    required this.paneWidth,
    required this.backgroundColor,
    required this.foregroundColor,
    required this.zoomScale,
    this.renderContent = true,
    required this.verticalScrollController,
    required this.horizontalScrollController,
    required this.isLoading,
    required this.alternateScreen,
    required this.isSeedOnly,
    required this.reachedHistoryStart,
    required this.loadedLineCount,
    required this.retainedLineLimit,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final theme = Theme.of(context);
    final chipColor = theme.brightness == Brightness.dark
        ? Colors.black.withValues(alpha: 0.72)
        : Colors.white.withValues(alpha: 0.92);
    final chipBorderColor = foregroundColor.withValues(alpha: 0.15);

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
        final historyLineCount = loadedLineCount > 0 ? loadedLineCount : 1;
        final historyPadding = const EdgeInsets.fromLTRB(4, 4, 10, 8);

        Widget historyContent;
        if (!renderContent) {
          final textPainter = TextPainter(
            text: TextSpan(
              text: 'Ag',
              style: TextStyle(
                fontSize: fontSize,
                fontFamily: settings.fontFamily,
              ),
            ),
            textDirection: TextDirection.ltr,
            textScaler: TextScaler.noScaling,
          )..layout();

          final reservedHeight =
              (textPainter.preferredLineHeight * historyLineCount) +
              historyPadding.vertical;
          historyContent = SizedBox(
            width: constraints.maxWidth,
            height: reservedHeight,
          );
        } else {
          final ansiParser = AnsiParser(
            defaultForeground: foregroundColor,
            defaultBackground: backgroundColor,
          );
          final historyText = content.isEmpty ? ' ' : content;
          final historySpan = ansiParser.parseToTextSpan(
            historyText,
            fontSize: fontSize,
            fontFamily: settings.fontFamily,
          );

          Widget historyBody = SelectionArea(
            child: Padding(
              padding: historyPadding,
              child: RichText(
                text: historySpan,
                softWrap: false,
                textScaler: TextScaler.noScaling,
              ),
            ),
          );

          historyContent = ConstrainedBox(
            constraints: BoxConstraints(
              minWidth: needsHorizontalScroll
                  ? terminalWidth
                  : constraints.maxWidth,
            ),
            child: historyBody,
          );

          if (needsHorizontalScroll) {
            historyContent = SingleChildScrollView(
              controller: horizontalScrollController,
              scrollDirection: Axis.horizontal,
              physics: const ClampingScrollPhysics(),
              child: historyContent,
            );
          }
        }

        return ColoredBox(
          color: backgroundColor,
          child: Stack(
            children: [
              historyContent,
              if (renderContent)
                Positioned(
                  left: 12,
                  bottom: 12,
                  child: AnimatedBuilder(
                    animation: verticalScrollController,
                    builder: (context, _) {
                      if (!verticalScrollController.hasClients ||
                          loadedLineCount <= 0) {
                        return const SizedBox.shrink();
                      }

                      final position = verticalScrollController.position;
                      if (!position.hasContentDimensions) {
                        return const SizedBox.shrink();
                      }
                      final fraction = position.maxScrollExtent <= 0
                          ? 1.0
                          : (position.pixels / position.maxScrollExtent).clamp(
                              0.0,
                              1.0,
                            );
                      final approxLine =
                          ((loadedLineCount - 1) * fraction).round() + 1;

                      return DecoratedBox(
                        decoration: BoxDecoration(
                          color: chipColor,
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(color: chipBorderColor),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 6,
                          ),
                          child: Text(
                            '~ line $approxLine / $loadedLineCount',
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: foregroundColor,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}
