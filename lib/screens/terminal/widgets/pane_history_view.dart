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
    required this.verticalScrollController,
    required this.horizontalScrollController,
    required this.isLoading,
    required this.alternateScreen,
    required this.isSeedOnly,
    required this.reachedHistoryStart,
    required this.loadedLineCount,
    required this.retainedLineLimit,
  });

  String get _topStatusTitle {
    if (alternateScreen) {
      return 'Alternate screen snapshot';
    }
    if (isLoading) {
      return 'Loading retained history...';
    }
    if (isSeedOnly) {
      return 'Recent tail only';
    }
    if (reachedHistoryStart) {
      return 'Start of retained history';
    }
    return 'Top of loaded history';
  }

  String get _topStatusDetail {
    if (alternateScreen) {
      return 'This pane is using an alternate screen, so only the visible snapshot is available here.';
    }
    if (isLoading) {
      return 'Showing the recent tail while tmux fetches up to $retainedLineLimit retained lines.';
    }
    if (isSeedOnly) {
      return 'Retained history is unavailable right now, so this view is showing only the recent visible tail.';
    }
    if (reachedHistoryStart) {
      return '$loadedLineCount retained lines loaded.';
    }
    return 'Showing the latest $loadedLineCount of up to $retainedLineLimit retained lines.';
  }

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

        Widget scrollableHistory = Scrollbar(
          controller: verticalScrollController,
          thumbVisibility: true,
          trackVisibility: true,
          interactive: true,
          child: SelectionArea(
            child: SingleChildScrollView(
              controller: verticalScrollController,
              physics: const ClampingScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(14, 18, 18, 18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  DecoratedBox(
                    decoration: BoxDecoration(
                      color: chipColor,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: chipBorderColor),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _topStatusTitle,
                            style: theme.textTheme.labelLarge?.copyWith(
                              color: foregroundColor,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            _topStatusDetail,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: foregroundColor.withValues(alpha: 0.72),
                              height: 1.35,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  RichText(
                    text: historySpan,
                    softWrap: false,
                    textScaler: TextScaler.noScaling,
                  ),
                ],
              ),
            ),
          ),
        );

        Widget historyContent = ConstrainedBox(
          constraints: BoxConstraints(
            minWidth: needsHorizontalScroll
                ? terminalWidth
                : constraints.maxWidth,
          ),
          child: scrollableHistory,
        );

        if (needsHorizontalScroll) {
          historyContent = SingleChildScrollView(
            controller: horizontalScrollController,
            scrollDirection: Axis.horizontal,
            physics: const ClampingScrollPhysics(),
            child: historyContent,
          );
        }

        return ColoredBox(
          color: backgroundColor,
          child: Stack(
            children: [
              historyContent,
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
