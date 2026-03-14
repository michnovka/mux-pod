import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:xterm/xterm.dart';

import '../../../providers/settings_provider.dart';
import '../../../services/terminal/font_calculator.dart';
import '../../../services/tmux/pane_navigator.dart';
import '../../../theme/design_colors.dart';

/// Terminal interaction mode.
enum PaneTerminalMode { normal, select }

@immutable
class PaneTerminalViewportState {
  final bool followBottom;
  final double verticalDistanceFromBottom;
  final double horizontalOffset;
  final double zoomScale;

  const PaneTerminalViewportState({
    this.followBottom = true,
    this.verticalDistanceFromBottom = 0,
    this.horizontalOffset = 0,
    this.zoomScale = 1.0,
  });
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
  final bool readOnly;
  final bool verticalScrollEnabled;
  final bool zoomEnabled;
  final bool showCursor;
  final void Function(double scale)? onZoomChanged;
  final ValueChanged<bool>? onFollowBottomChanged;
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
    this.readOnly = false,
    this.verticalScrollEnabled = true,
    this.zoomEnabled = true,
    this.showCursor = true,
    this.onZoomChanged,
    this.onFollowBottomChanged,
    this.verticalScrollController,
    this.onTwoFingerSwipe,
    this.navigableDirections,
  });

  @override
  ConsumerState<PaneTerminalView> createState() => PaneTerminalViewState();
}

class PaneTerminalViewState extends ConsumerState<PaneTerminalView> {
  static const double _autoScrollThresholdPx = 32;

  final ScrollController _horizontalScrollController = ScrollController();
  ScrollController? _internalVerticalScrollController;

  ScrollController get _verticalScrollController =>
      widget.verticalScrollController ?? _internalVerticalScrollController!;

  bool _hasSelection = false;
  double _currentScale = 1.0;
  double _baseScale = 1.0;
  bool _isUserScrollInProgress = false;
  bool _followBottom = true;
  bool _bottomSnapPending = false;

  _TwoFingerMode _twoFingerMode = _TwoFingerMode.undetermined;
  Offset _twoFingerPanStart = Offset.zero;
  Offset _twoFingerPanDelta = Offset.zero;
  bool _isTwoFingerPanning = false;
  SwipeDirection? _twoFingerSwipeResult;
  double _twoFingerStartDistance = 0;

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
    _setFollowBottom(true);
    _snapToBottom();
  }

  PaneTerminalViewportState captureViewportState() {
    final verticalPosition = _verticalScrollController.hasClients
        ? _verticalScrollController.position
        : null;
    final horizontalPosition = _horizontalScrollController.hasClients
        ? _horizontalScrollController.position
        : null;

    return PaneTerminalViewportState(
      followBottom: widget.verticalScrollEnabled ? _followBottom : true,
      verticalDistanceFromBottom:
          !widget.verticalScrollEnabled || verticalPosition == null
          ? 0
          : (verticalPosition.maxScrollExtent - verticalPosition.pixels).clamp(
              0.0,
              double.infinity,
            ),
      horizontalOffset: horizontalPosition?.pixels ?? 0,
      zoomScale: _currentScale,
    );
  }

  void restoreViewportState(PaneTerminalViewportState state) {
    final effectiveState = widget.verticalScrollEnabled
        ? state
        : PaneTerminalViewportState(
            followBottom: true,
            verticalDistanceFromBottom: 0,
            horizontalOffset: state.horizontalOffset,
            zoomScale: state.zoomScale,
          );
    final scaleChanged =
        (_currentScale - effectiveState.zoomScale).abs() > 0.001;
    final followBottomChanged = _followBottom != effectiveState.followBottom;
    _isUserScrollInProgress = false;
    _baseScale = effectiveState.zoomScale;

    if (scaleChanged || followBottomChanged) {
      setState(() {
        _setFollowBottom(effectiveState.followBottom, notify: false);
        if (scaleChanged) {
          _currentScale = effectiveState.zoomScale;
        }
      });
    } else {
      _setFollowBottom(effectiveState.followBottom, notify: false);
    }

    if (scaleChanged) {
      widget.onZoomChanged?.call(effectiveState.zoomScale);
    }

    if (effectiveState.followBottom) {
      scrollToBottom();
      _restoreHorizontalOffset(
        effectiveState.horizontalOffset,
        remainingAttempts: 4,
      );
      return;
    }

    _restoreViewportOffsets(effectiveState, remainingAttempts: 4);
  }

  void _snapToBottom([int remainingAttempts = 3]) {
    if (_bottomSnapPending) {
      return;
    }
    _bottomSnapPending = true;
    _scheduleBottomSnapAttempt(remainingAttempts);
  }

  @visibleForTesting
  bool get hasPendingBottomSnap => _bottomSnapPending;

  void _scheduleBottomSnapAttempt(int remainingAttempts) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        _bottomSnapPending = false;
        return;
      }

      if (!_verticalScrollController.hasClients) {
        if (remainingAttempts > 0) {
          _scheduleBottomSnapAttempt(remainingAttempts - 1);
        } else {
          _bottomSnapPending = false;
        }
        return;
      }

      final position = _verticalScrollController.position;
      final target = position.maxScrollExtent;
      if ((target - position.pixels).abs() > 0.5) {
        position.jumpTo(target);
      }

      if (remainingAttempts > 0 && !_isNearBottomForMetrics(position)) {
        _scheduleBottomSnapAttempt(remainingAttempts - 1);
        return;
      }

      _bottomSnapPending = false;
    });
  }

  void _restoreViewportOffsets(
    PaneTerminalViewportState state, {
    required int remainingAttempts,
  }) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }

      var needsRetry = false;

      if (_verticalScrollController.hasClients) {
        final position = _verticalScrollController.position;
        final target =
            (position.maxScrollExtent - state.verticalDistanceFromBottom).clamp(
              position.minScrollExtent,
              position.maxScrollExtent,
            );
        if ((position.pixels - target).abs() > 0.5) {
          position.jumpTo(target);
        }
        needsRetry = needsRetry || (position.pixels - target).abs() > 0.5;
      } else {
        needsRetry = true;
      }

      needsRetry =
          _restoreHorizontalOffset(
            state.horizontalOffset,
            remainingAttempts: remainingAttempts,
            scheduleRetry: false,
          ) ||
          needsRetry;

      if (remainingAttempts > 0 && needsRetry) {
        _restoreViewportOffsets(
          state,
          remainingAttempts: remainingAttempts - 1,
        );
      }
    });
  }

  bool _restoreHorizontalOffset(
    double offset, {
    required int remainingAttempts,
    bool scheduleRetry = true,
  }) {
    var needsRetry = false;
    if (_horizontalScrollController.hasClients) {
      final position = _horizontalScrollController.position;
      final target = offset.clamp(
        position.minScrollExtent,
        position.maxScrollExtent,
      );
      if ((position.pixels - target).abs() > 0.5) {
        position.jumpTo(target);
      }
      needsRetry = (position.pixels - target).abs() > 0.5;
    } else if (offset > 0.5) {
      needsRetry = true;
    }

    if (!needsRetry || remainingAttempts <= 0 || !scheduleRetry) {
      return needsRetry;
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      _restoreHorizontalOffset(
        offset,
        remainingAttempts: remainingAttempts - 1,
      );
    });
    return true;
  }

  bool get isNearBottom {
    if (!widget.verticalScrollEnabled) {
      return true;
    }
    if (!_verticalScrollController.hasClients) {
      return true;
    }

    final position = _verticalScrollController.position;
    return (position.maxScrollExtent - position.pixels) <=
        _autoScrollThresholdPx;
  }

  bool get shouldAutoFollow => _followBottom && !_isUserScrollInProgress;

  void _setFollowBottom(bool value, {bool notify = true}) {
    if (_followBottom == value) {
      return;
    }
    _followBottom = value;
    if (notify) {
      widget.onFollowBottomChanged?.call(value);
    }
  }

  bool _isNearBottomForMetrics(ScrollMetrics metrics) {
    return (metrics.maxScrollExtent - metrics.pixels) <= _autoScrollThresholdPx;
  }

  bool _handleScrollNotification(ScrollNotification notification) {
    if (!widget.verticalScrollEnabled ||
        notification.metrics.axis != Axis.vertical) {
      return false;
    }

    if (notification is ScrollStartNotification &&
        notification.dragDetails != null) {
      _isUserScrollInProgress = true;
      _setFollowBottom(false);
      return false;
    }

    final isNearBottom = _isNearBottomForMetrics(notification.metrics);
    if (notification is ScrollEndNotification ||
        (notification is UserScrollNotification &&
            notification.direction == ScrollDirection.idle)) {
      _isUserScrollInProgress = false;
      _setFollowBottom(isNearBottom);
      return false;
    }

    if (!_isUserScrollInProgress && isNearBottom) {
      _setFollowBottom(true);
    }

    return false;
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

    if (_pointerCurrentPositions.length == 2) {
      _beginTwoFingerGesture();
    }
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (!_pointerCurrentPositions.containsKey(event.pointer)) {
      return;
    }

    _pointerCurrentPositions[event.pointer] = event.position;

    if (_pointerCurrentPositions.length < 2) {
      return;
    }

    if (_twoFingerMode == _TwoFingerMode.zoom) {
      _updateZoomFromPointers();
      return;
    }

    if (_twoFingerMode == _TwoFingerMode.pan) {
      _isTwoFingerPanning = true;
      _twoFingerPanDelta = _currentTwoFingerFocalPoint() - _twoFingerPanStart;
      setState(() {});
      return;
    }

    _twoFingerMode = _detectModeFromFingerDirections();
    switch (_twoFingerMode) {
      case _TwoFingerMode.zoom:
        _updateZoomFromPointers();
        return;
      case _TwoFingerMode.pan:
        _isTwoFingerPanning = true;
        _twoFingerPanDelta = _currentTwoFingerFocalPoint() - _twoFingerPanStart;
        setState(() {});
        return;
      case _TwoFingerMode.undetermined:
        _twoFingerPanDelta = _currentTwoFingerFocalPoint() - _twoFingerPanStart;
        return;
    }
  }

  void _onPointerUpOrCancel(PointerEvent event) {
    final hadTwoFingerGesture = _pointerCurrentPositions.length >= 2;
    _pointerStartPositions.remove(event.pointer);
    _pointerCurrentPositions.remove(event.pointer);

    if (hadTwoFingerGesture && _pointerCurrentPositions.length < 2) {
      _endTwoFingerGesture();
      return;
    }

    if (hadTwoFingerGesture && _pointerCurrentPositions.length >= 2) {
      _beginTwoFingerGesture();
    }
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

  void _beginTwoFingerGesture() {
    _baseScale = _currentScale;
    _twoFingerPanStart = _currentTwoFingerFocalPoint();
    _twoFingerPanDelta = Offset.zero;
    _isTwoFingerPanning = false;
    _twoFingerMode = _TwoFingerMode.undetermined;
    _twoFingerStartDistance = _currentTwoFingerDistance();

    for (final entry in _pointerCurrentPositions.entries) {
      _pointerStartPositions[entry.key] = entry.value;
    }
  }

  Offset _currentTwoFingerFocalPoint() {
    final pointers = _activeTwoFingerPointers();
    if (pointers.length < 2) {
      return Offset.zero;
    }

    final first = _pointerCurrentPositions[pointers[0]]!;
    final second = _pointerCurrentPositions[pointers[1]]!;
    return Offset((first.dx + second.dx) / 2, (first.dy + second.dy) / 2);
  }

  double _currentTwoFingerDistance() {
    final pointers = _activeTwoFingerPointers();
    if (pointers.length < 2) {
      return 0;
    }

    final first = _pointerCurrentPositions[pointers[0]]!;
    final second = _pointerCurrentPositions[pointers[1]]!;
    return (second - first).distance;
  }

  List<int> _activeTwoFingerPointers() {
    return _pointerCurrentPositions.keys.take(2).toList(growable: false);
  }

  void _updateZoomFromPointers() {
    final distance = _currentTwoFingerDistance();
    if (_twoFingerStartDistance <= 0 || distance <= 0) {
      return;
    }

    final newScale = (_baseScale * (distance / _twoFingerStartDistance)).clamp(
      0.5,
      5.0,
    );
    if (newScale == _currentScale) {
      return;
    }

    setState(() {
      _currentScale = newScale;
    });
    widget.onZoomChanged?.call(newScale);
  }

  void _endTwoFingerGesture() {
    final wasPanning = _isTwoFingerPanning;
    _isTwoFingerPanning = false;
    _twoFingerMode = _TwoFingerMode.undetermined;
    _twoFingerStartDistance = 0;
    if (!wasPanning) {
      _twoFingerPanDelta = Offset.zero;
      setState(() {});
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
          border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
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
                colors: [Colors.transparent, Colors.red.withValues(alpha: 0.4)],
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
                colors: [Colors.transparent, color],
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
          child: MediaQuery.removePadding(
            context: context,
            removeLeft: true,
            removeTop: true,
            removeRight: true,
            removeBottom: true,
            child: TerminalView(
              widget.terminal,
              controller: widget.terminalController,
              scrollController: _verticalScrollController,
              autoResize: false,
              autofocus: true,
              deleteDetection: true,
              readOnly:
                  widget.readOnly || widget.mode == PaneTerminalMode.select,
              simulateScroll:
                  widget.mode == PaneTerminalMode.normal &&
                  widget.verticalScrollEnabled,
              scrollPhysics: widget.verticalScrollEnabled
                  ? null
                  : const NeverScrollableScrollPhysics(),
              theme: _buildTheme(),
              textStyle: TerminalStyle(
                fontSize: fontSize,
                height: 1.4,
                fontFamily: settings.fontFamily,
              ),
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
          terminalWidget = Listener(
            onPointerDown: _onPointerDown,
            onPointerMove: _onPointerMove,
            onPointerUp: _onPointerUpOrCancel,
            onPointerCancel: _onPointerUpOrCancel,
            child: terminalWidget,
          );
        }

        return NotificationListener<ScrollNotification>(
          onNotification: _handleScrollNotification,
          child: Container(
            color: widget.backgroundColor,
            child: Stack(
              children: [
                terminalWidget,
                if (_isTwoFingerPanning || _twoFingerSwipeResult != null)
                  _buildTwoFingerSwipeOverlay(),
                _buildSelectionActions(),
              ],
            ),
          ),
        );
      },
    );
  }
}

enum _TwoFingerMode { undetermined, zoom, pan }
