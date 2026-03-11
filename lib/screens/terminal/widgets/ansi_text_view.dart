import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/settings_provider.dart';
import '../../../services/terminal/ansi_parser.dart';
import '../../../services/terminal/font_calculator.dart';
import '../../../services/terminal/terminal_diff.dart';
import '../../../services/terminal/terminal_font_styles.dart';
import '../../../services/tmux/pane_navigator.dart';
import '../../../theme/design_colors.dart';

/// Key input event
class KeyInputEvent {
  /// Key data (escape sequence or character)
  final String data;

  /// Whether this is a special key
  final bool isSpecialKey;

  /// tmux-format key name (e.g., 'Enter' for Enter)
  /// Used when isSpecialKey is true
  final String? tmuxKeyName;

  const KeyInputEvent({
    required this.data,
    this.isSpecialKey = false,
    this.tmuxKeyName,
  });
}

/// Terminal operation mode
enum TerminalMode {
  /// Normal mode (key input is enabled)
  normal,

  /// Scroll mode (text selection is also available, key input is disabled)
  scroll,
}

/// ANSI text display widget
///
/// Displays capture-pane -e output with ANSI color support.
/// Uses RichText/SelectableText, eliminating xterm dependency.
class AnsiTextView extends ConsumerStatefulWidget {
  /// ANSI text to display
  final String text;

  /// Pane character width
  final int paneWidth;

  /// Pane character height
  final int paneHeight;

  /// Key input callback
  final void Function(KeyInputEvent)? onKeyInput;

  /// Background color
  final Color backgroundColor;

  /// Foreground color
  final Color foregroundColor;

  /// Operation mode
  final TerminalMode mode;

  /// Whether pinch zoom is enabled
  final bool zoomEnabled;

  /// Callback when zoom scale changes
  final void Function(double scale)? onZoomChanged;

  /// Vertical scroll controller passed from outside (optional)
  final ScrollController? verticalScrollController;

  /// Cursor X position (0-based)
  final int cursorX;

  /// Cursor Y position (0-based, relative to pane top)
  final int cursorY;

  /// Callback for arrow key input via hold+swipe
  /// direction: 'Up', 'Down', 'Left', 'Right'
  final void Function(String direction)? onArrowSwipe;

  /// Callback for pane switching via two-finger swipe
  final void Function(SwipeDirection direction)? onTwoFingerSwipe;

  /// Map indicating whether a pane exists in each direction (for visual feedback)
  final Map<SwipeDirection, bool>? navigableDirections;

  const AnsiTextView({
    super.key,
    required this.text,
    required this.paneWidth,
    required this.paneHeight,
    this.onKeyInput,
    this.backgroundColor = const Color(0xFF1E1E1E),
    this.foregroundColor = const Color(0xFFD4D4D4),
    this.mode = TerminalMode.normal,
    this.zoomEnabled = true,
    this.onZoomChanged,
    this.verticalScrollController,
    this.cursorX = 0,
    this.cursorY = 0,
    this.onArrowSwipe,
    this.onTwoFingerSwipe,
    this.navigableDirections,
  });

  @override
  ConsumerState<AnsiTextView> createState() => AnsiTextViewState();
}

class AnsiTextViewState extends ConsumerState<AnsiTextView>
    with SingleTickerProviderStateMixin {
  final FocusNode _focusNode = FocusNode();
  final ScrollController _horizontalScrollController = ScrollController();
  ScrollController? _internalVerticalScrollController;

  /// Controller for caret blinking animation
  late final AnimationController _caretBlinkController;

  /// Vertical scroll controller to use
  ScrollController get _verticalScrollController =>
      widget.verticalScrollController ?? _internalVerticalScrollController!;

  late AnsiParser _parser;

  /// Diff calculation service
  final TerminalDiff _terminalDiff = TerminalDiff();

  /// Modifier key state
  bool _ctrlPressed = false;
  bool _altPressed = false;
  bool _shiftPressed = false;

  /// State for hold+swipe gesture
  bool _isLongPressing = false;
  Offset? _longPressStartPosition;
  String? _lastSwipeDirection;
  static const double _swipeThreshold = 30.0;

  /// Two-finger gesture mode (determined by finger movement direction, locked until end)
  _TwoFingerMode _twoFingerMode = _TwoFingerMode.undetermined;
  Offset _twoFingerPanStart = Offset.zero;
  Offset _twoFingerPanDelta = Offset.zero;
  bool _isTwoFingerPanning = false;
  SwipeDirection? _twoFingerSwipeResult;
  static const double _twoFingerSwipeThreshold = 50.0;
  static const double _panGlowThreshold = 20.0;
  static const Duration _edgeFlashDuration = Duration(milliseconds: 400);

  /// Individual pointer tracking (determine zoom/pan by finger movement direction vectors)
  final Map<int, Offset> _pointerStartPositions = {};
  final Map<int, Offset> _pointerCurrentPositions = {};

  /// Current zoom scale
  double _currentScale = 1.0;

  /// Scale at the start of pinch zoom
  double _baseScale = 1.0;

  /// Cached parsed line data (for virtual scrolling)
  List<ParsedLine>? _cachedParsedLines;
  String? _cachedText;
  double? _cachedFontSize;
  String? _cachedFontFamily;

  /// Line height (using fixed height for virtual scrolling)
  double _lineHeight = 20.0;

  /// Last diff result (for adaptive polling)
  DiffResult? _lastDiffResult;

  @override
  void initState() {
    super.initState();
    // Create internally if no ScrollController is passed from outside
    if (widget.verticalScrollController == null) {
      _internalVerticalScrollController = ScrollController();
    }
    _parser = AnsiParser(
      defaultForeground: widget.foregroundColor,
      defaultBackground: widget.backgroundColor,
    );

    // Blink at 500ms intervals (1 cycle per second)
    _caretBlinkController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    )..repeat(reverse: true);
  }

  @override
  void didUpdateWidget(AnsiTextView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.foregroundColor != widget.foregroundColor ||
        oldWidget.backgroundColor != widget.backgroundColor) {
      _parser = AnsiParser(
        defaultForeground: widget.foregroundColor,
        defaultBackground: widget.backgroundColor,
      );
      // Invalidate cache since the parser changed
      _invalidateCache();
    }
  }

  /// Invalidate cache
  void _invalidateCache() {
    _cachedParsedLines = null;
    _cachedText = null;
    _cachedFontSize = null;
    _cachedFontFamily = null;
  }

  /// Get line data (using cache, for virtual scrolling)
  List<ParsedLine> _getParsedLines({
    required double fontSize,
    required String fontFamily,
  }) {
    // Execute diff calculation
    _lastDiffResult = _terminalDiff.calculateDiff(widget.text);

    // Check if cache is valid
    if (_cachedParsedLines != null &&
        _cachedText == widget.text &&
        _cachedFontSize == fontSize &&
        _cachedFontFamily == fontFamily) {
      return _cachedParsedLines!;
    }

    // Parse anew and cache
    _cachedParsedLines = _parser.parseLines(widget.text);
    _cachedText = widget.text;
    _cachedFontSize = fontSize;
    _cachedFontFamily = fontFamily;

    // Calculate line height (fontSize * lineHeight factor)
    _lineHeight = fontSize * 1.4;

    return _cachedParsedLines!;
  }

  /// Get last diff result (for reference from parent widget)
  DiffResult? get lastDiffResult => _lastDiffResult;

  /// Get recommended polling interval (for adaptive polling)
  int get recommendedPollingInterval {
    if (_lastDiffResult == null) {
      return AdaptivePollingInterval.defaultInterval;
    }
    return AdaptivePollingInterval.calculateInterval(
      _lastDiffResult!.unchangedFrames,
      _lastDiffResult!.changeRatio,
    );
  }

  @override
  void dispose() {
    _caretBlinkController.dispose();
    _focusNode.dispose();
    _horizontalScrollController.dispose();
    // Only dispose if created internally
    _internalVerticalScrollController?.dispose();
    super.dispose();
  }

  /// Reset zoom
  void resetZoom() {
    setState(() {
      _currentScale = 1.0;
      _baseScale = 1.0;
    });
    widget.onZoomChanged?.call(1.0);
  }

  // === Pointer tracking (determine zoom/pan by finger movement direction vectors) ===

  void _onPointerDown(PointerDownEvent event) {
    _pointerStartPositions[event.pointer] = event.position;
    _pointerCurrentPositions[event.pointer] = event.position;
  }

  void _onPointerMove(PointerMoveEvent event) {
    _pointerCurrentPositions[event.pointer] = event.position;
  }

  void _onPointerUpOrCancel(PointerEvent event) {
    _pointerStartPositions.remove(event.pointer);
    _pointerCurrentPositions.remove(event.pointer);
  }

  /// Determine mode from the dot product of two finger movement direction vectors
  ///
  /// - dot > 0: same direction (pan) -> pane switching
  /// - dot < 0: opposite direction (pinch) -> zoom
  /// - insufficient movement: undetermined
  _TwoFingerMode _detectModeFromFingerDirections() {
    if (_pointerCurrentPositions.length < 2) {
      return _TwoFingerMode.undetermined;
    }

    final pointers = _pointerStartPositions.keys
        .where((p) => _pointerCurrentPositions.containsKey(p))
        .take(2)
        .toList();
    if (pointers.length < 2) return _TwoFingerMode.undetermined;

    final v1 =
        _pointerCurrentPositions[pointers[0]]! -
        _pointerStartPositions[pointers[0]]!;
    final v2 =
        _pointerCurrentPositions[pointers[1]]! -
        _pointerStartPositions[pointers[1]]!;

    // Undetermined if minimum movement threshold not reached
    if (v1.distance < 15 || v2.distance < 15) {
      return _TwoFingerMode.undetermined;
    }

    final dot = v1.dx * v2.dx + v1.dy * v2.dy;
    return dot > 0 ? _TwoFingerMode.pan : _TwoFingerMode.zoom;
  }

  // === Pinch zoom + two-finger swipe handling ===

  void _onScaleStart(ScaleStartDetails details) {
    _baseScale = _currentScale;
    _twoFingerPanStart = details.focalPoint;
    _twoFingerPanDelta = Offset.zero;
    _isTwoFingerPanning = false;
    _twoFingerMode = _TwoFingerMode.undetermined;
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    // Leave single-finger drag to scrolling
    if (details.pointerCount <= 1) return;

    // Mode already determined -> process as-is
    if (_twoFingerMode == _TwoFingerMode.zoom) {
      _isTwoFingerPanning = false;
      _applyZoom(details);
      return;
    }
    if (_twoFingerMode == _TwoFingerMode.pan) {
      _isTwoFingerPanning = true;
      _twoFingerPanDelta = details.focalPoint - _twoFingerPanStart;
      setState(() {});
      return;
    }

    // Mode undetermined -> determine by finger movement direction vectors
    _twoFingerMode = _detectModeFromFingerDirections();

    switch (_twoFingerMode) {
      case _TwoFingerMode.zoom:
        _isTwoFingerPanning = false;
        _applyZoom(details);
      case _TwoFingerMode.pan:
        _isTwoFingerPanning = true;
        _twoFingerPanDelta = details.focalPoint - _twoFingerPanStart;
        setState(() {});
      case _TwoFingerMode.undetermined:
        // Cannot determine yet -> provisionally track pan delta only
        _twoFingerPanDelta = details.focalPoint - _twoFingerPanStart;
    }
  }

  void _applyZoom(ScaleUpdateDetails details) {
    final newScale = (_baseScale * details.scale).clamp(0.5, 5.0);
    if (newScale != _currentScale) {
      setState(() {
        _currentScale = newScale;
      });
      widget.onZoomChanged?.call(newScale);
    }
  }

  void _onScaleEnd(ScaleEndDetails details) {
    final wasPanning = _isTwoFingerPanning;
    _isTwoFingerPanning = false;
    _twoFingerMode = _TwoFingerMode.undetermined;
    if (!wasPanning) return;

    final direction = PaneNavigator.detectSwipeDirection(
      _twoFingerPanDelta,
      threshold: _twoFingerSwipeThreshold,
    );

    if (direction != null) {
      final canNavigate = widget.navigableDirections?[direction] ?? true;
      if (canNavigate) {
        widget.onTwoFingerSwipe?.call(direction);
        HapticFeedback.mediumImpact();
      } else {
        _showEdgeFlash(direction);
      }
    }
    _twoFingerPanDelta = Offset.zero;
    setState(() {});
  }

  void _showEdgeFlash(SwipeDirection direction) {
    HapticFeedback.heavyImpact();
    setState(() {
      _twoFingerSwipeResult = direction;
    });
    Future.delayed(_edgeFlashDuration, () {
      if (mounted) {
        setState(() {
          _twoFingerSwipeResult = null;
        });
      }
    });
  }

  // === Hold+swipe handling ===

  void _onLongPressStart(LongPressStartDetails details) {
    setState(() {
      _isLongPressing = true;
      _longPressStartPosition = details.localPosition;
      _lastSwipeDirection = null;
    });
    HapticFeedback.lightImpact();
  }

  void _onLongPressMoveUpdate(LongPressMoveUpdateDetails details) {
    if (!_isLongPressing || _longPressStartPosition == null) return;

    final delta = details.localPosition - _longPressStartPosition!;
    String? direction;

    // Detect direction that exceeds threshold
    if (delta.dx.abs() > delta.dy.abs()) {
      // Horizontal direction
      if (delta.dx > _swipeThreshold) {
        direction = 'Right';
      } else if (delta.dx < -_swipeThreshold) {
        direction = 'Left';
      }
    } else {
      // Vertical direction
      if (delta.dy > _swipeThreshold) {
        direction = 'Down';
      } else if (delta.dy < -_swipeThreshold) {
        direction = 'Up';
      }
    }

    if (direction != null) {
      setState(() {
        _lastSwipeDirection = direction;
      });
      widget.onArrowSwipe?.call(direction);
      HapticFeedback.selectionClick();
      // Reset start point for continuous swipe support
      _longPressStartPosition = details.localPosition;
      // Reset highlight after a short delay
      Future.delayed(const Duration(milliseconds: 150), () {
        if (mounted && _isLongPressing) {
          setState(() {
            _lastSwipeDirection = null;
          });
        }
      });
    }
  }

  void _onLongPressEnd(LongPressEndDetails details) {
    setState(() {
      _isLongPressing = false;
      _longPressStartPosition = null;
      _lastSwipeDirection = null;
    });
  }

  /// Swipe overlay widget
  Widget _buildSwipeOverlay() {
    return Center(
      child: AnimatedOpacity(
        opacity: _isLongPressing ? 1.0 : 0.0,
        duration: const Duration(milliseconds: 150),
        child: Container(
          width: 120,
          height: 120,
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.7),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Stack(
            children: [
              // Up arrow
              Positioned(
                top: 8,
                left: 0,
                right: 0,
                child: Icon(
                  Icons.arrow_drop_up,
                  size: 40,
                  color: _lastSwipeDirection == 'Up'
                      ? Colors.amber
                      : Colors.white.withValues(alpha: 0.6),
                ),
              ),
              // Down arrow
              Positioned(
                bottom: 8,
                left: 0,
                right: 0,
                child: Icon(
                  Icons.arrow_drop_down,
                  size: 40,
                  color: _lastSwipeDirection == 'Down'
                      ? Colors.amber
                      : Colors.white.withValues(alpha: 0.6),
                ),
              ),
              // Left arrow
              Positioned(
                left: 8,
                top: 0,
                bottom: 0,
                child: Icon(
                  Icons.arrow_left,
                  size: 40,
                  color: _lastSwipeDirection == 'Left'
                      ? Colors.amber
                      : Colors.white.withValues(alpha: 0.6),
                ),
              ),
              // Right arrow
              Positioned(
                right: 8,
                top: 0,
                bottom: 0,
                child: Icon(
                  Icons.arrow_right,
                  size: 40,
                  color: _lastSwipeDirection == 'Right'
                      ? Colors.amber
                      : Colors.white.withValues(alpha: 0.6),
                ),
              ),
              // Center dot
              Center(
                child: Container(
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.4),
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Visual feedback overlay during two-finger swipe
  Widget _buildTwoFingerSwipeOverlay() {
    // Flash display when reaching the edge
    if (_twoFingerSwipeResult != null) {
      return _buildEdgeFlash(_twoFingerSwipeResult!);
    }

    // Edge glow display during panning
    if (_isTwoFingerPanning) {
      return _buildPanGlow();
    }

    return const SizedBox.shrink();
  }

  /// Red-tinted flash when reaching the edge
  Widget _buildEdgeFlash(SwipeDirection direction) {
    final alignment = switch (direction) {
      SwipeDirection.left => Alignment.centerLeft,
      SwipeDirection.right => Alignment.centerRight,
      SwipeDirection.up => Alignment.topCenter,
      SwipeDirection.down => Alignment.bottomCenter,
    };

    final isHorizontal =
        direction == SwipeDirection.left || direction == SwipeDirection.right;

    return Positioned.fill(
      child: IgnorePointer(
        child: Align(
          alignment: alignment,
          child: Container(
            width: isHorizontal ? 40 : double.infinity,
            height: isHorizontal ? double.infinity : 40,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: isHorizontal
                    ? (direction == SwipeDirection.left
                        ? Alignment.centerRight
                        : Alignment.centerLeft)
                    : (direction == SwipeDirection.up
                        ? Alignment.bottomCenter
                        : Alignment.topCenter),
                end: isHorizontal
                    ? (direction == SwipeDirection.left
                        ? Alignment.centerLeft
                        : Alignment.centerRight)
                    : (direction == SwipeDirection.up
                        ? Alignment.topCenter
                        : Alignment.bottomCenter),
                colors: [
                  Colors.transparent,
                  Colors.red.withValues(alpha: 0.4),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Directional glow during panning
  Widget _buildPanGlow() {
    final dx = _twoFingerPanDelta.dx;
    final dy = _twoFingerPanDelta.dy;

    // Do not display if movement is too small
    if (dx.abs() < _panGlowThreshold && dy.abs() < _panGlowThreshold) {
      return const SizedBox.shrink();
    }

    SwipeDirection? direction;
    if (dx.abs() > dy.abs()) {
      direction = dx > 0 ? SwipeDirection.right : SwipeDirection.left;
    } else {
      direction = dy > 0 ? SwipeDirection.down : SwipeDirection.up;
    }

    final canNavigate = widget.navigableDirections?[direction] ?? true;
    final color = canNavigate
        ? DesignColors.primary.withValues(alpha: 0.2)
        : Colors.red.withValues(alpha: 0.15);

    final alignment = switch (direction) {
      SwipeDirection.left => Alignment.centerLeft,
      SwipeDirection.right => Alignment.centerRight,
      SwipeDirection.up => Alignment.topCenter,
      SwipeDirection.down => Alignment.bottomCenter,
    };

    final isHorizontal =
        direction == SwipeDirection.left || direction == SwipeDirection.right;

    return Positioned.fill(
      child: IgnorePointer(
        child: Align(
          alignment: alignment,
          child: Container(
            width: isHorizontal ? 30 : double.infinity,
            height: isHorizontal ? double.infinity : 30,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: isHorizontal
                    ? (direction == SwipeDirection.left
                        ? Alignment.centerRight
                        : Alignment.centerLeft)
                    : (direction == SwipeDirection.up
                        ? Alignment.bottomCenter
                        : Alignment.topCenter),
                end: isHorizontal
                    ? (direction == SwipeDirection.left
                        ? Alignment.centerLeft
                        : Alignment.centerRight)
                    : (direction == SwipeDirection.up
                        ? Alignment.topCenter
                        : Alignment.bottomCenter),
                colors: [
                  Colors.transparent,
                  color,
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Get the current zoom scale
  double get currentScale => _currentScale;

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);
    final isScrollMode = widget.mode == TerminalMode.scroll;

    return LayoutBuilder(
      builder: (context, constraints) {
        // Determine font size
        late final double fontSize;
        late final bool needsHorizontalScroll;

        if (settings.autoFitEnabled) {
          // Auto-fit: calculate to match screen width
          final calcResult = FontCalculator.calculate(
            screenWidth: constraints.maxWidth,
            paneCharWidth: widget.paneWidth,
            fontFamily: settings.fontFamily,
            minFontSize: settings.minFontSize,
          );
          fontSize = calcResult.fontSize;
          needsHorizontalScroll = calcResult.needsScroll;
        } else {
          // Manual setting: use settings.fontSize
          fontSize = settings.fontSize;
          // Determine if horizontal scrolling is needed
          final terminalWidth = FontCalculator.calculateTerminalWidth(
            paneCharWidth: widget.paneWidth,
            fontSize: fontSize,
            fontFamily: settings.fontFamily,
          );
          needsHorizontalScroll = terminalWidth > constraints.maxWidth;
        }

        // Calculate terminal width
        final terminalWidth = FontCalculator.calculateTerminalWidth(
          paneCharWidth: widget.paneWidth,
          fontSize: fontSize,
          fontFamily: settings.fontFamily,
        );

        // Get line data (using cache, for virtual scrolling)
        final parsedLines = _getParsedLines(
          fontSize: fontSize,
          fontFamily: settings.fontFamily,
        );

        // ListView.builder with virtual scrolling support
        Widget listWidget = ListView.builder(
          controller: _verticalScrollController,
          padding: EdgeInsets.zero, // Explicitly set padding to zero
          physics: const ClampingScrollPhysics(),
          itemCount: parsedLines.length,
          // Use fixed line height to speed up scroll calculations
          itemExtent: _lineHeight,
          // Automatically add RepaintBoundary
          addRepaintBoundaries: true,
          itemBuilder: (context, index) {
            final line = parsedLines[index];
            final textSpan = _parser.lineToTextSpan(
              line,
              fontSize: fontSize,
              fontFamily: settings.fontFamily,
            );

            // Text widget for each line
            Widget lineWidget = Text.rich(
              textSpan,
              style: TerminalFontStyles.getTextStyle(
                settings.fontFamily,
                fontSize: fontSize,
                height: 1.4,
                color: widget.foregroundColor,
              ),
              textScaler: TextScaler.noScaling,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.visible,
            );

            // Cursor rendering
            // Calculate the line index of the cursor position
            // parsedLines contains history + visible area.
            // The last paneHeight lines are the visible area.
            final int cursorLineIndex;
            if (parsedLines.length >= widget.paneHeight) {
              cursorLineIndex = parsedLines.length - widget.paneHeight + widget.cursorY;
            } else {
              // If line count is less than paneHeight, simply use cursorY (e.g., initial state)
              cursorLineIndex = widget.cursorY;
            }

            // If the current line matches the cursor position, overlay the cursor using Stack
            if (index == cursorLineIndex &&
                widget.mode == TerminalMode.normal &&
                settings.showTerminalCursor) {
              // Use TextPainter.getOffsetForCaret to get the exact cursor position calculated by the rendering engine
              double cursorLeft;
              double charWidth;

              // Create TextPainter using the full line text and styles
              final textSpanFull = _parser.lineToTextSpan(
                line,
                fontSize: fontSize,
                fontFamily: settings.fontFamily,
              );

              final painter = TextPainter(
                text: textSpanFull,
                textDirection: TextDirection.ltr,
                textScaler: TextScaler.noScaling,
              )..layout();

              // Get the plain text of the line
              final lineText = line.segments.map((s) => s.text).join();
              final lineTextLength = lineText.length;

              // Convert column position to character offset considering full-width characters
              // tmux cursor_x is a column position (full-width=2), but
              // TextPosition expects a character offset (full-width=1)
              final lineDisplayWidth = FontCalculator.getTextDisplayWidth(lineText);
              final charOffset = FontCalculator.columnToCharOffset(lineText, widget.cursorX);

              if (widget.cursorX <= lineDisplayWidth) {
                 // If cursor is within the line, get position via getOffsetForCaret
                 final offset = painter.getOffsetForCaret(
                   TextPosition(offset: charOffset),
                   Rect.zero,
                 );
                 cursorLeft = offset.dx;

                 // Get cursor width from current character position (width to next character)
                 // Use standard width at line end
                 if (charOffset < lineTextLength) {
                    final nextOffset = painter.getOffsetForCaret(
                      TextPosition(offset: charOffset + 1),
                      Rect.zero,
                    );
                    charWidth = nextOffset.dx - offset.dx;
                 } else {
                    charWidth = FontCalculator.measureCharWidth(settings.fontFamily, fontSize);
                 }
              } else {
                 // Cursor is beyond end of line (empty line or spaces past line end)
                 // Get end-of-line position and add the excess
                 cursorLeft = painter.width;
                 charWidth = FontCalculator.measureCharWidth(settings.fontFamily, fontSize);
                 cursorLeft += (widget.cursorX - lineDisplayWidth) * charWidth;
              }

              lineWidget = Stack(
                clipBehavior: Clip.none,
                children: [
                  lineWidget,
                  AnimatedBuilder(
                    animation: _caretBlinkController,
                    builder: (context, child) {
                      // Match caret height to character size (excluding line spacing)
                      final caretHeight = fontSize;
                      // Vertically center within the line
                      final caretTop = (_lineHeight - caretHeight) / 2;

                      return Positioned(
                        left: cursorLeft,
                        top: caretTop,
                        width: 2,
                        height: caretHeight,
                        child: Opacity(
                          opacity: _caretBlinkController.value, // Fade in/out
                          child: Container(
                            color: DesignColors.primary,
                          ),
                        ),
                      );
                    },
                  ),
                ],
              );
            }

            // Fixed-width container (for horizontal scrolling)
            if (needsHorizontalScroll) {
              lineWidget = SizedBox(
                width: terminalWidth,
                child: lineWidget,
              );
            }

            return lineWidget;
          },
        );

        // If horizontal scrolling is needed
        if (needsHorizontalScroll) {
          listWidget = SingleChildScrollView(
            controller: _horizontalScrollController,
            scrollDirection: Axis.horizontal,
            physics: const ClampingScrollPhysics(),
            child: SizedBox(
              width: terminalWidth,
              height: constraints.maxHeight,
              child: listWidget,
            ),
          );
        }

        // Pinch zoom + two-finger swipe
        if (widget.zoomEnabled) {
          // Use RawGestureDetector to force-win gesture arena on two-finger detection
          listWidget = RawGestureDetector(
            gestures: <Type, GestureRecognizerFactory>{
              _EagerScaleGestureRecognizer:
                  GestureRecognizerFactoryWithHandlers<
                    _EagerScaleGestureRecognizer
                  >(
                    () => _EagerScaleGestureRecognizer(),
                    (_EagerScaleGestureRecognizer instance) {
                      instance
                        ..onStart = _onScaleStart
                        ..onUpdate = _onScaleUpdate
                        ..onEnd = _onScaleEnd;
                    },
                  ),
            },
            child: Transform.scale(
              scale: _currentScale,
              alignment: Alignment.topLeft,
              child: listWidget,
            ),
          );
          // Track individual pointers with Listener (does not participate in gesture arena)
          // Used to determine zoom/pan by dot product of finger movement direction vectors
          listWidget = Listener(
            onPointerDown: _onPointerDown,
            onPointerMove: _onPointerMove,
            onPointerUp: _onPointerUpOrCancel,
            onPointerCancel: _onPointerUpOrCancel,
            child: listWidget,
          );
        }

        // Enable text selection in scroll mode
        if (isScrollMode) {
          return Container(
            color: widget.backgroundColor,
            child: SelectionArea(
              child: listWidget,
            ),
          );
        }

        // Normal mode: handle keyboard input
        // Support arrow key input via hold+swipe
        return Focus(
          focusNode: _focusNode,
          autofocus: true,
          onKeyEvent: _handleKeyEvent,
          child: GestureDetector(
            onTap: () => _focusNode.requestFocus(),
            onLongPressStart: _onLongPressStart,
            onLongPressMoveUpdate: _onLongPressMoveUpdate,
            onLongPressEnd: _onLongPressEnd,
            child: Stack(
              children: [
                Container(
                  color: widget.backgroundColor,
                  child: listWidget,
                ),
                // Hold+swipe overlay
                if (_isLongPressing) _buildSwipeOverlay(),
                // Two-finger swipe overlay
                if (_isTwoFingerPanning || _twoFingerSwipeResult != null)
                  _buildTwoFingerSwipeOverlay(),
              ],
            ),
          ),
        );
      },
    );
  }

  /// Handle key events
  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (widget.onKeyInput == null) return KeyEventResult.ignored;

    if (event is KeyDownEvent || event is KeyRepeatEvent) {
      final key = event.logicalKey;

      // Update modifier key state
      if (key == LogicalKeyboardKey.controlLeft ||
          key == LogicalKeyboardKey.controlRight) {
        _ctrlPressed = true;
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.altLeft ||
          key == LogicalKeyboardKey.altRight) {
        _altPressed = true;
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.shiftLeft ||
          key == LogicalKeyboardKey.shiftRight) {
        _shiftPressed = true;
        return KeyEventResult.handled;
      }

      // Handle special keys
      String? data;
      bool isSpecialKey = false;
      String? tmuxKeyName;

      if (key == LogicalKeyboardKey.escape) {
        data = '\x1b';
        isSpecialKey = true;
        tmuxKeyName = 'Escape';
      } else if (key == LogicalKeyboardKey.enter) {
        // Send with different key name for Shift+Enter
        if (_shiftPressed) {
          data = '\x1b[27;2;13~'; // xterm extension: Shift+Enter
          isSpecialKey = true;
          tmuxKeyName = 'S-Enter';
          _shiftPressed = false;
        } else {
          data = '\r';
          isSpecialKey = true;
          tmuxKeyName = 'Enter';
        }
      } else if (key == LogicalKeyboardKey.backspace) {
        data = '\x7f';
        isSpecialKey = true;
        tmuxKeyName = 'BSpace';
      } else if (key == LogicalKeyboardKey.delete) {
        data = _getParamSequence(3, '~');
        isSpecialKey = true;
        tmuxKeyName = _getModifiedTmuxKey('DC');
      } else if (key == LogicalKeyboardKey.tab) {
        if (_shiftPressed) {
          data = '\x1b[Z';
          tmuxKeyName = 'BTab';
          _shiftPressed = false;
        } else {
          data = '\t';
          tmuxKeyName = 'Tab';
        }
        isSpecialKey = true;
      } else if (key == LogicalKeyboardKey.arrowUp) {
        data = _getArrowSequence('A');
        isSpecialKey = true;
        tmuxKeyName = _getArrowTmuxKey('Up');
      } else if (key == LogicalKeyboardKey.arrowDown) {
        data = _getArrowSequence('B');
        isSpecialKey = true;
        tmuxKeyName = _getArrowTmuxKey('Down');
      } else if (key == LogicalKeyboardKey.arrowRight) {
        data = _getArrowSequence('C');
        isSpecialKey = true;
        tmuxKeyName = _getArrowTmuxKey('Right');
      } else if (key == LogicalKeyboardKey.arrowLeft) {
        data = _getArrowSequence('D');
        isSpecialKey = true;
        tmuxKeyName = _getArrowTmuxKey('Left');
      } else if (key == LogicalKeyboardKey.home) {
        data = _getFinalCharSequence('H');
        isSpecialKey = true;
        tmuxKeyName = _getModifiedTmuxKey('Home');
      } else if (key == LogicalKeyboardKey.end) {
        data = _getFinalCharSequence('F');
        isSpecialKey = true;
        tmuxKeyName = _getModifiedTmuxKey('End');
      } else if (key == LogicalKeyboardKey.pageUp) {
        data = _getParamSequence(5, '~');
        isSpecialKey = true;
        tmuxKeyName = _getModifiedTmuxKey('PPage');
      } else if (key == LogicalKeyboardKey.pageDown) {
        data = _getParamSequence(6, '~');
        isSpecialKey = true;
        tmuxKeyName = _getModifiedTmuxKey('NPage');
      } else if (key == LogicalKeyboardKey.f1) {
        data = _getFKeySequence('P');
        isSpecialKey = true;
        tmuxKeyName = _getModifiedTmuxKey('F1');
      } else if (key == LogicalKeyboardKey.f2) {
        data = _getFKeySequence('Q');
        isSpecialKey = true;
        tmuxKeyName = _getModifiedTmuxKey('F2');
      } else if (key == LogicalKeyboardKey.f3) {
        data = _getFKeySequence('R');
        isSpecialKey = true;
        tmuxKeyName = _getModifiedTmuxKey('F3');
      } else if (key == LogicalKeyboardKey.f4) {
        data = _getFKeySequence('S');
        isSpecialKey = true;
        tmuxKeyName = _getModifiedTmuxKey('F4');
      } else if (key == LogicalKeyboardKey.f5) {
        data = _getParamSequence(15, '~');
        isSpecialKey = true;
        tmuxKeyName = _getModifiedTmuxKey('F5');
      } else if (key == LogicalKeyboardKey.f6) {
        data = _getParamSequence(17, '~');
        isSpecialKey = true;
        tmuxKeyName = _getModifiedTmuxKey('F6');
      } else if (key == LogicalKeyboardKey.f7) {
        data = _getParamSequence(18, '~');
        isSpecialKey = true;
        tmuxKeyName = _getModifiedTmuxKey('F7');
      } else if (key == LogicalKeyboardKey.f8) {
        data = _getParamSequence(19, '~');
        isSpecialKey = true;
        tmuxKeyName = _getModifiedTmuxKey('F8');
      } else if (key == LogicalKeyboardKey.f9) {
        data = _getParamSequence(20, '~');
        isSpecialKey = true;
        tmuxKeyName = _getModifiedTmuxKey('F9');
      } else if (key == LogicalKeyboardKey.f10) {
        data = _getParamSequence(21, '~');
        isSpecialKey = true;
        tmuxKeyName = _getModifiedTmuxKey('F10');
      } else if (key == LogicalKeyboardKey.f11) {
        data = _getParamSequence(23, '~');
        isSpecialKey = true;
        tmuxKeyName = _getModifiedTmuxKey('F11');
      } else if (key == LogicalKeyboardKey.f12) {
        data = _getParamSequence(24, '~');
        isSpecialKey = true;
        tmuxKeyName = _getModifiedTmuxKey('F12');
      } else if (event.character != null && event.character!.isNotEmpty) {
        // Normal character
        data = event.character!;

        // Handle Ctrl+character
        if (_ctrlPressed && data.length == 1) {
          final code = data.codeUnitAt(0);
          if ((code >= 0x61 && code <= 0x7a) ||
              (code >= 0x41 && code <= 0x5a)) {
            data = String.fromCharCode(code & 0x1f);
          }
        }

        // Handle Alt+character
        if (_altPressed) {
          data = '\x1b$data';
        }
      }

      if (data != null) {
        widget.onKeyInput!(KeyInputEvent(
          data: data,
          isSpecialKey: isSpecialKey,
          tmuxKeyName: tmuxKeyName,
        ));
        return KeyEventResult.handled;
      }
    } else if (event is KeyUpEvent) {
      final key = event.logicalKey;

      // Release modifier keys
      if (key == LogicalKeyboardKey.controlLeft ||
          key == LogicalKeyboardKey.controlRight) {
        _ctrlPressed = false;
      } else if (key == LogicalKeyboardKey.altLeft ||
          key == LogicalKeyboardKey.altRight) {
        _altPressed = false;
      } else if (key == LogicalKeyboardKey.shiftLeft ||
          key == LogicalKeyboardKey.shiftRight) {
        _shiftPressed = false;
      }
    }

    return KeyEventResult.ignored;
  }

  /// Get the escape sequence for arrow keys
  String _getArrowSequence(String code) {
    if (_shiftPressed) {
      return '\x1b[1;2$code';
    } else if (_ctrlPressed) {
      return '\x1b[1;5$code';
    } else if (_altPressed) {
      return '\x1b[1;3$code';
    }
    return '\x1b[$code';
  }

  /// Get the tmux-format key name for arrow keys
  String _getArrowTmuxKey(String direction) {
    if (_shiftPressed) {
      return 'S-$direction';
    } else if (_ctrlPressed) {
      return 'C-$direction';
    } else if (_altPressed) {
      return 'M-$direction';
    }
    return direction;
  }

  /// Get tmux key name with modifier (generic: Home/End/PPage/NPage/DC, etc.)
  /// Consumes (resets) the modifier flag
  String _getModifiedTmuxKey(String baseKey) {
    if (_shiftPressed) {
      _shiftPressed = false;
      return 'S-$baseKey';
    } else if (_ctrlPressed) {
      _ctrlPressed = false;
      return 'C-$baseKey';
    } else if (_altPressed) {
      _altPressed = false;
      return 'M-$baseKey';
    }
    return baseKey;
  }

  /// CSI sequence with modifier: final character type (Home: \x1b[H, End: \x1b[F)
  /// With modifier: \x1b[1;{mod}{finalChar}
  String _getFinalCharSequence(String finalChar) {
    final mod = _shiftPressed ? 2 : _ctrlPressed ? 5 : _altPressed ? 3 : 0;
    if (mod == 0) return '\x1b[$finalChar';
    return '\x1b[1;$mod$finalChar';
  }

  /// CSI sequence with modifier: parameter type (PageUp: \x1b[5~, Delete: \x1b[3~)
  /// With modifier: \x1b[{param};{mod}~
  String _getParamSequence(int param, String suffix) {
    final mod = _shiftPressed ? 2 : _ctrlPressed ? 5 : _altPressed ? 3 : 0;
    if (mod == 0) return '\x1b[$param$suffix';
    return '\x1b[$param;$mod$suffix';
  }

  /// Sequence for F1-F4 (SS3 format, converted to CSI format if modifier is present)
  /// F1=P, F2=Q, F3=R, F4=S
  /// Without modifier: \x1bO{code}, with modifier: \x1b[1;{mod}{code}
  String _getFKeySequence(String code) {
    final mod = _shiftPressed ? 2 : _ctrlPressed ? 5 : _altPressed ? 3 : 0;
    if (mod == 0) return '\x1bO$code';
    return '\x1b[1;$mod$code';
  }

  // === Modifier key toggles (for external control) ===

  void toggleCtrl() {
    setState(() {
      _ctrlPressed = !_ctrlPressed;
    });
    HapticFeedback.selectionClick();
  }

  void toggleAlt() {
    setState(() {
      _altPressed = !_altPressed;
    });
    HapticFeedback.selectionClick();
  }

  void toggleShift() {
    setState(() {
      _shiftPressed = !_shiftPressed;
    });
    HapticFeedback.selectionClick();
  }

  bool get ctrlPressed => _ctrlPressed;
  bool get altPressed => _altPressed;
  bool get shiftPressed => _shiftPressed;

  void resetModifiers() {
    setState(() {
      _ctrlPressed = false;
      _altPressed = false;
      _shiftPressed = false;
    });
  }

  // === Scroll control ===

  /// Scroll to the bottom
  void scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_verticalScrollController.hasClients) {
        _verticalScrollController.animateTo(
          _verticalScrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  /// Scroll to the top
  void scrollToTop() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_verticalScrollController.hasClients) {
        _verticalScrollController.animateTo(
          0,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  /// Scroll to cursor position
  void scrollToCaret() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!_verticalScrollController.hasClients) return;

      final parsedLines = _cachedParsedLines;
      if (parsedLines == null || parsedLines.isEmpty) return;

      // Calculate cursor line index (same logic as in build)
      final int cursorLineIndex;
      if (parsedLines.length >= widget.paneHeight) {
        cursorLineIndex =
            parsedLines.length - widget.paneHeight + widget.cursorY;
      } else {
        cursorLineIndex = widget.cursorY;
      }

      // Scroll offset of the cursor line
      final targetOffset = cursorLineIndex * _lineHeight;

      // Adjust so the cursor line is near the center, considering viewport height
      final viewportHeight =
          _verticalScrollController.position.viewportDimension;
      final centeredOffset =
          targetOffset - (viewportHeight / 2) + (_lineHeight / 2);

      // Clamp to valid range
      final maxExtent = _verticalScrollController.position.maxScrollExtent;
      final clampedOffset = centeredOffset.clamp(0.0, maxExtent);

      _verticalScrollController.animateTo(
        clampedOffset,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    });
  }
}

/// Two-finger gesture mode (determined at gesture start, locked until end)
enum _TwoFingerMode { undetermined, pan, zoom }

/// ScaleGestureRecognizer that forcefully wins the gesture arena when two or more fingers are detected.
///
/// The standard ScaleGestureRecognizer loses the arena to the internal
/// SingleChildScrollView's HorizontalDragGestureRecognizer.
/// This class overrides rejectGesture() with acceptGesture() when two fingers
/// are detected, forcefully winning the arena. For single-finger gestures,
/// it defers to super.rejectGesture() as usual, so single-finger scrolling is unaffected.
class _EagerScaleGestureRecognizer extends ScaleGestureRecognizer {
  int _pointerCount = 0;

  @override
  void addAllowedPointer(PointerDownEvent event) {
    super.addAllowedPointer(event);
    _pointerCount++;
  }

  @override
  void handleEvent(PointerEvent event) {
    super.handleEvent(event);
    if (event is PointerUpEvent || event is PointerCancelEvent) {
      _pointerCount = (_pointerCount - 1).clamp(0, 99);
    }
  }

  @override
  void rejectGesture(int pointer) {
    if (_pointerCount >= 2) {
      acceptGesture(pointer);
    } else {
      super.rejectGesture(pointer);
    }
  }

  @override
  void dispose() {
    _pointerCount = 0;
    super.dispose();
  }
}
