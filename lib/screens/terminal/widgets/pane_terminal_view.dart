import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:xterm/xterm.dart';

import '../../../providers/settings_provider.dart';
import '../../../services/terminal/font_calculator.dart';
import '../../../services/tmux/pane_navigator.dart';
import '../../../theme/design_colors.dart';

/// Terminal interaction mode.
enum PaneTerminalMode {
  normal,
  select,
}

/// xterm-backed pane renderer that preserves the app's single-pane UX.
class PaneTerminalView extends ConsumerStatefulWidget {
  final Terminal terminal;
  final TerminalController terminalController;
  final int paneWidth;
  final int paneHeight;
  final Color backgroundColor;
  final Color foregroundColor;
  final PaneTerminalMode mode;
  final bool zoomEnabled;
  final bool showCursor;
  final void Function(double scale)? onZoomChanged;
  final ScrollController? verticalScrollController;
  final void Function(SwipeDirection direction)? onTwoFingerSwipe;
  final Map<SwipeDirection, bool>? navigableDirections;

  const PaneTerminalView({
    super.key,
    required this.terminal,
    required this.terminalController,
    required this.paneWidth,
    required this.paneHeight,
    required this.backgroundColor,
    required this.foregroundColor,
    this.mode = PaneTerminalMode.normal,
    this.zoomEnabled = true,
    this.showCursor = true,
    this.onZoomChanged,
    this.verticalScrollController,
    this.onTwoFingerSwipe,
    this.navigableDirections,
  });

  @override
  ConsumerState<PaneTerminalView> createState() => PaneTerminalViewState();
}

class PaneTerminalViewState extends ConsumerState<PaneTerminalView> {
  final ScrollController _horizontalScrollController = ScrollController();
  ScrollController? _internalVerticalScrollController;

  ScrollController get _verticalScrollController =>
      widget.verticalScrollController ?? _internalVerticalScrollController!;

  bool _hasSelection = false;
  double _currentScale = 1.0;
  double _baseScale = 1.0;

  _TwoFingerMode _twoFingerMode = _TwoFingerMode.undetermined;
  Offset _twoFingerPanStart = Offset.zero;
  Offset _twoFingerPanDelta = Offset.zero;
  bool _isTwoFingerPanning = false;
  SwipeDirection? _twoFingerSwipeResult;

  final Map<int, Offset> _pointerStartPositions = {};
  final Map<int, Offset> _pointerCurrentPositions = {};

  static const double _twoFingerSwipeThreshold = 50.0;
  static const double _panGlowThreshold = 20.0;
  static const Duration _edgeFlashDuration = Duration(milliseconds: 400);

  @override
  void initState() {
    super.initState();
    if (widget.verticalScrollController == null) {
      _internalVerticalScrollController = ScrollController();
    }
    widget.terminalController.addListener(_handleSelectionChanged);
  }

  @override
  void didUpdateWidget(covariant PaneTerminalView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.verticalScrollController != widget.verticalScrollController) {
      if (oldWidget.verticalScrollController == null) {
        _internalVerticalScrollController?.dispose();
      }
      if (widget.verticalScrollController == null) {
        _internalVerticalScrollController = ScrollController();
      } else {
        _internalVerticalScrollController = null;
      }
    }
    if (oldWidget.terminalController != widget.terminalController) {
      oldWidget.terminalController.removeListener(_handleSelectionChanged);
      widget.terminalController.addListener(_handleSelectionChanged);
      _handleSelectionChanged();
    }
  }

  @override
  void dispose() {
    widget.terminalController.removeListener(_handleSelectionChanged);
    _horizontalScrollController.dispose();
    _internalVerticalScrollController?.dispose();
    super.dispose();
  }

  void resetZoom() {
    if (_currentScale == 1.0) {
      return;
    }
    setState(() {
      _currentScale = 1.0;
      _baseScale = 1.0;
    });
    widget.onZoomChanged?.call(1.0);
  }

  void scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_verticalScrollController.hasClients) {
        return;
      }
      _verticalScrollController.jumpTo(
        _verticalScrollController.position.maxScrollExtent,
      );
    });
  }

  Future<void> copySelection() async {
    final selection = widget.terminalController.selection;
    if (selection == null) {
      return;
    }
    final text = widget.terminal.buffer.getText(selection);
    await Clipboard.setData(ClipboardData(text: text));
    widget.terminalController.clearSelection();
  }

  void _handleSelectionChanged() {
    final hasSelection = widget.terminalController.selection != null;
    if (_hasSelection != hasSelection && mounted) {
      setState(() {
        _hasSelection = hasSelection;
      });
    }
  }

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

  _TwoFingerMode _detectModeFromFingerDirections() {
    if (_pointerCurrentPositions.length < 2) {
      return _TwoFingerMode.undetermined;
    }

    final pointers = _pointerStartPositions.keys
        .where(_pointerCurrentPositions.containsKey)
        .take(2)
        .toList();
    if (pointers.length < 2) {
      return _TwoFingerMode.undetermined;
    }

    final v1 =
        _pointerCurrentPositions[pointers[0]]! -
        _pointerStartPositions[pointers[0]]!;
    final v2 =
        _pointerCurrentPositions[pointers[1]]! -
        _pointerStartPositions[pointers[1]]!;

    if (v1.distance < 15 || v2.distance < 15) {
      return _TwoFingerMode.undetermined;
    }

    final dot = v1.dx * v2.dx + v1.dy * v2.dy;
    return dot > 0 ? _TwoFingerMode.pan : _TwoFingerMode.zoom;
  }

  void _onScaleStart(ScaleStartDetails details) {
    _baseScale = _currentScale;
    _twoFingerPanStart = details.focalPoint;
    _twoFingerPanDelta = Offset.zero;
    _isTwoFingerPanning = false;
    _twoFingerMode = _TwoFingerMode.undetermined;
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    if (details.pointerCount <= 1) {
      return;
    }

    if (_twoFingerMode == _TwoFingerMode.zoom) {
      _applyZoom(details);
      return;
    }

    if (_twoFingerMode == _TwoFingerMode.pan) {
      _isTwoFingerPanning = true;
      _twoFingerPanDelta = details.focalPoint - _twoFingerPanStart;
      setState(() {});
      return;
    }

    _twoFingerMode = _detectModeFromFingerDirections();
    switch (_twoFingerMode) {
      case _TwoFingerMode.zoom:
        _applyZoom(details);
        return;
      case _TwoFingerMode.pan:
        _isTwoFingerPanning = true;
        _twoFingerPanDelta = details.focalPoint - _twoFingerPanStart;
        setState(() {});
        return;
      case _TwoFingerMode.undetermined:
        _twoFingerPanDelta = details.focalPoint - _twoFingerPanStart;
        return;
    }
  }

  void _applyZoom(ScaleUpdateDetails details) {
    final newScale = (_baseScale * details.scale).clamp(0.5, 5.0);
    if (newScale == _currentScale) {
      return;
    }

    setState(() {
      _currentScale = newScale;
    });
    widget.onZoomChanged?.call(newScale);
  }

  void _onScaleEnd(ScaleEndDetails details) {
    final wasPanning = _isTwoFingerPanning;
    _isTwoFingerPanning = false;
    _twoFingerMode = _TwoFingerMode.undetermined;
    if (!wasPanning) {
      return;
    }

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
      if (!mounted) {
        return;
      }
      setState(() {
        _twoFingerSwipeResult = null;
      });
    });
  }

  TerminalTheme _buildTheme() {
    final base = TerminalThemes.defaultTheme;
    final cursorColor = widget.showCursor
        ? DesignColors.primary
        : Colors.transparent;

    return TerminalTheme(
      cursor: cursorColor,
      selection: base.selection,
      foreground: widget.foregroundColor,
      background: widget.backgroundColor,
      black: base.black,
      white: base.white,
      red: base.red,
      green: base.green,
      yellow: base.yellow,
      blue: base.blue,
      magenta: base.magenta,
      cyan: base.cyan,
      brightBlack: base.brightBlack,
      brightRed: base.brightRed,
      brightGreen: base.brightGreen,
      brightYellow: base.brightYellow,
      brightBlue: base.brightBlue,
      brightMagenta: base.brightMagenta,
      brightCyan: base.brightCyan,
      brightWhite: base.brightWhite,
      searchHitBackground: base.searchHitBackground,
      searchHitBackgroundCurrent: base.searchHitBackgroundCurrent,
      searchHitForeground: base.searchHitForeground,
    );
  }

  Widget _buildSelectionActions() {
    if (widget.mode != PaneTerminalMode.select || !_hasSelection) {
      return const SizedBox.shrink();
    }

    return Positioned(
      right: 12,
      bottom: 12,
      child: Material(
        color: Colors.transparent,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildOverlayButton(
              icon: Icons.copy,
              label: 'Copy',
              onTap: () {
                unawaited(copySelection());
              },
            ),
            const SizedBox(width: 8),
            _buildOverlayButton(
              icon: Icons.clear,
              label: 'Clear',
              onTap: widget.terminalController.clearSelection,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildOverlayButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Ink(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.7),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.12),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: Colors.white),
            const SizedBox(width: 6),
            Text(
              label,
              style: GoogleFonts.jetBrainsMono(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: Colors.white,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTwoFingerSwipeOverlay() {
    if (_twoFingerSwipeResult != null) {
      return _buildEdgeFlash(_twoFingerSwipeResult!);
    }

    if (_isTwoFingerPanning) {
      return _buildPanGlow();
    }

    return const SizedBox.shrink();
  }

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

  Widget _buildPanGlow() {
    final dx = _twoFingerPanDelta.dx;
    final dy = _twoFingerPanDelta.dy;

    if (dx.abs() < _panGlowThreshold && dy.abs() < _panGlowThreshold) {
      return const SizedBox.shrink();
    }

    SwipeDirection direction;
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

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(settingsProvider);

    return LayoutBuilder(
      builder: (context, constraints) {
        final baseFontSize = settings.autoFitEnabled
            ? FontCalculator.calculate(
                screenWidth: constraints.maxWidth,
                paneCharWidth: widget.paneWidth,
                fontFamily: settings.fontFamily,
                minFontSize: settings.minFontSize,
              ).fontSize
            : settings.fontSize;

        final fontSize = baseFontSize * _currentScale;
        final terminalWidth = FontCalculator.calculateTerminalWidth(
          paneCharWidth: widget.paneWidth,
          fontSize: fontSize,
          fontFamily: settings.fontFamily,
        );
        final needsHorizontalScroll = terminalWidth > constraints.maxWidth;

        Widget terminalWidget = SizedBox(
          width: needsHorizontalScroll ? terminalWidth : constraints.maxWidth,
          height: constraints.maxHeight,
          child: TerminalView(
            widget.terminal,
            controller: widget.terminalController,
            scrollController: _verticalScrollController,
            autoResize: false,
            autofocus: true,
            readOnly: widget.mode == PaneTerminalMode.select,
            simulateScroll: widget.mode == PaneTerminalMode.normal,
            theme: _buildTheme(),
            textStyle: TerminalStyle(
              fontSize: fontSize,
              height: 1.4,
              fontFamily: settings.fontFamily,
            ),
          ),
        );

        if (needsHorizontalScroll) {
          terminalWidget = SingleChildScrollView(
            controller: _horizontalScrollController,
            scrollDirection: Axis.horizontal,
            physics: const ClampingScrollPhysics(),
            child: terminalWidget,
          );
        }

        if (widget.zoomEnabled) {
          terminalWidget = RawGestureDetector(
            gestures: <Type, GestureRecognizerFactory>{
              ScaleGestureRecognizer:
                  GestureRecognizerFactoryWithHandlers<
                    ScaleGestureRecognizer
                  >(
                    ScaleGestureRecognizer.new,
                    (ScaleGestureRecognizer instance) {
                      instance
                        ..onStart = _onScaleStart
                        ..onUpdate = _onScaleUpdate
                        ..onEnd = _onScaleEnd;
                    },
                  ),
            },
            child: terminalWidget,
          );
          terminalWidget = Listener(
            onPointerDown: _onPointerDown,
            onPointerMove: _onPointerMove,
            onPointerUp: _onPointerUpOrCancel,
            onPointerCancel: _onPointerUpOrCancel,
            child: terminalWidget,
          );
        }

        return Container(
          color: widget.backgroundColor,
          child: Stack(
            children: [
              terminalWidget,
              if (_isTwoFingerPanning || _twoFingerSwipeResult != null)
                _buildTwoFingerSwipeOverlay(),
              _buildSelectionActions(),
            ],
          ),
        );
      },
    );
  }
}

enum _TwoFingerMode {
  undetermined,
  zoom,
  pan,
}
