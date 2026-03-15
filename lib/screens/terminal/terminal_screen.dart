import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:xterm/xterm.dart';

import '../../providers/active_session_provider.dart';
import '../../providers/connection_provider.dart';
import '../../providers/known_hosts_provider.dart';
import '../../providers/settings_provider.dart';
import '../../providers/ssh_provider.dart';
import '../../providers/tmux_provider.dart';
import '../../services/keychain/secure_storage.dart';
import '../../services/network/network_monitor.dart';
import '../../services/ssh/input_queue.dart';
import '../../services/ssh/ssh_client.dart'
    show SshConnectOptions, SshHostKeyError;
import '../../services/terminal/bounded_text_buffer.dart';
import '../../services/terminal/terminal_image_attachment.dart';
import '../../services/terminal/terminal_output_normalizer.dart';
import '../../services/terminal/terminal_scrollback_merge.dart';
import '../../services/terminal/terminal_snapshot.dart';
import '../../services/terminal/xterm_input_adapter.dart';
import '../../services/tmux/pane_navigator.dart';
import '../../services/tmux/tmux_commands.dart';
import '../../services/tmux/tmux_control_client.dart';
import '../../services/tmux/tmux_parser.dart'
    show TmuxPane, TmuxParser, TmuxWindow, TmuxWindowFlag;
import '../../theme/design_colors.dart';
import '../../widgets/dialogs/viewport_resize_dialog.dart';
import 'widgets/tmux_management_dialogs.dart';
import '../../widgets/special_keys_bar.dart';
import '../../providers/terminal_display_provider.dart';
import '../settings/settings_screen.dart';
import 'terminal_scroll_policy.dart';
import 'widgets/pane_terminal_view.dart';

/// Terminal mode used by the mobile UI.
enum TerminalMode { normal, select }

enum _ConnectionIndicatorMode { latency, bandwidth }

enum _PendingLiveUpdateKind { none, lines, updated }

class _PaneSnapshotPayload {
  final String activeContent;
  final String mainContent;
  final String metadata;

  const _PaneSnapshotPayload({
    required this.activeContent,
    required this.mainContent,
    required this.metadata,
  });
}

class _PendingKeyboardModifiers {
  final bool ctrl;
  final bool alt;
  final bool shift;

  const _PendingKeyboardModifiers({
    required this.ctrl,
    required this.alt,
    required this.shift,
  });

  bool get isEmpty => !ctrl && !alt && !shift;
}

class _PaneRenderCacheEntry {
  final Terminal terminal;
  final TerminalSnapshotFrame frame;
  final PaneTerminalViewportState viewportState;
  final DateTime capturedAt;

  const _PaneRenderCacheEntry({
    required this.terminal,
    required this.frame,
    required this.viewportState,
    required this.capturedAt,
  });

  _PaneRenderCacheEntry copyWith({
    Terminal? terminal,
    TerminalSnapshotFrame? frame,
    PaneTerminalViewportState? viewportState,
    DateTime? capturedAt,
  }) {
    return _PaneRenderCacheEntry(
      terminal: terminal ?? this.terminal,
      frame: frame ?? this.frame,
      viewportState: viewportState ?? this.viewportState,
      capturedAt: capturedAt ?? this.capturedAt,
    );
  }
}

class _TerminalLoadMetrics {
  final String reason;
  final bool refreshTree;
  final bool restartedControlClient;
  final int totalMs;
  final int? treeRefreshMs;
  final int? controlStartMs;
  final int? snapshotFetchMs;
  final int? snapshotParseMs;
  final int? terminalApplyMs;
  final int? snapshotPayloadBytes;
  final int? snapshotPayloadLines;
  final int? firstLiveOutputMs;
  final bool snapshotApplied;

  const _TerminalLoadMetrics({
    required this.reason,
    required this.refreshTree,
    required this.restartedControlClient,
    required this.totalMs,
    required this.snapshotApplied,
    this.treeRefreshMs,
    this.controlStartMs,
    this.snapshotFetchMs,
    this.snapshotParseMs,
    this.terminalApplyMs,
    this.snapshotPayloadBytes,
    this.snapshotPayloadLines,
    this.firstLiveOutputMs,
  });

  _TerminalLoadMetrics copyWith({
    int? firstLiveOutputMs,
  }) {
    return _TerminalLoadMetrics(
      reason: reason,
      refreshTree: refreshTree,
      restartedControlClient: restartedControlClient,
      totalMs: totalMs,
      treeRefreshMs: treeRefreshMs,
      controlStartMs: controlStartMs,
      snapshotFetchMs: snapshotFetchMs,
      snapshotParseMs: snapshotParseMs,
      terminalApplyMs: terminalApplyMs,
      snapshotPayloadBytes: snapshotPayloadBytes,
      snapshotPayloadLines: snapshotPayloadLines,
      firstLiveOutputMs: firstLiveOutputMs ?? this.firstLiveOutputMs,
      snapshotApplied: snapshotApplied,
    );
  }

  String get summary {
    final parts = <String>[
      reason,
      'total ${totalMs}ms',
      if (treeRefreshMs != null) 'tree ${treeRefreshMs}ms',
      if (controlStartMs != null) 'control ${controlStartMs}ms',
      if (snapshotFetchMs != null) 'fetch ${snapshotFetchMs}ms',
      if (snapshotParseMs != null) 'parse ${snapshotParseMs}ms',
      if (terminalApplyMs != null) 'render ${terminalApplyMs}ms',
      if (firstLiveOutputMs != null) 'first live ${firstLiveOutputMs}ms',
      if (snapshotPayloadBytes != null)
        '${(snapshotPayloadBytes! / 1024).toStringAsFixed(1)}KB',
      if (snapshotPayloadLines != null) '$snapshotPayloadLines lines',
    ];
    return parts.join(' · ');
  }
}

@immutable
class _PendingLiveUpdateState {
  final _PendingLiveUpdateKind kind;
  final int lineCount;

  const _PendingLiveUpdateState._({
    required this.kind,
    required this.lineCount,
  });

  const _PendingLiveUpdateState.none()
    : this._(kind: _PendingLiveUpdateKind.none, lineCount: 0);

  const _PendingLiveUpdateState.lines(int count)
    : this._(kind: _PendingLiveUpdateKind.lines, lineCount: count);

  const _PendingLiveUpdateState.updated()
    : this._(kind: _PendingLiveUpdateKind.updated, lineCount: 0);

  bool get hasPending => kind != _PendingLiveUpdateKind.none;
}

class _TerminalLoadTrace {
  final String reason;
  final bool refreshTree;
  final bool restartedControlClient;
  final Stopwatch stopwatch = Stopwatch()..start();

  int? treeRefreshMs;
  int? controlStartMs;
  int? snapshotFetchMs;
  int? snapshotParseMs;
  int? terminalApplyMs;
  int? snapshotPayloadBytes;
  int? snapshotPayloadLines;

  _TerminalLoadTrace({
    required this.reason,
    required this.refreshTree,
    required this.restartedControlClient,
  });

  _TerminalLoadMetrics finish({required bool snapshotApplied}) {
    stopwatch.stop();
    return _TerminalLoadMetrics(
      reason: reason,
      refreshTree: refreshTree,
      restartedControlClient: restartedControlClient,
      totalMs: stopwatch.elapsedMilliseconds,
      treeRefreshMs: treeRefreshMs,
      controlStartMs: controlStartMs,
      snapshotFetchMs: snapshotFetchMs,
      snapshotParseMs: snapshotParseMs,
      terminalApplyMs: terminalApplyMs,
      snapshotPayloadBytes: snapshotPayloadBytes,
      snapshotPayloadLines: snapshotPayloadLines,
      snapshotApplied: snapshotApplied,
    );
  }
}

class _TmuxTargetSelection {
  final String? sessionName;
  final int? windowIndex;
  final int? paneIndex;
  final String? paneId;

  const _TmuxTargetSelection({
    required this.sessionName,
    required this.windowIndex,
    required this.paneIndex,
    required this.paneId,
  });

  factory _TmuxTargetSelection.fromState(TmuxState state) {
    return _TmuxTargetSelection(
      sessionName: state.activeSessionName,
      windowIndex: state.activeWindowIndex,
      paneIndex: state.activePaneIndex,
      paneId: state.activePaneId,
    );
  }
}

/// Terminal screen (compliant with HTML design specification)
class TerminalScreen extends ConsumerStatefulWidget {
  final String connectionId;
  final String? sessionName;

  /// For restoration: last opened window index
  final int? lastWindowIndex;

  /// For restoration: last opened pane ID
  final String? lastPaneId;

  const TerminalScreen({
    super.key,
    required this.connectionId,
    this.sessionName,
    this.lastWindowIndex,
    this.lastPaneId,
  });

  @override
  ConsumerState<TerminalScreen> createState() => _TerminalScreenState();
}

class _TerminalScreenState extends ConsumerState<TerminalScreen>
    with WidgetsBindingObserver {
  static const int _maxDeferredStreamOutputChars = 256 * 1024;
  static const int _literalInputChunkLength = 1024;
  static const Duration _connectionLookupTimeout = Duration(seconds: 3);
  static const Duration _initialControlRestartDelay = Duration(
    milliseconds: 250,
  );
  static const Duration _maxControlRestartDelay = Duration(seconds: 4);
  static const Duration _paneCacheMaxAge = Duration(seconds: 4);
  static const String _snapshotMainMarker = '\x01__MUXPOD_MAIN__\x01';
  static const String _snapshotAltMarker = '\x01__MUXPOD_ALT__\x01';
  static const String _snapshotMetadataMarker = '\x01__MUXPOD_META__\x01';

  final _secureStorage = SecureStorageService();
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  final _paneTerminalViewKey = GlobalKey<PaneTerminalViewState>();
  final _terminalScrollController = _StableScrollController();
  late Terminal _terminal;
  final _terminalController = TerminalController();
  int _terminalScrollbackLines = AppSettings().scrollbackLines;
  final Map<String, _PaneRenderCacheEntry> _paneRenderCache = {};
  final _pendingLiveUpdateNotifier = ValueNotifier<_PendingLiveUpdateState>(
    const _PendingLiveUpdateState.none(),
  );

  // Connection state (managed locally)
  bool _isConnecting = false;
  bool _isSwitchingPane = false;
  bool _showSwitchingOverlay = false;
  int? _lastBellWindowIndex;
  DateTime? _lastBellTime;
  String? _connectionError;
  SshState _sshState = const SshState();

  // Terminal display data used for bootstrap/resync (managed via ValueNotifier)
  final _viewNotifier = ValueNotifier<TerminalSnapshotFrame>(
    const TerminalSnapshotFrame(),
  );
  final _latencyNotifier = ValueNotifier<int>(0);
  final _bandwidthNotifier = ValueNotifier<int>(0);
  final _deferredStreamOutput = BoundedTextBuffer(
    maxLength: _maxDeferredStreamOutputChars,
  );

  TmuxControlClient? _controlClient;
  String? _controlClientSessionName;
  Timer? _controlSyncTimer;
  Timer? _controlRestartTimer;
  Timer? _bandwidthTimer;
  int _controlRestartAttempt = 0;
  bool _isResyncingPane = false;
  bool _pauseControlOutputUntilResyncComplete = false;
  bool _isFollowingLiveTail = true;
  double _lastKeyboardInset = 0;
  _ConnectionIndicatorMode _connectionIndicatorMode =
      _ConnectionIndicatorMode.latency;
  String? _loadingStageLabel;
  _TerminalLoadMetrics? _lastLoadMetrics;
  DateTime? _pendingFirstLiveOutputStartedAt;
  String? _pendingFirstLiveOutputPaneId;
  int _scrollbackBackfillToken = 0;
  int _lastBandwidthSampleTotalBytes = 0;
  DateTime? _lastBandwidthSampleAt;
  DateTime? _lastLatencySampleAt;
  double? _pendingHistoryViewportAnchorPixels;
  bool _historyViewportAnchorScheduled = false;
  bool _shouldRefreshTreeAfterControlSync = false;
  bool _shouldResyncAfterControlRefresh = false;
  bool _isDisposed = false;

  TerminalSnapshotFrame _pendingViewData = const TerminalSnapshotFrame();

  // Initial scroll completed flag
  bool _hasInitialScrolled = false;

  // Terminal mode
  TerminalMode _terminalMode = TerminalMode.normal;

  // Zoom scale
  double _zoomScale = 1.0;

  // Input queue (holds input during disconnection)
  final _inputQueue = InputQueue();

  // Background state
  bool _isInBackground = false;

  // Sticky extra-key modifiers applied to the next keyboard action.
  bool _ctrlModifierPressed = false;
  bool _altModifierPressed = false;
  bool _shiftModifierPressed = false;
  SshNotifier? _sshNotifier;

  // Riverpod listeners
  ProviderSubscription<SshState>? _sshSubscription;
  ProviderSubscription<TmuxState>? _tmuxSubscription;
  ProviderSubscription<AppSettings>? _settingsSubscription;
  ProviderSubscription<AsyncValue<NetworkStatus>>? _networkSubscription;

  @override
  void initState() {
    super.initState();
    _terminal = _createTerminalEmulator();
    WidgetsBinding.instance.addObserver(this);

    // Set up listeners on the next frame (because ref is needed)
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _setupListeners();
      _connectAndSetup();
      _applyKeepScreenOn();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
        _pausePolling();
        break;
      case AppLifecycleState.resumed:
        _resumePolling();
        break;
      case AppLifecycleState.detached:
        break;
    }
  }

  /// Stop live terminal streaming when transitioning to background.
  void _pausePolling() {
    _isInBackground = true;
    _controlSyncTimer?.cancel();
    _controlSyncTimer = null;
    _stopConnectionStatsPolling(resetValue: true);
    unawaited(_stopControlClient(resetRestartState: true));
    WakelockPlus.disable();
  }

  /// Resume live terminal streaming when returning to foreground.
  void _resumePolling() {
    if (!_isInBackground || _isDisposed) return;
    _isInBackground = false;
    _applyKeepScreenOn();
    _startConnectionStatsPolling();
    unawaited(
      _restartTerminalStream(
        restartControlClient: true,
        reason: 'resume_foreground',
      ),
    );
  }

  /// Apply keep screen on setting
  void _applyKeepScreenOn() {
    final settings = ref.read(settingsProvider);
    if (settings.keepScreenOn) {
      WakelockPlus.enable();
    } else {
      WakelockPlus.disable();
    }
  }

  /// Set up Provider listeners
  void _setupListeners() {
    // Monitor SSH state changes
    _sshSubscription = ref.listenManual<SshState>(sshProvider, (
      previous,
      next,
    ) {
      if (!mounted || _isDisposed) return;
      setState(() {
        _sshState = next;
      });
    }, fireImmediately: true);

    // Monitor Tmux state changes
    // Note: Parent setState() is not needed. Breadcrumbs and pane indicators
    // directly watch tmuxProvider via Consumer widgets, so they are
    // only rebuilt within the subtree.
    _tmuxSubscription = ref.listenManual<TmuxState>(tmuxProvider, (
      previous,
      next,
    ) {
      // Consumer widgets directly watch tmuxProvider, so
      // parent setState() is not needed (removed for BottomSheet stability)
    }, fireImmediately: true);

    // Monitor settings changes.
    _settingsSubscription = ref.listenManual<AppSettings>(settingsProvider, (
      previous,
      next,
    ) {
      if (!mounted || _isDisposed) return;
      if (previous?.keepScreenOn != next.keepScreenOn) {
        _applyKeepScreenOn();
      }
      if (previous?.scrollbackLines != next.scrollbackLines) {
        _reconfigureTerminal(next);
        unawaited(
          _resyncActivePane(
            refreshTree: false,
            reason: 'settings_scrollback_change',
          ),
        );
      }
    }, fireImmediately: false);

    _reconfigureTerminal(ref.read(settingsProvider));

    // Monitor network state changes (only update on actual connection state changes)
    _networkSubscription = ref.listenManual<AsyncValue<NetworkStatus>>(
      networkStatusProvider,
      (previous, next) {
        if (!mounted || _isDisposed) return;
        final prevStatus = previous?.value;
        final nextStatus = next.value;
        if (prevStatus != nextStatus) {
          setState(() {});
        }
      },
      fireImmediately: true,
    );

    // Set up handler for successful reconnection
    _sshNotifier = ref.read(sshProvider.notifier);
    _sshNotifier!.onReconnectSuccess = _onReconnectSuccess;
  }

  /// Handler for successful reconnection
  Future<void> _onReconnectSuccess() async {
    if (!mounted || _isDisposed) return;

    await _stopControlClient(resetRestartState: true);
    await _refreshSessionTree(syncActive: true);
    await _restartTerminalStream(
      restartControlClient: true,
      refreshTree: false,
      reason: 'reconnect_recover',
    );
    await _flushInputQueue();
    _startConnectionStatsPolling();

    // Update UI
    if (mounted) setState(() {});
  }

  void _startConnectionStatsPolling() {
    _stopConnectionStatsPolling();
    if (_isDisposed || _isInBackground) {
      return;
    }

    final sshClient = _sshNotifier?.client;
    _lastBandwidthSampleTotalBytes = sshClient?.totalPayloadBytes ?? 0;
    _lastBandwidthSampleAt = DateTime.now();
    _refreshConnectionStats(resetBandwidthSample: true);
    _bandwidthTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _refreshConnectionStats();
    });
  }

  void _stopConnectionStatsPolling({bool resetValue = false}) {
    _bandwidthTimer?.cancel();
    _bandwidthTimer = null;
    _lastBandwidthSampleTotalBytes = 0;
    _lastBandwidthSampleAt = null;
    _lastLatencySampleAt = null;
    if (resetValue && !_isDisposed) {
      _latencyNotifier.value = 0;
      _bandwidthNotifier.value = 0;
    }
  }

  void _refreshConnectionStats({bool resetBandwidthSample = false}) {
    if (_isDisposed || _isInBackground || !mounted) {
      return;
    }

    final sshClient = _sshNotifier?.client;
    if (sshClient == null || !sshClient.isConnected) {
      return;
    }

    final sampledLatencyAt = sshClient.lastKeepAliveLatencyAt;
    if (sampledLatencyAt != null) {
      _recordLatencySample(
        sshClient.lastKeepAliveLatencyMs,
        sampledAt: sampledLatencyAt,
      );
    }

    final now = DateTime.now();
    if (resetBandwidthSample || _lastBandwidthSampleAt == null) {
      _lastBandwidthSampleAt = now;
      _lastBandwidthSampleTotalBytes = sshClient.totalPayloadBytes;
      _bandwidthNotifier.value = 0;
      return;
    }

    final lastSampleAt = _lastBandwidthSampleAt!;
    final elapsedMs = now.difference(lastSampleAt).inMilliseconds;
    if (elapsedMs <= 0) {
      return;
    }

    final totalBytes = sshClient.totalPayloadBytes;
    final deltaBytes = math.max(0, totalBytes - _lastBandwidthSampleTotalBytes);
    final bitsPerSecond = (deltaBytes * 8 * 1000 / elapsedMs).round();

    _lastBandwidthSampleAt = now;
    _lastBandwidthSampleTotalBytes = totalBytes;
    _bandwidthNotifier.value = bitsPerSecond;
  }

  void _recordLatencySample(int latencyMs, {DateTime? sampledAt}) {
    if (_isDisposed) {
      return;
    }
    final effectiveSampleAt = sampledAt ?? DateTime.now();
    if (_lastLatencySampleAt != null &&
        effectiveSampleAt.isBefore(_lastLatencySampleAt!)) {
      return;
    }
    _lastLatencySampleAt = effectiveSampleAt;
    _latencyNotifier.value = latencyMs;
  }

  /// Send queued input
  Future<void> _flushInputQueue() async {
    if (_inputQueue.isEmpty) return;

    final queuedInput = _inputQueue.flush();
    if (queuedInput.isNotEmpty) {
      await _sendTerminalData(queuedInput);
    }
  }

  Terminal _createTerminalEmulator() {
    return Terminal(maxLines: _terminalScrollbackLines, reflowEnabled: false)
      ..onOutput = _handleTerminalOutput;
  }

  bool get _shouldCollectTerminalPerfMetrics => kDebugMode || kProfileMode;

  void _setLoadingStage(String? value) {
    if (_loadingStageLabel == value) {
      return;
    }

    if (!mounted || _isDisposed) {
      _loadingStageLabel = value;
      return;
    }

    setState(() {
      _loadingStageLabel = value;
    });
  }

  void _recordLoadMetrics(_TerminalLoadMetrics metrics) {
    _lastLoadMetrics = metrics;
    if (_shouldCollectTerminalPerfMetrics) {
      debugPrint('[TerminalLoad] ${metrics.summary}');
    }

    if (!mounted || _isDisposed) {
      return;
    }

    setState(() {});
  }

  void _armFirstLiveOutputProbe(String paneId) {
    _pendingFirstLiveOutputPaneId = paneId;
    _pendingFirstLiveOutputStartedAt = DateTime.now();
  }

  void _recordFirstLiveOutputIfNeeded(String paneId) {
    if (_pendingFirstLiveOutputPaneId != paneId ||
        _pendingFirstLiveOutputStartedAt == null ||
        _lastLoadMetrics == null) {
      return;
    }

    final firstLiveOutputMs = DateTime.now()
        .difference(_pendingFirstLiveOutputStartedAt!)
        .inMilliseconds;
    _pendingFirstLiveOutputPaneId = null;
    _pendingFirstLiveOutputStartedAt = null;
    _recordLoadMetrics(
      _lastLoadMetrics!.copyWith(firstLiveOutputMs: firstLiveOutputMs),
    );
  }

  int _countTextLines(String text) {
    if (text.isEmpty) {
      return 0;
    }
    return '\n'.allMatches(text).length + 1;
  }

  void _resetTerminalEmulator() {
    _terminal = _createTerminalEmulator();
  }

  void _reconfigureTerminal(AppSettings settings) {
    if (_terminalScrollbackLines == settings.scrollbackLines) {
      _terminal.onOutput = _handleTerminalOutput;
      for (final entry in _paneRenderCache.values) {
        entry.terminal.onOutput = _handleTerminalOutput;
      }
      return;
    }
    _terminalScrollbackLines = settings.scrollbackLines;
    _paneRenderCache.clear();
    _resetTerminalEmulator();
    if (mounted) {
      setState(() {});
    }
  }

  TerminalSnapshotFrame _cacheFrameForTerminal() {
    final buffer = _terminal.buffer;
    return _viewNotifier.value.copyWith(
      paneWidth: _terminal.viewWidth,
      paneHeight: _terminal.viewHeight,
      alternateScreen: _terminal.isUsingAltBuffer,
      cursorX: buffer.cursorX,
      cursorY: buffer.cursorY,
      insertMode: _terminal.insertMode,
      cursorKeysMode: _terminal.cursorKeysMode,
      appKeypadMode: _terminal.appKeypadMode,
      autoWrapMode: _terminal.autoWrapMode,
      pendingWrap: buffer.isCursorInWrapState,
      cursorVisible: _terminal.cursorVisibleMode,
      originMode: _terminal.originMode,
      scrollRegionUpper: buffer.marginTop,
      scrollRegionLower: buffer.marginBottom,
    );
  }

  TerminalSnapshotFrame _cacheFrameForTerminalInstance(
    Terminal terminal, {
    TerminalSnapshotFrame? fallbackFrame,
  }) {
    final buffer = terminal.buffer;
    final baseFrame = fallbackFrame ?? _viewNotifier.value;
    return baseFrame.copyWith(
      paneWidth: terminal.viewWidth,
      paneHeight: terminal.viewHeight,
      alternateScreen: terminal.isUsingAltBuffer,
      cursorX: buffer.cursorX,
      cursorY: buffer.cursorY,
      insertMode: terminal.insertMode,
      cursorKeysMode: terminal.cursorKeysMode,
      appKeypadMode: terminal.appKeypadMode,
      autoWrapMode: terminal.autoWrapMode,
      pendingWrap: buffer.isCursorInWrapState,
      cursorVisible: terminal.cursorVisibleMode,
      originMode: terminal.originMode,
      scrollRegionUpper: buffer.marginTop,
      scrollRegionLower: buffer.marginBottom,
    );
  }

  void _cachePaneRenderState({
    String? paneId,
    PaneTerminalViewportState? viewportState,
  }) {
    final resolvedPaneId = paneId ?? ref.read(tmuxProvider).activePaneId;
    if (resolvedPaneId == null) {
      return;
    }

    final resolvedViewportState =
        viewportState ??
        _paneTerminalViewKey.currentState?.captureViewportState() ??
        _paneRenderCache[resolvedPaneId]?.viewportState ??
        const PaneTerminalViewportState();

    _paneRenderCache[resolvedPaneId] = _PaneRenderCacheEntry(
      terminal: _terminal..onOutput = _handleTerminalOutput,
      frame: _cacheFrameForTerminal(),
      viewportState: resolvedViewportState,
      capturedAt: DateTime.now(),
    );
  }

  bool _restorePaneRenderState(
    String? paneId, {
    Duration? maxAge = _paneCacheMaxAge,
  }) {
    if (paneId == null) {
      return false;
    }

    final cacheEntry = _paneRenderCache[paneId];
    if (cacheEntry == null) {
      return false;
    }
    if (maxAge != null &&
        DateTime.now().difference(cacheEntry.capturedAt) > maxAge) {
      _paneRenderCache.remove(paneId);
      return false;
    }

    _terminalController.clearSelection();
    cacheEntry.terminal.onOutput = _handleTerminalOutput;
    _terminal = cacheEntry.terminal;
    final activePane = ref.read(tmuxProvider).activePane;
    final restoredFrame = cacheEntry.frame.copyWith(
      paneWidth: activePane?.width ?? cacheEntry.frame.paneWidth,
      paneHeight: activePane?.height ?? cacheEntry.frame.paneHeight,
      cursorX: activePane?.cursorX ?? cacheEntry.frame.cursorX,
      cursorY: activePane?.cursorY ?? cacheEntry.frame.cursorY,
    );
    _pendingViewData = restoredFrame;
    _viewNotifier.value = restoredFrame;
    _hasInitialScrolled = true;
    _isFollowingLiveTail = cacheEntry.viewportState.followBottom;
    _paneTerminalViewKey.currentState?.restoreViewportState(
      cacheEntry.viewportState,
    );
    return true;
  }

  void _showPlaceholderPane(TmuxPane? pane) {
    _terminalController.clearSelection();
    _resetTerminalEmulator();
    _pendingFirstLiveOutputPaneId = null;
    _pendingFirstLiveOutputStartedAt = null;
    _scrollbackBackfillToken += 1;
    final emptyView = _viewNotifier.value.copyWith(
      content: '',
      mainContent: '',
      alternateScreen: false,
      paneWidth: pane?.width ?? _viewNotifier.value.paneWidth,
      paneHeight: pane?.height ?? _viewNotifier.value.paneHeight,
      cursorX: 0,
      cursorY: 0,
      scrollRegionUpper: null,
      scrollRegionLower: null,
    );
    _pendingViewData = emptyView;
    _viewNotifier.value = emptyView;
    _hasInitialScrolled = false;
    _isFollowingLiveTail = true;
    _clearPendingLiveUpdates();
  }

  bool _showActivePaneFromCacheOrPlaceholder({
    Duration? maxAge = _paneCacheMaxAge,
  }) {
    final tmuxState = ref.read(tmuxProvider);
    final activePane = tmuxState.activePane;
    final restored = _restorePaneRenderState(activePane?.id, maxAge: maxAge);
    if (!restored) {
      _showPlaceholderPane(activePane);
    }

    if (activePane != null) {
      ref.read(terminalDisplayProvider.notifier).updatePane(activePane);
    }

    return restored;
  }

  void _restoreLocalSelection(_TmuxTargetSelection selection) {
    ref
        .read(tmuxProvider.notifier)
        .setActive(
          sessionName: selection.sessionName,
          windowIndex: selection.windowIndex,
          paneIndex: selection.paneIndex,
          paneId: selection.paneId,
        );
    _showActivePaneFromCacheOrPlaceholder();
  }

  Future<void> _recoverFromFailedSwitch(
    _TmuxTargetSelection previousSelection, {
    bool restartControlClient = false,
    bool restoreRemoteTarget = false,
  }) async {
    _restoreLocalSelection(previousSelection);

    try {
      final sshClient = ref.read(sshProvider.notifier).client;
      if (restoreRemoteTarget && sshClient != null && sshClient.isConnected) {
        if (previousSelection.paneId != null) {
          await sshClient.execPersistent(
            TmuxCommands.selectPane(previousSelection.paneId!),
          );
        } else if (previousSelection.sessionName != null &&
            previousSelection.windowIndex != null) {
          await sshClient.execPersistent(
            TmuxCommands.selectWindow(
              previousSelection.sessionName!,
              previousSelection.windowIndex!,
            ),
          );
        }
      }

      if (restartControlClient && previousSelection.sessionName != null) {
        await _restartTerminalStream(
          restartControlClient: true,
          refreshTree: false,
          reason: 'switch_recovery',
        );
      }

      final paneId = previousSelection.paneId;
      if (paneId != null && sshClient != null && sshClient.isConnected) {
        await sshClient.execPersistentInput(
          TmuxCommands.sendKeys(paneId, '\x1b[I', literal: true),
        );
      }
    } catch (_) {
      // Best-effort recovery only. The local selection has already been restored.
    }
  }

  void _persistActivePaneSelection(String paneId) {
    final tmuxState = ref.read(tmuxProvider);
    final sessionName = tmuxState.activeSessionName;
    final windowIndex = tmuxState.activeWindowIndex;
    if (sessionName == null || windowIndex == null) {
      return;
    }

    ref
        .read(activeSessionsProvider.notifier)
        .updateLastPane(
          connectionId: widget.connectionId,
          sessionName: sessionName,
          windowIndex: windowIndex,
          paneId: paneId,
        );
  }

  void _syncKeyboardViewportState({
    required bool keyboardVisible,
    required double keyboardInset,
  }) {
    if ((keyboardInset - _lastKeyboardInset).abs() < 0.5) {
      return;
    }

    _lastKeyboardInset = keyboardInset;

    if (!keyboardVisible || _terminalMode != TerminalMode.normal) {
      return;
    }

    final paneView = _paneTerminalViewKey.currentState;
    final shouldFollowBottom =
        paneView?.shouldAutoFollow ?? paneView?.isNearBottom ?? true;
    if (!shouldFollowBottom) {
      return;
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _terminalMode != TerminalMode.normal) {
        return;
      }

      if (_terminalScrollController.shouldPreserveTopAnchorForShortContent) {
        return;
      }

      _terminalScrollController.armUnsuppressedStickToBottom();
      _paneTerminalViewKey.currentState?.scrollToBottom();
    });
  }

  void _handleLiveFollowChanged(bool followBottom) {
    if (_isFollowingLiveTail == followBottom) {
      if (followBottom && _pendingLiveUpdateNotifier.value.hasPending) {
        _clearPendingLiveUpdates();
      }
      return;
    }

    if (followBottom) {
      _clearPendingLiveUpdates();
    }

    if (!mounted || _isDisposed) {
      _isFollowingLiveTail = followBottom;
      return;
    }

    setState(() {
      _isFollowingLiveTail = followBottom;
    });
  }

  void _jumpToLive() {
    _clearPendingLiveUpdates();
    _terminalScrollController.armUnsuppressedStickToBottom();
    _paneTerminalViewKey.currentState?.scrollToBottom();
  }

  void _recordPendingLiveUpdate({
    required String data,
    required int beforeScrollBack,
  }) {
    if (_terminal.isUsingAltBuffer || _isFollowingLiveTail || data.isEmpty) {
      return;
    }

    final delta = _terminal.buffer.scrollBack - beforeScrollBack;
    if (!_isCountableAppendOnlyOutput(data) || delta <= 0) {
      _pendingLiveUpdateNotifier.value = const _PendingLiveUpdateState.updated();
      return;
    }

    final currentState = _pendingLiveUpdateNotifier.value;
    if (currentState.kind == _PendingLiveUpdateKind.updated) {
      return;
    }

    final currentCount = currentState.kind == _PendingLiveUpdateKind.lines
        ? currentState.lineCount
        : 0;
    _pendingLiveUpdateNotifier.value = _PendingLiveUpdateState.lines(
      currentCount + delta,
    );
  }

  void _clearPendingLiveUpdates() {
    if (_pendingLiveUpdateNotifier.value.kind ==
            _PendingLiveUpdateKind.none &&
        _pendingLiveUpdateNotifier.value.lineCount == 0) {
      return;
    }
    _pendingLiveUpdateNotifier.value = const _PendingLiveUpdateState.none();
  }

  bool _isCountableAppendOnlyOutput(String data) {
    for (var index = 0; index < data.length; index += 1) {
      final codeUnit = data.codeUnitAt(index);

      if (codeUnit == 0x08) {
        return false;
      }

      if (codeUnit == 0x0d) {
        final nextIsLineFeed =
            index + 1 < data.length && data.codeUnitAt(index + 1) == 0x0a;
        if (!nextIsLineFeed) {
          return false;
        }
        continue;
      }

      if (codeUnit != 0x1b) {
        continue;
      }

      if (index + 1 >= data.length || data.codeUnitAt(index + 1) != 0x5b) {
        return false;
      }

      var sequenceIndex = index + 2;
      while (sequenceIndex < data.length) {
        final sequenceCodeUnit = data.codeUnitAt(sequenceIndex);
        if (sequenceCodeUnit >= 0x40 && sequenceCodeUnit <= 0x7e) {
          if (sequenceCodeUnit != 0x6d) {
            return false;
          }
          index = sequenceIndex;
          break;
        }
        sequenceIndex += 1;
      }

      if (sequenceIndex >= data.length) {
        return false;
      }
    }

    return true;
  }

  void _preserveHistoryViewportAnchor(double pixels) {
    if (_isFollowingLiveTail) {
      return;
    }

    _pendingHistoryViewportAnchorPixels = pixels;
    if (_historyViewportAnchorScheduled) {
      return;
    }

    _historyViewportAnchorScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _historyViewportAnchorScheduled = false;

      if (!mounted || _isDisposed || _isFollowingLiveTail) {
        return;
      }

      final desiredPixels = _pendingHistoryViewportAnchorPixels;
      _pendingHistoryViewportAnchorPixels = null;
      if (desiredPixels == null || !_terminalScrollController.hasClients) {
        return;
      }

      final position = _terminalScrollController.position;
      final target = desiredPixels.clamp(
        position.minScrollExtent,
        position.maxScrollExtent,
      );
      if ((position.pixels - target).abs() > 0.5) {
        position.jumpTo(target);
      }
    });
  }

  void _resetTransientTerminalUiBeforeSwitch() {
    _clearPendingLiveUpdates();
    _isFollowingLiveTail = true;
  }

  void _prunePaneRenderCache() {
    final validPaneIds = <String>{};
    for (final session in ref.read(tmuxProvider).sessions) {
      for (final window in session.windows) {
        for (final pane in window.panes) {
          validPaneIds.add(pane.id);
        }
      }
    }
    _paneRenderCache.removeWhere((paneId, _) => !validPaneIds.contains(paneId));
  }

  /// Connect via SSH and set up tmux session
  Future<void> _connectAndSetup() async {
    if (!mounted || _isDisposed || _isConnecting) {
      return;
    }
    setState(() {
      _isConnecting = true;
      _connectionError = null;
    });

    try {
      // 1. Get connection info
      final connection = await ref
          .read(connectionsProvider.notifier)
          .getByIdWhenReady(
            widget.connectionId,
            timeout: _connectionLookupTimeout,
          );
      if (!mounted || _isDisposed) {
        return;
      }
      if (connection == null) {
        throw Exception('Connection not found');
      }

      // 2. Get authentication info
      final options = await _getAuthOptions(connection);
      if (!mounted || _isDisposed) {
        return;
      }

      // 3. SSH connection (no shell startup - exec only)
      final knownHostsNotifier = ref.read(knownHostsProvider.notifier);
      final verifiedOptions = options.copyWith(
        onVerifyHostKey: buildInteractiveVerifier(
          context: context,
          host: connection.host,
          port: connection.port,
          notifier: knownHostsNotifier,
        ),
      );
      final SshNotifier sshNotifier = ref.read(sshProvider.notifier);
      _sshNotifier ??= sshNotifier;
      await sshNotifier.connectWithoutShell(connection, verifiedOptions);
      if (!mounted || _isDisposed) {
        return;
      }

      // 4. Get the entire session tree
      await _refreshSessionTree();
      if (!mounted || _isDisposed) {
        return;
      }

      final tmuxState = ref.read(tmuxProvider);
      final sessions = tmuxState.sessions;

      // 5. Select or create a new session
      String sessionName;
      if (widget.sessionName != null) {
        // If session name is specified
        final existingIndex = sessions.indexWhere(
          (s) => s.name == widget.sessionName,
        );
        if (existingIndex >= 0) {
          // Connect to existing session
          sessionName = sessions[existingIndex].name;
        } else {
          // Create new session
          final sshClient = ref.read(sshProvider.notifier).client;
          await sshClient?.execPersistent(
            TmuxCommands.newSession(name: widget.sessionName!, detached: true),
          );
          if (!mounted || _isDisposed) return;
          await _refreshSessionTree();
          if (!mounted || _isDisposed) return;
          sessionName = widget.sessionName!;
        }
      } else if (sessions.isNotEmpty) {
        // If no session name specified, connect to the first session
        sessionName = sessions.first.name;
      } else {
        // If no sessions exist, create a new one with auto-generated name
        final sshClient = ref.read(sshProvider.notifier).client;
        sessionName = 'muxpod-${DateTime.now().millisecondsSinceEpoch}';
        await sshClient?.execPersistent(
          TmuxCommands.newSession(name: sessionName, detached: true),
        );
        if (!mounted || _isDisposed) return;
        await _refreshSessionTree();
        if (!mounted || _isDisposed) return;
      }

      // 6. Set active session/window/pane
      ref.read(tmuxProvider.notifier).setActiveSession(sessionName);

      // 6.1 Restore saved window/pane position
      if (widget.lastWindowIndex != null) {
        final tmuxState = ref.read(tmuxProvider);
        final session = tmuxState.activeSession;
        if (session != null) {
          // Check if the specified window exists
          final window = session.windows.firstWhere(
            (w) => w.index == widget.lastWindowIndex,
            orElse: () => session.windows.first,
          );
          ref.read(tmuxProvider.notifier).setActiveWindow(window.index);

          // Restore pane if pane ID is specified and exists
          if (widget.lastPaneId != null) {
            final pane = window.panes.firstWhere(
              (p) => p.id == widget.lastPaneId,
              orElse: () => window.panes.first,
            );
            ref.read(tmuxProvider.notifier).setActivePane(pane.id);
          }
        }
      }

      // 7. Notify TerminalDisplayProvider of pane info (for font size calculation)
      final activePane = ref.read(tmuxProvider).activePane;
      if (activePane != null) {
        ref.read(terminalDisplayProvider.notifier).updatePane(activePane);
        _viewNotifier.value = _viewNotifier.value.copyWith(
          paneWidth: activePane.width,
          paneHeight: activePane.height,
        );
      }

      // Clear any previously rendered body before the first resync of this
      // connect cycle so a stale pane cannot remain visible under the loading
      // overlay while the fresh snapshot is fetched.
      _showPlaceholderPane(activePane);

      await _restartTerminalStream(
        restartControlClient: true,
        refreshTree: false,
        reason: 'initial_connect',
      );
      _startConnectionStatsPolling();

      if (activePane != null) {
        // Send focus-in to pane (so apps like Claude Code can detect focus).
        await sshNotifier.client?.execPersistentInput(
          TmuxCommands.sendKeys(activePane.id, '\x1b[I', literal: true),
        );
      }

      if (!mounted) return;
      setState(() {
        _isConnecting = false;
      });
    } on SshHostKeyError catch (e) {
      _stopConnectionStatsPolling(resetValue: true);
      if (!mounted) return;
      setState(() {
        _isConnecting = false;
        _connectionError = e.message;
      });
    } catch (e) {
      _stopConnectionStatsPolling(resetValue: true);
      if (!mounted) return;
      setState(() {
        _isConnecting = false;
        _connectionError = e.toString();
      });
      _showErrorSnackBar(e.toString());
    }
  }

  /// Fetch and update the entire session tree.
  Future<void> _refreshSessionTree({
    bool syncActive = false,
    _TerminalLoadTrace? trace,
  }) async {
    if (_isDisposed) {
      return;
    }
    final sshClient = ref.read(sshProvider.notifier).client;
    if (sshClient == null || !sshClient.isConnected) {
      return;
    }

    try {
      final cmd = TmuxCommands.listAllPanes();
      final refreshStopwatch = trace == null ? null : (Stopwatch()..start());
      final output = await sshClient.execPersistent(cmd);
      refreshStopwatch?.stop();
      trace?.treeRefreshMs = refreshStopwatch?.elapsedMilliseconds;
      if (!mounted || _isDisposed) return;
      ref.read(tmuxProvider.notifier).parseAndUpdateFullTree(output);
      _prunePaneRenderCache();
      if (syncActive) {
        _syncActiveTmuxStateFromTree();
      }
    } catch (_) {
      // Silently ignore tree update errors.
    }
  }

  void _syncActiveTmuxStateFromTree() {
    final tmuxState = ref.read(tmuxProvider);
    final sessionName = tmuxState.activeSessionName;
    if (sessionName == null) {
      return;
    }

    ref.read(tmuxProvider.notifier).setActiveSession(sessionName);

    final activePane = ref.read(tmuxProvider).activePane;
    if (activePane != null) {
      ref.read(terminalDisplayProvider.notifier).updatePane(activePane);
      _viewNotifier.value = _viewNotifier.value.copyWith(
        paneWidth: activePane.width,
        paneHeight: activePane.height,
      );
    }
  }

  void _scheduleControlSync({
    bool refreshTree = true,
    bool resyncPane = false,
  }) {
    _shouldRefreshTreeAfterControlSync =
        _shouldRefreshTreeAfterControlSync || refreshTree;
    _shouldResyncAfterControlRefresh =
        _shouldResyncAfterControlRefresh || resyncPane;
    _controlSyncTimer?.cancel();
    _controlSyncTimer = Timer(const Duration(milliseconds: 120), () async {
      if (!mounted || _isDisposed) {
        return;
      }

      final previousActivePane = ref.read(tmuxProvider).activePane;
      final shouldRefreshTree = _shouldRefreshTreeAfterControlSync;
      final shouldResync = _shouldResyncAfterControlRefresh;
      _shouldRefreshTreeAfterControlSync = false;
      _shouldResyncAfterControlRefresh = false;
      if (shouldRefreshTree) {
        await _refreshSessionTree(syncActive: true);
      }
      final nextActivePane = ref.read(tmuxProvider).activePane;
      final shouldApplyResync =
          shouldResync &&
          _shouldResyncPaneAfterControlSync(
            previousActivePane: previousActivePane,
            nextActivePane: nextActivePane,
          );
      if (shouldApplyResync) {
        await _resyncActivePane(
          refreshTree: false,
          reason: 'control_notification',
        );
      }
    });
  }

  bool _shouldResyncPaneAfterControlSync({
    required TmuxPane? previousActivePane,
    required TmuxPane? nextActivePane,
  }) {
    if (nextActivePane == null) {
      return false;
    }

    if (previousActivePane == null) {
      return true;
    }

    return previousActivePane.id != nextActivePane.id ||
        previousActivePane.width != nextActivePane.width ||
        previousActivePane.height != nextActivePane.height;
  }

  void _cancelControlClientRestart({bool resetAttempts = false}) {
    _controlRestartTimer?.cancel();
    _controlRestartTimer = null;
    if (resetAttempts) {
      _controlRestartAttempt = 0;
    }
  }

  Duration _nextControlRestartDelay() {
    var delayMs = _initialControlRestartDelay.inMilliseconds;
    for (var attempt = 0; attempt < _controlRestartAttempt; attempt++) {
      delayMs *= 2;
      if (delayMs >= _maxControlRestartDelay.inMilliseconds) {
        delayMs = _maxControlRestartDelay.inMilliseconds;
        break;
      }
    }
    return Duration(milliseconds: delayMs);
  }

  void _scheduleControlClientRestart() {
    if (_isDisposed || _isInBackground || _controlRestartTimer != null) {
      return;
    }

    final sshState = ref.read(sshProvider);
    if (!sshState.isConnected) {
      if (!sshState.isReconnecting) {
        unawaited(_attemptReconnect());
      }
      return;
    }

    final delay = _nextControlRestartDelay();
    _controlRestartAttempt += 1;
    _controlRestartTimer = Timer(delay, () async {
      _controlRestartTimer = null;
      if (!mounted || _isDisposed || _isInBackground) {
        return;
      }
      await _restartTerminalStream(
        restartControlClient: true,
        reason: 'control_restart',
      );
    });
  }

  Future<void> _startControlClient(String sessionName) async {
    if (_isDisposed || _isInBackground) {
      return;
    }
    if (_controlClient != null &&
        _controlClientSessionName == sessionName &&
        _controlClient!.isStarted) {
      return;
    }

    _cancelControlClientRestart();
    await _stopControlClient();

    final sshClient = ref.read(sshProvider.notifier).client;
    if (sshClient == null || !sshClient.isConnected) {
      return;
    }

    final activePane = ref.read(tmuxProvider).activePane;
    final cols = activePane?.width ?? _viewNotifier.value.paneWidth;
    final rows = activePane?.height ?? _viewNotifier.value.paneHeight;

    final controlClient = TmuxControlClient(
      sshClient,
      onPaneOutput: _handleControlPaneOutput,
      onNotification: _handleControlNotification,
      onError: _handleControlClientError,
      onClosed: _handleControlClientClosed,
    );

    try {
      await controlClient.start(
        sessionName: sessionName,
        cols: cols > 0 ? cols : 200,
        rows: rows > 0 ? rows : 50,
      );
      _controlClient = controlClient;
      _controlClientSessionName = sessionName;
      _cancelControlClientRestart(resetAttempts: true);
    } catch (_) {
      await controlClient.dispose();
      _controlClient = null;
      _controlClientSessionName = null;
      _scheduleControlClientRestart();
    }
  }

  Future<void> _stopControlClient({bool resetRestartState = false}) async {
    _controlSyncTimer?.cancel();
    _controlSyncTimer = null;
    _shouldRefreshTreeAfterControlSync = false;
    _shouldResyncAfterControlRefresh = false;
    _pendingFirstLiveOutputPaneId = null;
    _pendingFirstLiveOutputStartedAt = null;
    _scrollbackBackfillToken += 1;
    _cancelControlClientRestart(resetAttempts: resetRestartState);
    final controlClient = _controlClient;
    _controlClient = null;
    _controlClientSessionName = null;
    await controlClient?.dispose();
  }

  Future<void> _restartTerminalStream({
    bool restartControlClient = false,
    bool refreshTree = true,
    String reason = 'resync',
  }) async {
    if (_isDisposed || _isInBackground) {
      return;
    }

    final sessionName = ref.read(tmuxProvider).activeSessionName;
    if (sessionName == null) {
      await _stopControlClient(resetRestartState: true);
      return;
    }

    final shouldRestartControlClient =
        restartControlClient ||
        _controlClientSessionName != sessionName ||
        _controlClient == null ||
        !_controlClient!.isStarted;
    final trace = _shouldCollectTerminalPerfMetrics
        ? _TerminalLoadTrace(
            reason: reason,
            refreshTree: refreshTree,
            restartedControlClient: shouldRestartControlClient,
          )
        : null;

    if (shouldRestartControlClient) {
      await _stopControlClient();
    }

    try {
      if (shouldRestartControlClient) {
        _pauseControlOutputUntilResyncComplete = true;
        _setLoadingStage('Starting tmux live stream…');
        final controlStartStopwatch = trace == null
            ? null
            : (Stopwatch()..start());
        await _startControlClient(sessionName);
        controlStartStopwatch?.stop();
        trace?.controlStartMs = controlStartStopwatch?.elapsedMilliseconds;
        if (!mounted || _isDisposed) {
          return;
        }
      }

      await _resyncActivePane(
        refreshTree: refreshTree,
        reason: reason,
        trace: trace,
      );
    } finally {
      if (shouldRestartControlClient) {
        _pauseControlOutputUntilResyncComplete = false;
        _flushDeferredStreamOutput();
      }
      _setLoadingStage(null);
    }
  }

  void _handleControlPaneOutput(String paneId, String data) {
    if (!mounted || _isDisposed || data.isEmpty) {
      return;
    }

    final tmuxState = ref.read(tmuxProvider);
    final activePaneId = tmuxState.activePaneId;
    if (activePaneId != paneId) {
      // Check for bell character in output from non-active panes,
      // but not during pane/window switches or resyncs (which replay
      // buffered output that may contain stale bell characters).
      if (!_isSwitchingPane &&
          !_isResyncingPane &&
          !_pauseControlOutputUntilResyncComplete &&
          data.contains('\x07')) {
        _handleBellFromPane(paneId, tmuxState);
      }
      return;
    }

    if (_terminalMode == TerminalMode.select ||
        _isResyncingPane ||
        _pauseControlOutputUntilResyncComplete) {
      _deferredStreamOutput.write(data);
      return;
    }

    _recordFirstLiveOutputIfNeeded(paneId);
    final scrollBackBeforeWrite = _terminal.buffer.scrollBack;
    final paneViewState = _paneTerminalViewKey.currentState;
    final shouldAutoScroll = paneViewState?.shouldAutoFollow ?? true;
    final shouldPreserveHistoryViewport =
        !shouldAutoScroll && !(paneViewState?.isUserScrollInProgress ?? false);
    final historyViewportPixels = shouldPreserveHistoryViewport &&
            _terminalScrollController.hasClients
        ? _terminalScrollController.position.pixels
        : null;
    _terminal.write(data);
    _recordPendingLiveUpdate(data: data, beforeScrollBack: scrollBackBeforeWrite);
    if ((shouldAutoScroll || !_hasInitialScrolled) &&
        !_terminal.isInSynchronizedUpdate) {
      _hasInitialScrolled = true;
      _paneTerminalViewKey.currentState?.scrollToBottom();
    } else if (historyViewportPixels != null) {
      _preserveHistoryViewportAnchor(historyViewportPixels);
    }
  }

  void _handleControlNotification(TmuxControlNotification notification) {
    if (!mounted || _isDisposed) {
      return;
    }

    switch (notification.name) {
      case 'layout-change':
        _scheduleControlSync(refreshTree: true, resyncPane: true);
        break;
      case 'pane-mode-changed':
        // For interactive TUIs, tmux often emits enough live output for the
        // screen to converge naturally. A snapshot-based resync here tends to
        // create duplicate bottom rows more often than it helps.
        break;
      case 'session-changed':
      case 'session-window-changed':
      case 'window-close':
      case 'window-pane-changed':
        _scheduleControlSync(refreshTree: true, resyncPane: true);
        break;
      case 'sessions-changed':
      case 'unlinked-window-add':
      case 'unlinked-window-close':
      case 'window-add':
      case 'window-renamed':
        _scheduleControlSync(refreshTree: true);
        break;
      case 'exit':
        _handleControlClientClosed();
        break;
    }
  }

  /// Handle a bell character received from a non-active pane.
  ///
  /// Shows a SnackBar prompting the user to switch to the window that
  /// triggered the bell.
  void _handleBellFromPane(String paneId, TmuxState tmuxState) {
    // Find which window contains this pane
    final session = tmuxState.activeSession;
    if (session == null) return;

    TmuxWindow? bellWindow;
    for (final window in session.windows) {
      for (final pane in window.panes) {
        if (pane.id == paneId) {
          bellWindow = window;
          break;
        }
      }
      if (bellWindow != null) break;
    }
    if (bellWindow == null) return;

    // Don't show duplicate notifications for the same window within 10s
    final now = DateTime.now();
    if (_lastBellWindowIndex == bellWindow.index &&
        _lastBellTime != null &&
        now.difference(_lastBellTime!).inSeconds < 10) {
      return;
    }
    _lastBellWindowIndex = bellWindow.index;
    _lastBellTime = now;

    // Refresh tree to pick up the bell flag
    _scheduleControlSync(refreshTree: true);

    if (!mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          'Bell in window ${bellWindow.index}: ${bellWindow.name}',
        ),
        action: SnackBarAction(
          label: 'Go',
          textColor: Colors.white,
          onPressed: () {
            messenger.hideCurrentSnackBar();
            _selectWindow(session.name, bellWindow!.index);
          },
        ),
        dismissDirection: DismissDirection.horizontal,
        showCloseIcon: true,
        closeIconColor: Colors.white,
        duration: const Duration(seconds: 5),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  void _handleControlClientError(Object error) {
    if (_isDisposed || _isInBackground) {
      return;
    }
    _scheduleControlClientRestart();
  }

  void _handleControlClientClosed() {
    if (_isDisposed || _isInBackground) {
      return;
    }
    _scheduleControlClientRestart();
  }

  void _flushDeferredStreamOutput() {
    if (_deferredStreamOutput.isEmpty ||
        _terminalMode == TerminalMode.select ||
        _isResyncingPane ||
        _pauseControlOutputUntilResyncComplete) {
      return;
    }

    final bufferedOutput = _deferredStreamOutput.takeAll();
    final activePaneId = ref.read(tmuxProvider).activePaneId;
    if (activePaneId != null) {
      _recordFirstLiveOutputIfNeeded(activePaneId);
    }
    final scrollBackBeforeWrite = _terminal.buffer.scrollBack;
    final paneViewState = _paneTerminalViewKey.currentState;
    final shouldAutoScroll = paneViewState?.shouldAutoFollow ?? true;
    final shouldPreserveHistoryViewport =
        !shouldAutoScroll && !(paneViewState?.isUserScrollInProgress ?? false);
    final historyViewportPixels = shouldPreserveHistoryViewport &&
            _terminalScrollController.hasClients
        ? _terminalScrollController.position.pixels
        : null;
    _terminal.write(bufferedOutput);
    _recordPendingLiveUpdate(
      data: bufferedOutput,
      beforeScrollBack: scrollBackBeforeWrite,
    );
    if (shouldAutoScroll && !_terminal.isInSynchronizedUpdate) {
      _paneTerminalViewKey.currentState?.scrollToBottom();
    } else if (historyViewportPixels != null) {
      _preserveHistoryViewportAnchor(historyViewportPixels);
    }
  }

  String _buildPaneSnapshotCommand(
    String paneId, {
    bool includeScrollback = true,
  }) {
    final alternateOnCommand = TmuxCommands.getPaneAlternateOn(paneId);
    final metadataCommand = TmuxCommands.getPaneSnapshotMetadata(paneId);
    final mainSnapshotCommand = TmuxCommands.capturePane(
      paneId,
      escapeSequences: true,
      preserveTrailingSpaces: true,
      // Preserve physical rows exactly as tmux displays them. Joining wrapped
      // lines loses row boundaries in TUIs with long bottom prompts, and later
      // incremental redraws then target the wrong rows.
      joinWrappedLines: false,
      startLine: includeScrollback && _terminalScrollbackLines > 0
          ? -_terminalScrollbackLines
          : null,
    );
    final alternateSnapshotCommand = TmuxCommands.capturePane(
      paneId,
      escapeSequences: true,
      alternateScreen: true,
      preserveTrailingSpaces: true,
      quiet: true,
    );

    return '''
__muxpod_alt=\$($alternateOnCommand);
if [ "\$__muxpod_alt" = "1" ]; then
  printf '\\001__MUXPOD_MAIN__\\001\n';
  $mainSnapshotCommand;
  printf '\\001__MUXPOD_ALT__\\001\n';
  $alternateSnapshotCommand;
else
  $mainSnapshotCommand;
fi;
printf '\\001__MUXPOD_META__\\001';
$metadataCommand
''';
  }

  String _buildPaneScrollbackBackfillCommand(String paneId) {
    return TmuxCommands.capturePane(
      paneId,
      escapeSequences: true,
      preserveTrailingSpaces: true,
      joinWrappedLines: false,
      startLine: _terminalScrollbackLines > 0
          ? -_terminalScrollbackLines
          : null,
    );
  }

  _PaneSnapshotPayload _parseSnapshotPayload(String combinedOutput) {
    final metadataIndex = combinedOutput.lastIndexOf(_snapshotMetadataMarker);
    if (metadataIndex == -1) {
      final snapshot = _trimSingleTrailingNewline(combinedOutput);
      return _PaneSnapshotPayload(
        activeContent: snapshot,
        mainContent: snapshot,
        metadata: '',
      );
    }

    final body = combinedOutput.substring(0, metadataIndex);
    final metadata = combinedOutput
        .substring(metadataIndex + _snapshotMetadataMarker.length)
        .trim();
    final trimmedBody = _trimSingleTrailingNewline(body);
    final mainMarkerIndex = trimmedBody.indexOf(_snapshotMainMarker);
    final altMarkerIndex = trimmedBody.indexOf(_snapshotAltMarker);

    if (mainMarkerIndex != -1 &&
        altMarkerIndex != -1 &&
        mainMarkerIndex < altMarkerIndex) {
      final mainContent = _trimSingleTrailingNewline(
        trimmedBody.substring(
          mainMarkerIndex + _snapshotMainMarker.length,
          altMarkerIndex,
        ),
      );
      final activeContent = _trimSingleTrailingNewline(
        trimmedBody.substring(altMarkerIndex + _snapshotAltMarker.length),
      );
      return _PaneSnapshotPayload(
        activeContent: activeContent,
        mainContent: mainContent,
        metadata: metadata,
      );
    }

    final snapshot = _trimSingleTrailingNewline(trimmedBody);
    return _PaneSnapshotPayload(
      activeContent: snapshot,
      mainContent: snapshot,
      metadata: metadata,
    );
  }

  String _trimSingleTrailingNewline(String value) {
    if (value.endsWith('\n')) {
      return value.substring(0, value.length - 1);
    }
    return value;
  }

  Future<void> _scheduleScrollbackBackfill({
    required String paneId,
    required TerminalSnapshotFrame visibleFrame,
    required Terminal targetTerminal,
  }) async {
    if (visibleFrame.alternateScreen ||
        _terminalScrollbackLines <= visibleFrame.paneHeight) {
      return;
    }

    final sshClient = ref.read(sshProvider.notifier).client;
    if (sshClient == null || !sshClient.isConnected) {
      return;
    }

    final token = ++_scrollbackBackfillToken;
    final fetchStopwatch = _shouldCollectTerminalPerfMetrics
        ? (Stopwatch()..start())
        : null;

    try {
      final fullMainContent = _trimSingleTrailingNewline(
        await sshClient.execDirect(
          _buildPaneScrollbackBackfillCommand(paneId),
          timeout: const Duration(seconds: 2),
        ),
      );
      fetchStopwatch?.stop();

      if (!mounted || _isDisposed || token != _scrollbackBackfillToken) {
        return;
      }

      final activePaneId = ref.read(tmuxProvider).activePaneId;
      final cacheEntry = _paneRenderCache[paneId];
      final targetStillRelevant =
          identical(_terminal, targetTerminal) ||
          activePaneId == paneId ||
          (cacheEntry != null && identical(cacheEntry.terminal, targetTerminal));
      if (!targetStillRelevant) {
        return;
      }

      final scratchFrame = visibleFrame.copyWith(
        content: fullMainContent,
        mainContent: fullMainContent,
        alternateScreen: false,
      );
      final scratchTerminal = createTerminalFromSnapshot(
        frame: scratchFrame,
        maxLines: _terminalScrollbackLines,
        showCursor: ref.read(settingsProvider).showTerminalCursor,
        onOutput: (_) {},
        controller: TerminalController(),
      );

      final applied = prependTerminalScrollback(
        terminal: targetTerminal,
        fullSnapshotLines: scratchTerminal.mainBuffer.lines.toList(),
      );
      if (!applied) {
        return;
      }

      final currentViewportState =
          activePaneId == paneId
          ? (_paneTerminalViewKey.currentState?.captureViewportState() ??
                const PaneTerminalViewportState())
          : (cacheEntry?.viewportState ?? const PaneTerminalViewportState());
      final updatedFrame = _cacheFrameForTerminalInstance(
        targetTerminal,
        fallbackFrame: visibleFrame.copyWith(mainContent: fullMainContent),
      );
      if (activePaneId == paneId) {
        _paneRenderCache[paneId] = _PaneRenderCacheEntry(
          terminal: targetTerminal..onOutput = _handleTerminalOutput,
          frame: updatedFrame,
          viewportState: currentViewportState,
          capturedAt: DateTime.now(),
        );
        if (_paneTerminalViewKey.currentState?.shouldAutoFollow ?? false) {
          _paneTerminalViewKey.currentState?.scrollToBottom();
        }
      } else if (cacheEntry != null) {
        _paneRenderCache[paneId] = cacheEntry.copyWith(
          frame: updatedFrame,
          capturedAt: DateTime.now(),
        );
      }

      if (_shouldCollectTerminalPerfMetrics) {
        debugPrint(
          '[TerminalBackfill] pane=$paneId fetch ${fetchStopwatch?.elapsedMilliseconds ?? 0}ms · '
          '${(utf8.encode(fullMainContent).length / 1024).toStringAsFixed(1)}KB · '
          '${_countTextLines(fullMainContent)} lines',
        );
      }
    } catch (_) {
      fetchStopwatch?.stop();
    }
  }

  bool _parseTmuxFlag(String? value, {required bool fallback}) {
    if (value == null) {
      return fallback;
    }

    switch (value) {
      case '1':
        return true;
      case '0':
        return false;
      default:
        return fallback;
    }
  }

  Future<void> _resyncActivePane({
    bool refreshTree = true,
    String reason = 'resync',
    _TerminalLoadTrace? trace,
  }) async {
    if (_isDisposed || _isResyncingPane) {
      return;
    }

    final sshClient = ref.read(sshProvider.notifier).client;
    if (sshClient == null || !sshClient.isConnected) {
      return;
    }

    final activeTrace =
        trace ??
        (_shouldCollectTerminalPerfMetrics
            ? _TerminalLoadTrace(
                reason: reason,
                refreshTree: refreshTree,
                restartedControlClient: false,
              )
            : null);
    var snapshotApplied = false;
    TerminalSnapshotFrame? visibleFrameForBackfill;
    String? visiblePaneIdForBackfill;
    Terminal? targetTerminalForBackfill;

    try {
      _isResyncingPane = true;
      _scrollbackBackfillToken += 1;

      if (refreshTree) {
        _setLoadingStage('Refreshing tmux state…');
        await _refreshSessionTree(syncActive: true, trace: activeTrace);
      }
      if (!mounted || _isDisposed) {
        return;
      }

      final activePane = ref.read(tmuxProvider).activePane;
      if (activePane == null) {
        final emptyView = _viewNotifier.value.copyWith(
          content: '',
          mainContent: '',
          alternateScreen: false,
        );
        _applyTerminalFrame(emptyView);
        _viewNotifier.value = emptyView;
        _hasInitialScrolled = false;
        return;
      }

      final snapshotCommand = _buildPaneSnapshotCommand(
        activePane.id,
        includeScrollback: false,
      );

      _setLoadingStage('Capturing pane…');
      final startTime = DateTime.now();
      final combinedOutput = await sshClient.execDirect(
        snapshotCommand,
        timeout: const Duration(seconds: 2),
      );
      final latency = DateTime.now().difference(startTime).inMilliseconds;
      activeTrace?.snapshotFetchMs = latency;
      if (!_isDisposed) {
        _recordLatencySample(latency);
      }

      if (!mounted || _isDisposed) {
        return;
      }

      if (activeTrace != null) {
        activeTrace.snapshotPayloadBytes = utf8.encode(combinedOutput).length;
        activeTrace.snapshotPayloadLines = _countTextLines(combinedOutput);
      }

      final parseStopwatch = activeTrace == null ? null : (Stopwatch()..start());
      final snapshotPayload = _parseSnapshotPayload(combinedOutput);
      parseStopwatch?.stop();
      activeTrace?.snapshotParseMs = parseStopwatch?.elapsedMilliseconds;

      var nextView = _viewNotifier.value.copyWith(
        content: snapshotPayload.activeContent,
        mainContent: snapshotPayload.mainContent,
        alternateScreen: false,
        paneWidth: activePane.width,
        paneHeight: activePane.height,
        cursorX: activePane.cursorX,
        cursorY: activePane.cursorY,
      );

      final metadataParts = snapshotPayload.metadata.split(',');
      if (metadataParts.length >= 5) {
        final alternateScreen = metadataParts[0] == '1';
        final x = int.tryParse(metadataParts[1]);
        final y = int.tryParse(metadataParts[2]);
        final w = int.tryParse(metadataParts[3]);
        final h = int.tryParse(metadataParts[4]);
        final insertMode = _parseTmuxFlag(
          metadataParts.length > 5 ? metadataParts[5] : null,
          fallback: nextView.insertMode,
        );
        final cursorKeysMode = _parseTmuxFlag(
          metadataParts.length > 6 ? metadataParts[6] : null,
          fallback: nextView.cursorKeysMode,
        );
        final appKeypadMode = _parseTmuxFlag(
          metadataParts.length > 7 ? metadataParts[7] : null,
          fallback: nextView.appKeypadMode,
        );
        final pendingWrap = _parseTmuxFlag(
          metadataParts.length > 8 ? metadataParts[8] : null,
          fallback: nextView.pendingWrap,
        );
        final cursorVisible = _parseTmuxFlag(
          metadataParts.length > 9 ? metadataParts[9] : null,
          fallback: nextView.cursorVisible,
        );
        final originMode = _parseTmuxFlag(
          metadataParts.length > 10 ? metadataParts[10] : null,
          fallback: nextView.originMode,
        );
        final scrollRegionUpper = metadataParts.length > 11
            ? int.tryParse(metadataParts[11])
            : null;
        final scrollRegionLower = metadataParts.length > 12
            ? int.tryParse(metadataParts[12])
            : null;

        nextView = nextView.copyWith(
          alternateScreen: alternateScreen,
          insertMode: insertMode,
          cursorKeysMode: cursorKeysMode,
          appKeypadMode: appKeypadMode,
          autoWrapMode: nextView.autoWrapMode,
          pendingWrap: pendingWrap,
          cursorVisible: cursorVisible,
          originMode: originMode,
          scrollRegionUpper: scrollRegionUpper,
          scrollRegionLower: scrollRegionLower,
        );

        if (w != null && h != null) {
          nextView = nextView.copyWith(paneWidth: w, paneHeight: h);
          ref
              .read(terminalDisplayProvider.notifier)
              .updatePane(activePane.copyWith(width: w, height: h));
        }

        if (x != null && y != null) {
          ref
              .read(tmuxProvider.notifier)
              .updateCursorPosition(activePane.id, x, y);
          nextView = nextView.copyWith(cursorX: x, cursorY: y);
        }
      }

      _setLoadingStage('Rendering terminal…');
      final applyStopwatch = activeTrace == null ? null : (Stopwatch()..start());
      _applyResyncUpdate(nextView);
      applyStopwatch?.stop();
      activeTrace?.terminalApplyMs = applyStopwatch?.elapsedMilliseconds;
      snapshotApplied = true;
      _armFirstLiveOutputProbe(activePane.id);
      visibleFrameForBackfill = nextView;
      visiblePaneIdForBackfill = activePane.id;
      targetTerminalForBackfill = _terminal;

      // Post-snapshot ordering fence: send a no-op through the control
      // mode channel (same stream as %output).  We awaited the snapshot
      // response before sending this, so tmux processes the fence at
      // Tf > Ts (snapshot time).  By the time the fence response arrives,
      // all %output generated before Tf has been delivered.  Clearing
      // after a successful fence drops pre-snapshot duplicates.
      //
      // Bounded-loss tradeoff: output produced between Ts and Tf (one
      // RTT) is NOT in the snapshot but IS cleared by the fence.  This
      // is an intentional trade — losing at most one RTT of output
      // avoids the corruption caused by double-applying duplicates.
      // For append-only streams the gap is visible until the next
      // %output arrives; for interactive programs the next keypress
      // triggers a refresh.
      //
      // If the fence fails (timeout / session closed), skip the clear:
      // the deferred buffer may contain duplicates, but flushing
      // duplicates is less harmful than silently losing genuinely new
      // output.
      final controlClient = _controlClient;
      if (controlClient != null && controlClient.isStarted) {
        try {
          await controlClient.sendCommand(
            'display-message -p ""',
            timeout: const Duration(seconds: 1),
          );
          // Fence succeeded — all pre-Tf output delivered; safe to clear.
          _deferredStreamOutput.clear();
        } catch (_) {
          // Fence failed — skip clear to avoid losing post-snapshot output.
        }
      }
    } catch (_) {
      final currentState = ref.read(sshProvider);
      if (!currentState.isReconnecting) {
        unawaited(_attemptReconnect());
      }
    } finally {
      _isResyncingPane = false;
      if (activeTrace != null) {
        _recordLoadMetrics(activeTrace.finish(snapshotApplied: snapshotApplied));
      }
      _setLoadingStage(null);
      // Flush any remaining deferred output.  Three scenarios:
      //  1. Snapshot applied + fence succeeded: buffer was cleared after
      //     the fence, so only genuinely post-snapshot output remains.
      //  2. Snapshot applied + fence failed: buffer may contain a mix of
      //     pre-/post-snapshot output — duplicates are preferable to loss.
      //  3. Snapshot never applied (error path): all output since resync
      //     start is still in the buffer and must be flushed to avoid
      //     silent data loss.
      _flushDeferredStreamOutput();
    }

    if (snapshotApplied &&
        visibleFrameForBackfill != null &&
        visiblePaneIdForBackfill != null &&
        targetTerminalForBackfill != null) {
      unawaited(
        _scheduleScrollbackBackfill(
          paneId: visiblePaneIdForBackfill,
          visibleFrame: visibleFrameForBackfill,
          targetTerminal: targetTerminalForBackfill,
        ),
      );
    }
  }

  void _applyResyncUpdate(TerminalSnapshotFrame viewData) {
    _pendingViewData = viewData;
    _applyUpdate();
  }

  /// Apply pending update
  void _applyUpdate() {
    if (!mounted || _isDisposed) return;
    final shouldAutoScroll =
        _paneTerminalViewKey.currentState?.shouldAutoFollow ??
        !_hasInitialScrolled;
    _applyTerminalFrame(_pendingViewData);
    _viewNotifier.value = _pendingViewData;
    final activePaneId = ref.read(tmuxProvider).activePaneId;
    if (activePaneId != null) {
      _cachePaneRenderState(
        paneId: activePaneId,
        viewportState:
            _paneTerminalViewKey.currentState?.captureViewportState() ??
            const PaneTerminalViewportState(),
      );
    }
    if (_terminalMode == TerminalMode.normal && shouldAutoScroll) {
      _paneTerminalViewKey.currentState?.scrollToBottom();
    }

    // Scroll to bottom on first content received
    if (!_hasInitialScrolled && _pendingViewData.content.isNotEmpty) {
      _hasInitialScrolled = true;
      _paneTerminalViewKey.currentState?.scrollToBottom();
    }
  }

  void _applyTerminalFrame(TerminalSnapshotFrame viewData) {
    _terminal = createTerminalFromSnapshot(
      frame: viewData,
      maxLines: _terminalScrollbackLines,
      showCursor: ref.read(settingsProvider).showTerminalCursor,
      onOutput: _handleTerminalOutput,
      controller: _terminalController,
    );
  }

  void _handleTerminalOutput(String data) {
    if (_terminalMode != TerminalMode.normal) {
      return;
    }

    _ensureTerminalViewportAtBottomForInput();
    final modifiers = _consumePendingKeyboardModifiers();
    final output = modifiers == null
        ? data
        : XtermInputAdapter.encodeOutputWithModifiers(
                data,
                shift: modifiers.shift,
                ctrl: modifiers.ctrl,
                alt: modifiers.alt,
              ) ??
              data;

    unawaited(_sendTerminalData(normalizeTerminalOutput(output)));
  }

  /// Attempt auto-reconnection
  Future<void> _attemptReconnect() async {
    if (_isDisposed) return;

    final sshNotifier = ref.read(sshProvider.notifier);
    final success = await sshNotifier.reconnect();

    if (!mounted || _isDisposed) return;

    if (!success) {
      // Retry on reconnection failure (until max attempts reached)
      final currentState = ref.read(sshProvider);
      if (currentState.reconnectAttempt < 5) {
        // Will be retried on the next reconnect attempt.
      }
    }
  }

  /// Get authentication options
  Future<SshConnectOptions> _getAuthOptions(Connection connection) async {
    if (connection.authMethod == 'key' && connection.keyId != null) {
      final privateKey = await _secureStorage.getPrivateKey(connection.keyId!);
      final passphrase = await _secureStorage.getPassphrase(connection.keyId!);
      return SshConnectOptions(privateKey: privateKey, passphrase: passphrase);
    } else {
      final password = await _secureStorage.getPassword(connection.id);
      return SshConnectOptions(password: password);
    }
  }

  void _showTerminalSnackBar(
    String message, {
    Color? backgroundColor,
    SnackBarAction? action,
  }) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: backgroundColor,
        action: action,
      ),
    );
  }

  /// Show error SnackBar
  void _showErrorSnackBar(String message) {
    _showTerminalSnackBar(
      message,
      backgroundColor: Colors.red,
      action: SnackBarAction(
        label: 'Retry',
        textColor: Colors.white,
        onPressed: _connectAndSetup,
      ),
    );
  }

  Future<T> _runWithTerminalProgressDialog<T>({
    required String title,
    required String message,
    required Future<T> Function() task,
  }) async {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return AlertDialog(
          backgroundColor: isDark
              ? DesignColors.surfaceDark
              : DesignColors.surfaceLight,
          title: Text(
            title,
            style: TextStyle(color: isDark ? Colors.white : Colors.black87),
          ),
          content: Row(
            children: [
              const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Text(
                  message,
                  style: TextStyle(
                    color: isDark ? Colors.white70 : Colors.black54,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );

    try {
      return await task();
    } finally {
      if (mounted) {
        unawaited(Navigator.of(context, rootNavigator: true).maybePop());
      }
    }
  }

  Future<void> _attachImageFromDevice() async {
    final sshClient = ref.read(sshProvider.notifier).client;
    final target = ref.read(tmuxProvider.notifier).currentTarget;

    if (sshClient == null || !sshClient.isConnected || target == null) {
      _showTerminalSnackBar(
        'Connect to a pane before attaching an image.',
        backgroundColor: Colors.orange.shade700,
      );
      return;
    }

    FilePickerResult? result;
    try {
      result = await FilePicker.platform.pickFiles(
        type: FileType.image,
        allowMultiple: false,
        withData: true,
      );
    } catch (error) {
      if (mounted) {
        _showTerminalSnackBar(
          'Failed to open image picker: $error',
          backgroundColor: Colors.red,
        );
      }
      return;
    }

    if (result == null || result.files.isEmpty) {
      return;
    }

    final pickedFile = result.files.single;
    if (pickedFile.size <= 0) {
      _showTerminalSnackBar(
        'Selected image is empty.',
        backgroundColor: Colors.orange.shade700,
      );
      return;
    }
    if (pickedFile.size > terminalImageAttachmentMaxBytes) {
      final maxMiB = terminalImageAttachmentMaxBytes ~/ (1024 * 1024);
      _showTerminalSnackBar(
        'Selected image is larger than $maxMiB MB.',
        backgroundColor: Colors.orange.shade700,
      );
      return;
    }

    try {
      final imageBytes =
          pickedFile.bytes ??
          (pickedFile.path != null
              ? await File(pickedFile.path!).readAsBytes()
              : null);
      if (imageBytes == null || imageBytes.isEmpty) {
        _showTerminalSnackBar(
          'Could not read the selected image.',
          backgroundColor: Colors.orange.shade700,
        );
        return;
      }

      final remotePath = await _runWithTerminalProgressDialog(
        title: 'Uploading Image',
        message: 'Sending ${pickedFile.name} to the remote host…',
        task: () => sshClient.uploadTerminalImageAttachment(
          imageBytes,
          originalFilename: pickedFile.name,
        ),
      );

      if (!mounted || _isDisposed) {
        return;
      }

      if (_terminalMode != TerminalMode.normal) {
        setState(() {
          _terminalMode = TerminalMode.normal;
        });
        _terminalController.clearSelection();
        _flushDeferredStreamOutput();
      }

      _ensureTerminalViewportAtBottomForInput();
      XtermInputAdapter.sendPaste(_terminal, remotePath);
      _showTerminalSnackBar(
        'Image uploaded. Remote path pasted into the terminal.',
        backgroundColor: Colors.green.shade700,
      );
    } catch (error) {
      if (mounted) {
        _showTerminalSnackBar(
          'Failed to attach image: $error',
          backgroundColor: Colors.red,
        );
      }
    }
  }

  @override
  void dispose() {
    // First set _isDisposed to stop async operations
    _isDisposed = true;
    WidgetsBinding.instance.removeObserver(this);
    // Disable WakeLock
    WakelockPlus.disable();
    // Clear reconnection success callback
    _sshNotifier?.onReconnectSuccess = null;
    _sshNotifier = null;
    // Cancel Riverpod subscriptions
    _sshSubscription?.close();
    _sshSubscription = null;
    _tmuxSubscription?.close();
    _tmuxSubscription = null;
    _settingsSubscription?.close();
    _settingsSubscription = null;
    _networkSubscription?.close();
    _networkSubscription = null;
    _controlSyncTimer?.cancel();
    _controlSyncTimer = null;
    _stopConnectionStatsPolling();
    unawaited(_stopControlClient(resetRestartState: true));
    // Dispose ValueNotifier
    _viewNotifier.dispose();
    _latencyNotifier.dispose();
    _bandwidthNotifier.dispose();
    _pendingLiveUpdateNotifier.dispose();
    // Dispose scroll controller
    _terminalScrollController.dispose();
    _terminalController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Use local state (do not use ref.watch)
    // Note: tmuxProvider is obtained via ref.watch within each Consumer.
    // This keeps high-frequency terminal output out of the parent build path.
    final sshState = _sshState;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final keyboardInset = MediaQuery.of(context).viewInsets.bottom;
    final keyboardVisible = keyboardInset > 0;

    // Enable scroll-to-bottom suppression while the keyboard is visible and
    // the terminal scroll is near the top.  This prevents xterm's internal
    // stick-to-bottom from pushing short content off-screen.
    // viewportShrinkBudget is the total height the viewport lost (keyboard +
    // SpecialKeysBar).  If maxScrollExtent is within this budget the content
    // would have fit without the keyboard, so we suppress.
    _terminalScrollController.suppressScrollToMax = keyboardVisible;
    _terminalScrollController.viewportShrinkBudget = keyboardVisible
        ? keyboardInset + 120
        : 0;
    _syncKeyboardViewportState(
      keyboardVisible: keyboardVisible,
      keyboardInset: keyboardInset,
    );

    return Scaffold(
      key: _scaffoldKey,
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: Stack(
        children: [
          Column(
            children: [
              // Breadcrumb: directly watch tmuxProvider via Consumer (no parent rebuild needed)
              Consumer(
                builder: (context, ref, _) {
                  final tmuxState = ref.watch(tmuxProvider);
                  return _buildBreadcrumbHeader(tmuxState);
                },
              ),
              Expanded(
                child: ColoredBox(
                  color: _terminalMode == TerminalMode.select
                      ? DesignColors.warning
                      : Colors.transparent,
                  child: Padding(
                    padding: const EdgeInsets.all(3),
                    child: Stack(
                      children: [
                        RepaintBoundary(
                          child: ValueListenableBuilder<TerminalSnapshotFrame>(
                            valueListenable: _viewNotifier,
                            builder: (context, viewData, _) {
                              final backgroundColor = Theme.of(
                                context,
                              ).scaffoldBackgroundColor;
                              final foregroundColor = Theme.of(
                                context,
                              ).colorScheme.onSurface.withValues(alpha: 0.9);
                              return PaneTerminalView(
                                key: _paneTerminalViewKey,
                                terminal: _terminal,
                                terminalController: _terminalController,
                                paneWidth: viewData.paneWidth,
                                paneHeight: viewData.paneHeight,
                                backgroundColor: backgroundColor,
                                foregroundColor: foregroundColor,
                                mode: _terminalMode == TerminalMode.select
                                    ? PaneTerminalMode.select
                                    : PaneTerminalMode.normal,
                                readOnly: false,
                                verticalScrollEnabled: true,
                                zoomEnabled: true,
                                showCursor: ref
                                    .watch(settingsProvider)
                                    .showTerminalCursor,
                                onZoomChanged: (scale) {
                                  setState(() {
                                    _zoomScale = scale;
                                  });
                                },
                                verticalScrollController:
                                    _terminalScrollController,
                                onTwoFingerSwipe: _handleTwoFingerSwipe,
                                navigableDirections: _getNavigableDirections(),
                                onFollowBottomChanged: _handleLiveFollowChanged,
                              );
                            },
                          ),
                        ),
                        // Pane indicator: directly watch tmuxProvider via Consumer
                        Positioned(
                          top: 8,
                          right: 8,
                          child: Consumer(
                            builder: (context, ref, _) {
                              final tmuxState = ref.watch(tmuxProvider);
                              return _buildPaneIndicator(tmuxState);
                            },
                          ),
                        ),
                        if (_terminalMode == TerminalMode.normal)
                          _buildJumpToLiveOverlay(),
                      ],
                    ),
                  ),
                ),
              ),
              // SpecialKeysBar: only shown when the on-screen keyboard is visible
              if (keyboardVisible)
                SpecialKeysBar(
                  onLiteralKeyPressed: _sendLiteralKey,
                  onSpecialKeyPressed: _sendSpecialKey,
                  onCtrlToggle: _toggleCtrlModifier,
                  onAltToggle: _toggleAltModifier,
                  ctrlPressed: _ctrlModifierPressed,
                  altPressed: _altModifierPressed,
                  onShiftToggle: _toggleShiftModifier,
                  shiftPressed: _shiftModifierPressed,
                  onAttachImage: _attachImageFromDevice,
                  attachImageEnabled:
                      ref.read(sshProvider).isConnected &&
                      ref.read(tmuxProvider.notifier).currentTarget != null,
                  onToggleSelect: _toggleSelectMode,
                  selectModeActive: _terminalMode == TerminalMode.select,
                  onPaste: _pasteFromClipboard,
                ),
            ],
          ),
          // Loading overlay. During cached pane restores we keep the terminal
          // visible and only use a transparent barrier so input cannot race the
          // in-flight remote pane/window/session switch.
          if (_isConnecting || _isSwitchingPane || sshState.isConnecting)
            _buildLoadingOverlay(isDark: isDark, sshState: sshState),
          // Error overlay
          if (_connectionError != null || sshState.hasError)
            _buildErrorOverlay(sshState.error ?? _connectionError),
        ],
      ),
    );
  }

  Widget _buildJumpToLiveOverlay() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final chipColor = isDark
        ? Colors.black.withValues(alpha: 0.72)
        : Colors.white.withValues(alpha: 0.92);
    final textColor = Theme.of(context).colorScheme.onSurface;

    return Positioned(
      right: 12,
      bottom: 12,
      child: ValueListenableBuilder<_PendingLiveUpdateState>(
        valueListenable: _pendingLiveUpdateNotifier,
        builder: (context, pendingUpdate, _) {
          if (_isFollowingLiveTail && !pendingUpdate.hasPending) {
            return const SizedBox.shrink();
          }

          final label = switch (pendingUpdate.kind) {
            _PendingLiveUpdateKind.none => 'Jump to live',
            _PendingLiveUpdateKind.lines =>
              'Jump to live · ${pendingUpdate.lineCount} '
              '${pendingUpdate.lineCount == 1 ? 'new line' : 'new lines'}',
            _PendingLiveUpdateKind.updated => 'Jump to live · updated',
          };

          return Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: _jumpToLive,
              borderRadius: BorderRadius.circular(14),
              child: Ink(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: chipColor,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: DesignColors.primary.withValues(alpha: 0.28),
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.arrow_downward,
                      size: 16,
                      color: DesignColors.primary,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      label,
                      style: GoogleFonts.jetBrainsMono(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: textColor,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildLoadingOverlay({
    required bool isDark,
    required SshState sshState,
  }) {
    final showDimBackground =
        _isConnecting || sshState.isConnecting || _showSwitchingOverlay;
    final stageLabel = _loadingStageLabel;

    return Container(
      color: showDimBackground
          ? (isDark ? Colors.black54 : Colors.white70)
          : Colors.transparent,
      alignment: Alignment.center,
      child:
          (_isConnecting || sshState.isConnecting || _showSwitchingOverlay)
          ? DecoratedBox(
              decoration: BoxDecoration(
                color: isDark
                    ? Colors.black.withValues(alpha: 0.72)
                    : Colors.white.withValues(alpha: 0.96),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: Theme.of(
                    context,
                  ).colorScheme.outline.withValues(alpha: 0.18),
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 18,
                  vertical: 16,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(
                      width: 28,
                      height: 28,
                      child: CircularProgressIndicator(strokeWidth: 2.6),
                    ),
                    if (stageLabel != null && stageLabel.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      Text(
                        stageLabel,
                        style: GoogleFonts.jetBrainsMono(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: Theme.of(context).colorScheme.onSurface,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            )
          : null,
    );
  }

  /// Switch pane via two-finger swipe
  void _handleTwoFingerSwipe(SwipeDirection direction) {
    final tmuxState = ref.read(tmuxProvider);
    final window = tmuxState.activeWindow;
    final activePane = tmuxState.activePane;
    if (window == null || activePane == null) return;

    // Invert swipe direction based on settings
    final settings = ref.read(settingsProvider);
    final actualDirection = settings.invertPaneNavigation
        ? direction.inverted
        : direction;

    final targetPane = PaneNavigator.findAdjacentPane(
      panes: window.panes,
      current: activePane,
      direction: actualDirection,
    );

    if (targetPane != null) {
      _selectPane(targetPane.id);
    }
  }

  /// Get navigable directions from the current pane
  Map<SwipeDirection, bool>? _getNavigableDirections() {
    final tmuxState = ref.read(tmuxProvider);
    final window = tmuxState.activeWindow;
    final activePane = tmuxState.activePane;
    if (window == null || activePane == null) return null;

    final rawDirections = PaneNavigator.getNavigableDirections(
      panes: window.panes,
      current: activePane,
    );

    // Swap direction keys if inversion setting is enabled
    final settings = ref.read(settingsProvider);
    if (settings.invertPaneNavigation) {
      return {
        for (final dir in SwipeDirection.values)
          dir: rawDirections[dir.inverted] ?? false,
      };
    }

    return rawDirections;
  }

  Future<void> _sendTerminalData(String data) async {
    final sshClient = ref.read(sshProvider.notifier).client;

    if (data.isEmpty) {
      return;
    }

    if (sshClient == null || !sshClient.isConnected) {
      _inputQueue.enqueue(data);
      if (mounted) setState(() {});
      return;
    }

    final target = ref.read(tmuxProvider.notifier).currentTarget;
    if (target == null) return;

    try {
      final commands = TmuxCommands.sendKeysLiteralChunks(
        target,
        data,
        maxChunkLength: _literalInputChunkLength,
      );
      for (final command in commands) {
        await sshClient.execPersistentInput(
          command,
          timeout: const Duration(seconds: 2),
        );
      }
    } catch (_) {
      // Silently ignore key send errors.
    }
  }

  void _sendLiteralKey(String key) {
    if (_terminalMode != TerminalMode.normal) {
      return;
    }
    _ensureTerminalViewportAtBottomForInput();
    final modifiers = _consumePendingKeyboardModifiers();
    if (modifiers == null || modifiers.isEmpty) {
      XtermInputAdapter.sendText(_terminal, key);
      return;
    }

    XtermInputAdapter.sendTmuxKey(
      _terminal,
      XtermInputAdapter.applyModifiersToTmuxKey(
        key,
        shift: modifiers.shift,
        ctrl: modifiers.ctrl,
        alt: modifiers.alt,
      ),
    );
  }

  void _sendSpecialKey(String tmuxKey) {
    if (_terminalMode != TerminalMode.normal) {
      return;
    }
    _ensureTerminalViewportAtBottomForInput();
    final modifiers = _consumePendingKeyboardModifiers();
    final key = modifiers == null || modifiers.isEmpty
        ? tmuxKey
        : XtermInputAdapter.applyModifiersToTmuxKey(
            tmuxKey,
            shift: modifiers.shift,
            ctrl: modifiers.ctrl,
            alt: modifiers.alt,
          );
    XtermInputAdapter.sendTmuxKey(_terminal, key);
  }

  void _toggleCtrlModifier() {
    setState(() {
      _ctrlModifierPressed = !_ctrlModifierPressed;
    });
  }

  void _toggleAltModifier() {
    setState(() {
      _altModifierPressed = !_altModifierPressed;
    });
  }

  void _toggleShiftModifier() {
    setState(() {
      _shiftModifierPressed = !_shiftModifierPressed;
    });
  }

  void _toggleSelectMode() {
    final enteringSelect = _terminalMode != TerminalMode.select;
    setState(() {
      _terminalMode =
          enteringSelect ? TerminalMode.select : TerminalMode.normal;
    });
    if (enteringSelect) {
      _terminalController.clearSelection();
    } else {
      _flushDeferredStreamOutput();
    }
  }

  void _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data?.text != null && data!.text!.isNotEmpty) {
      // Exit select mode so the pasted text reaches tmux.
      if (_terminalMode == TerminalMode.select) {
        _toggleSelectMode();
      }
      _ensureTerminalViewportAtBottomForInput();
      XtermInputAdapter.sendPaste(_terminal, data.text!);
    }
  }

  _PendingKeyboardModifiers? _consumePendingKeyboardModifiers() {
    if (!_ctrlModifierPressed && !_altModifierPressed && !_shiftModifierPressed) {
      return null;
    }

    final modifiers = _PendingKeyboardModifiers(
      ctrl: _ctrlModifierPressed,
      alt: _altModifierPressed,
      shift: _shiftModifierPressed,
    );
    if (mounted && !_isDisposed) {
      setState(() {
        _ctrlModifierPressed = false;
        _altModifierPressed = false;
        _shiftModifierPressed = false;
      });
    } else {
      _ctrlModifierPressed = false;
      _altModifierPressed = false;
      _shiftModifierPressed = false;
    }
    return modifiers;
  }

  void _ensureTerminalViewportAtBottomForInput() {
    final paneView = _paneTerminalViewKey.currentState;
    if (paneView == null) {
      return;
    }

    if (paneView.shouldAutoFollow || paneView.isNearBottom) {
      paneView.scrollToBottom();
    }
  }

  /// Select session
  Future<void> _selectSession(String sessionName) async {
    final sshClient = ref.read(sshProvider.notifier).client;
    if (sshClient == null || _isSwitchingPane) return;

    _resetTransientTerminalUiBeforeSwitch();
    final previousSelection = _TmuxTargetSelection.fromState(
      ref.read(tmuxProvider),
    );
    if (previousSelection.sessionName == sessionName) {
      return;
    }

    _cachePaneRenderState(paneId: previousSelection.paneId);
    ref.read(tmuxProvider.notifier).setActiveSession(sessionName);

    final nextPane = ref.read(tmuxProvider).activePane;
    final restoredFromCache = _showActivePaneFromCacheOrPlaceholder(
      maxAge: Duration.zero,
    );
    setState(() {
      _isSwitchingPane = true;
      _showSwitchingOverlay = !restoredFromCache;
    });

    if (nextPane == null) {
      await _stopControlClient(resetRestartState: true);
      if (mounted) {
        setState(() {
          _isSwitchingPane = false;
          _showSwitchingOverlay = false;
        });
      }
      return;
    }

    var switchConfirmed = false;
    try {
      if (previousSelection.paneId != null &&
          previousSelection.paneId != nextPane.id) {
        await sshClient.execPersistentInput(
          TmuxCommands.sendKeys(
            previousSelection.paneId!,
            '\x1b[O',
            literal: true,
          ),
        );
      }
      await _restartTerminalStream(
        restartControlClient: true,
        refreshTree: false,
        reason: 'switch_session',
      );
      switchConfirmed = true;
      await sshClient.execPersistentInput(
        TmuxCommands.sendKeys(nextPane.id, '\x1b[I', literal: true),
      );
    } catch (_) {
      if (!switchConfirmed) {
        await _recoverFromFailedSwitch(
          previousSelection,
          restartControlClient: true,
        );
      }
    } finally {
      if (switchConfirmed) {
        _persistActivePaneSelection(nextPane.id);
      }
      if (mounted) {
        setState(() {
          _isSwitchingPane = false;
          _showSwitchingOverlay = false;
        });
      }
    }
  }

  /// Select window
  Future<void> _selectWindow(String sessionName, int windowIndex) async {
    final sshClient = ref.read(sshProvider.notifier).client;
    if (sshClient == null || !sshClient.isConnected || _isSwitchingPane) return;

    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    _resetTransientTerminalUiBeforeSwitch();
    final previousSelection = _TmuxTargetSelection.fromState(
      ref.read(tmuxProvider),
    );
    if (previousSelection.sessionName == sessionName &&
        previousSelection.windowIndex == windowIndex) {
      return;
    }

    _cachePaneRenderState(paneId: previousSelection.paneId);
    final currentSession = previousSelection.sessionName;
    if (currentSession != sessionName) {
      ref.read(tmuxProvider.notifier).setActiveSession(sessionName);
    }
    ref.read(tmuxProvider.notifier).setActiveWindow(windowIndex);

    final activePane = ref.read(tmuxProvider).activePane;
    final restoredFromCache = _showActivePaneFromCacheOrPlaceholder(
      maxAge: currentSession == sessionName ? _paneCacheMaxAge : Duration.zero,
    );
    setState(() {
      _isSwitchingPane = true;
      _showSwitchingOverlay = !restoredFromCache;
    });

    if (activePane == null) {
      await _recoverFromFailedSwitch(previousSelection);
      if (mounted) {
        setState(() {
          _isSwitchingPane = false;
          _showSwitchingOverlay = false;
        });
      }
      return;
    }

    var remoteSelectionChanged = false;
    var switchConfirmed = false;
    try {
      if (previousSelection.paneId != null &&
          previousSelection.paneId != activePane.id) {
        await sshClient.execPersistentInput(
          TmuxCommands.sendKeys(
            previousSelection.paneId!,
            '\x1b[O',
            literal: true,
          ),
        );
      }
      await sshClient.execPersistent(
        TmuxCommands.selectWindow(sessionName, windowIndex),
      );
      remoteSelectionChanged = true;
      await _restartTerminalStream(
        restartControlClient: currentSession != sessionName,
        refreshTree: false,
        reason: 'switch_window',
      );
      switchConfirmed = true;
      try {
        await sshClient.execPersistentInput(
          TmuxCommands.sendKeys(activePane.id, '\x1b[I', literal: true),
        );
      } catch (_) {
        // The tmux target is already switched and the stream is live again.
      }
    } catch (_) {
      if (!switchConfirmed) {
        await _recoverFromFailedSwitch(
          previousSelection,
          restartControlClient: currentSession != sessionName,
          restoreRemoteTarget: remoteSelectionChanged,
        );
      }
    } finally {
      if (switchConfirmed) {
        _persistActivePaneSelection(activePane.id);
      }
      if (mounted) {
        setState(() {
          _isSwitchingPane = false;
          _showSwitchingOverlay = false;
        });
      }
    }
  }

  /// Select pane
  Future<void> _selectPane(String paneId) async {
    final sshClient = ref.read(sshProvider.notifier).client;
    if (sshClient == null || !sshClient.isConnected || _isSwitchingPane) return;

    _resetTransientTerminalUiBeforeSwitch();
    final previousSelection = _TmuxTargetSelection.fromState(
      ref.read(tmuxProvider),
    );
    final oldPaneId = previousSelection.paneId;
    if (oldPaneId == paneId) {
      return;
    }

    _cachePaneRenderState(paneId: oldPaneId);
    ref.read(tmuxProvider.notifier).setActivePane(paneId);

    final activePane = ref.read(tmuxProvider).activePane;
    if (activePane == null) {
      _restoreLocalSelection(previousSelection);
      return;
    }

    final restoredFromCache = _showActivePaneFromCacheOrPlaceholder();
    setState(() {
      _isSwitchingPane = true;
      _showSwitchingOverlay = !restoredFromCache;
    });

    var remoteSelectionChanged = false;
    var switchConfirmed = false;
    try {
      // Send focus-out to the previous pane
      if (oldPaneId != null && oldPaneId != paneId) {
        await sshClient.execPersistentInput(
          TmuxCommands.sendKeys(oldPaneId, '\x1b[O', literal: true),
        );
      }

      await sshClient.execPersistent(TmuxCommands.selectPane(paneId));
      remoteSelectionChanged = true;
      await _restartTerminalStream(
        refreshTree: false,
        reason: 'switch_pane',
      );
      switchConfirmed = true;

      // Send focus-in to the new pane (so apps like Claude Code can detect focus)
      try {
        await sshClient.execPersistentInput(
          TmuxCommands.sendKeys(paneId, '\x1b[I', literal: true),
        );
      } catch (_) {
        // The tmux target is already switched and the stream is live again.
      }
    } catch (_) {
      if (!switchConfirmed) {
        await _recoverFromFailedSwitch(
          previousSelection,
          restoreRemoteTarget: remoteSelectionChanged,
        );
      }
    } finally {
      if (switchConfirmed) {
        _persistActivePaneSelection(paneId);
      }
      if (mounted) {
        setState(() {
          _isSwitchingPane = false;
          _showSwitchingOverlay = false;
        });
      }
    }
  }

  /// Error overlay
  Widget _buildErrorOverlay(String? error) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final colorScheme = Theme.of(context).colorScheme;
    final queuedCount = _inputQueue.length;
    final isWaitingForNetwork = _sshState.isWaitingForNetwork;

    return Container(
      color: isDark ? Colors.black87 : Colors.white.withValues(alpha: 0.95),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              isWaitingForNetwork ? Icons.signal_wifi_off : Icons.error_outline,
              color: isWaitingForNetwork
                  ? DesignColors.warning
                  : colorScheme.error,
              size: 48,
            ),
            const SizedBox(height: 16),
            Text(
              isWaitingForNetwork
                  ? 'Waiting for network...'
                  : (error ?? 'Connection error'),
              style: TextStyle(color: colorScheme.onSurface),
              textAlign: TextAlign.center,
            ),

            // Queuing state
            if (queuedCount > 0) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: DesignColors.primary.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.keyboard, size: 16, color: DesignColors.primary),
                    const SizedBox(width: 8),
                    Text(
                      '$queuedCount chars queued',
                      style: TextStyle(
                        color: DesignColors.primary,
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(width: 8),
                    GestureDetector(
                      onTap: () {
                        _inputQueue.clear();
                        setState(() {});
                      },
                      child: Icon(
                        Icons.clear,
                        size: 16,
                        color: DesignColors.primary.withValues(alpha: 0.7),
                      ),
                    ),
                  ],
                ),
              ),
            ],

            const SizedBox(height: 16),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                ElevatedButton(
                  onPressed: () {
                    ref.read(sshProvider.notifier).reconnectNow();
                  },
                  child: const Text('Retry Now'),
                ),
                if (_sshState.isReconnecting) ...[
                  const SizedBox(width: 12),
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: colorScheme.primary,
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// Top breadcrumb navigation header
  Widget _buildBreadcrumbHeader(TmuxState tmuxState) {
    final currentSession = tmuxState.activeSessionName ?? '';
    final activeWindow = tmuxState.activeWindow;
    final currentWindow = activeWindow?.name ?? '';
    final activePane = tmuxState.activePane;
    final colorScheme = Theme.of(context).colorScheme;

    // Place SafeArea on the outside to reserve space for the status bar
    return SafeArea(
      bottom: false,
      child: Container(
        height: 40,
        decoration: BoxDecoration(
          color: colorScheme.surface.withValues(alpha: 0.9),
          border: Border(
            bottom: BorderSide(color: colorScheme.outline, width: 1),
          ),
        ),
        child: Row(
          children: [
            const SizedBox(width: 8),
            // Breadcrumb navigation
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    // Session name (tap to switch)
                    _buildBreadcrumbItem(
                      currentSession,
                      icon: Icons.folder,
                      isActive: true,
                      onTap: () => _showSessionSelector(tmuxState),
                    ),
                    _buildBreadcrumbSeparator(),
                    // Window name (tap to switch)
                    // Check if any non-active window has a bell flag
                    Builder(builder: (_) {
                      final session = tmuxState.activeSession;
                      final hasBell = session != null &&
                          session.windows.any((w) =>
                              w.index != tmuxState.activeWindowIndex &&
                              w.hasBell);
                      return _buildBreadcrumbItem(
                        currentWindow,
                        icon: hasBell
                            ? Icons.notifications_active
                            : Icons.tab,
                        isSelected: true,
                        alertColor: hasBell ? DesignColors.error : null,
                        onTap: () => _showWindowSelector(tmuxState),
                      );
                    }),
                    // Display pane if available
                    if (activePane != null) ...[
                      _buildBreadcrumbSeparator(),
                      _buildBreadcrumbItem(
                        'Pane ${activePane.index}',
                        icon: Icons.terminal,
                        isActive: false,
                        onTap: () => _showPaneSelector(tmuxState),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            // Select mode indicator — tappable to exit select mode
            if (_terminalMode == TerminalMode.select)
              GestureDetector(
                onTap: _toggleSelectMode,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  margin: const EdgeInsets.only(right: 8),
                  decoration: BoxDecoration(
                    color: DesignColors.warning.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(
                      color: DesignColors.warning.withValues(alpha: 0.5),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.close,
                        size: 12,
                        color: DesignColors.warning,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        'Select',
                        style: GoogleFonts.jetBrainsMono(
                          fontSize: 10,
                          color: DesignColors.warning,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            // Zoom indicator
            if (_zoomScale != 1.0)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                margin: const EdgeInsets.only(right: 8),
                decoration: BoxDecoration(
                  color: DesignColors.warning.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  '${(_zoomScale * 100).toStringAsFixed(0)}%',
                  style: GoogleFonts.jetBrainsMono(
                    fontSize: 10,
                    color: DesignColors.warning,
                  ),
                ),
              ),
            // Latency / Bandwidth / Reconnect indicator
            AnimatedBuilder(
              animation: Listenable.merge([
                _latencyNotifier,
                _bandwidthNotifier,
              ]),
              builder: (context, _) => _buildConnectionIndicator(
                latency: _latencyNotifier.value,
                bandwidthBitsPerSecond: _bandwidthNotifier.value,
              ),
            ),
            // Settings button
            IconButton(
              onPressed: _showTerminalMenu,
              icon: Icon(
                Icons.settings,
                size: 16,
                color: colorScheme.onSurface.withValues(alpha: 0.6),
              ),
              padding: const EdgeInsets.all(8),
              constraints: const BoxConstraints(),
            ),
            const SizedBox(width: 4),
          ],
        ),
      ),
    );
  }

  /// Execute a tmux management command with error handling and tree refresh.
  ///
  /// Returns `true` only when the remote command succeeds (no tmux error in
  /// the output and no thrown exception). Callers can trust that `true` means
  /// the mutation was applied on the server.
  Future<bool> _execTmuxManagement(String command) async {
    final sshClient = ref.read(sshProvider.notifier).client;
    if (sshClient == null || !sshClient.isConnected) return false;
    try {
      final output = await sshClient.execPersistent(command);
      final error = TmuxParser.extractError(output);
      if (error != null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(error)),
          );
        }
        return false;
      }
      _scheduleControlSync(refreshTree: true);
      return true;
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Command failed: $e')),
        );
      }
      return false;
    }
  }

  /// Execute a tmux command, immediately refresh the tree, and return success.
  ///
  /// Unlike [_execTmuxManagement], this awaits the tree refresh so callers
  /// can read the updated [TmuxState] right after the call returns.
  Future<bool> _execTmuxAndRefreshTree(String command) async {
    final sshClient = ref.read(sshProvider.notifier).client;
    if (sshClient == null || !sshClient.isConnected) return false;
    try {
      final output = await sshClient.execPersistent(command);
      final error = TmuxParser.extractError(output);
      if (error != null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(error)),
          );
        }
        return false;
      }
      final treeOutput =
          await sshClient.execPersistent(TmuxCommands.listAllPanes());
      if (!mounted || _isDisposed) return false;
      ref.read(tmuxProvider.notifier).parseAndUpdateFullTree(treeOutput);
      return true;
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Command failed: $e')),
        );
      }
      return false;
    }
  }

  /// Show session selection dialog
  void _showSessionSelector(TmuxState tmuxState) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      isDismissible: true,
      enableDrag: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetContext) {
        final colorScheme = Theme.of(sheetContext).colorScheme;
        final maxHeight = MediaQuery.of(sheetContext).size.height * 0.6;
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maxHeight),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.only(
                    left: 16,
                    top: 16,
                    bottom: 16,
                    right: 4,
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.folder, color: colorScheme.primary),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Select Session',
                          style: GoogleFonts.spaceGrotesk(
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                            color: colorScheme.onSurface,
                          ),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.add),
                        tooltip: 'New Session',
                        onPressed: () async {
                          Navigator.pop(sheetContext);
                          final name = await showDialog<String>(
                            context: context,
                            builder: (_) => TmuxNewItemDialog(
                              itemType: 'Session',
                              existingNames: tmuxState.sessions
                                  .map((s) => s.name)
                                  .toList(),
                            ),
                          );
                          if (name != null) {
                            final ok = await _execTmuxAndRefreshTree(
                              TmuxCommands.newSession(name: name),
                            );
                            if (ok && mounted) {
                              _selectSession(name);
                            }
                          }
                        },
                      ),
                    ],
                  ),
                ),
                Divider(height: 1, color: colorScheme.outline),
                Flexible(
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: tmuxState.sessions.length,
                    itemBuilder: (context, index) {
                      final session = tmuxState.sessions[index];
                      final isActive =
                          session.name == tmuxState.activeSessionName;
                      final canDelete = tmuxState.sessions.length > 1;
                      return ListTile(
                        leading: Icon(
                          isActive ? Icons.folder : Icons.folder_outlined,
                          color: isActive
                              ? colorScheme.primary
                              : colorScheme.onSurface.withValues(alpha: 0.6),
                        ),
                        title: Text(
                          session.name,
                          style: TextStyle(
                            color: isActive
                                ? colorScheme.primary
                                : colorScheme.onSurface,
                            fontWeight: isActive
                                ? FontWeight.bold
                                : FontWeight.normal,
                          ),
                        ),
                        subtitle: Text(
                          '${session.windowCount} windows',
                          style: TextStyle(
                            color: colorScheme.onSurface.withValues(
                              alpha: 0.38,
                            ),
                          ),
                        ),
                        trailing: PopupMenuButton<String>(
                          icon: Icon(
                            Icons.more_vert,
                            size: 20,
                            color: colorScheme.onSurface.withValues(alpha: 0.6),
                          ),
                          onSelected: (action) async {
                            Navigator.pop(sheetContext);
                            switch (action) {
                              case 'rename':
                                final newName = await showDialog<String>(
                                  context: context,
                                  builder: (_) => TmuxRenameDialog(
                                    currentName: session.name,
                                    itemType: 'Session',
                                    existingNames: tmuxState.sessions
                                        .map((s) => s.name)
                                        .toList(),
                                  ),
                                );
                                if (newName != null) {
                                  final ok = await _execTmuxManagement(
                                    TmuxCommands.renameSession(
                                      session.name,
                                      newName,
                                    ),
                                  );
                                  if (ok) {
                                    if (isActive) {
                                      ref
                                          .read(tmuxProvider.notifier)
                                          .setActive(sessionName: newName);
                                    }
                                    ref
                                        .read(activeSessionsProvider.notifier)
                                        .renameSession(
                                          widget.connectionId,
                                          session.name,
                                          newName,
                                        );
                                  }
                                }
                              case 'delete':
                                final confirmed = await showDialog<bool>(
                                  context: context,
                                  builder: (_) => TmuxConfirmDeleteDialog(
                                    itemType: 'Session',
                                    itemName: session.name,
                                  ),
                                );
                                if (confirmed == true) {
                                  final ok = await _execTmuxManagement(
                                    TmuxCommands.killSession(session.name),
                                  );
                                  if (ok) {
                                    ref
                                        .read(activeSessionsProvider.notifier)
                                        .removeSession(
                                          widget.connectionId,
                                          session.name,
                                        );
                                    if (isActive) {
                                      // Switch to first remaining session
                                      final remaining = ref
                                          .read(tmuxProvider)
                                          .sessions
                                          .where(
                                            (s) => s.name != session.name,
                                          )
                                          .firstOrNull;
                                      if (remaining != null && mounted) {
                                        _selectSession(remaining.name);
                                      } else if (mounted) {
                                        Navigator.of(this.context).pop();
                                      }
                                    }
                                  }
                                }
                            }
                          },
                          itemBuilder: (_) => [
                            const PopupMenuItem(
                              value: 'rename',
                              child: ListTile(
                                leading: Icon(Icons.edit),
                                title: Text('Rename'),
                                dense: true,
                                contentPadding: EdgeInsets.zero,
                              ),
                            ),
                            if (canDelete)
                              PopupMenuItem(
                                value: 'delete',
                                child: ListTile(
                                  leading: Icon(
                                    Icons.delete,
                                    color: DesignColors.error,
                                  ),
                                  title: Text(
                                    'Delete',
                                    style:
                                        TextStyle(color: DesignColors.error),
                                  ),
                                  dense: true,
                                  contentPadding: EdgeInsets.zero,
                                ),
                              ),
                          ],
                        ),
                        onTap: () {
                          Navigator.pop(sheetContext);
                          _selectSession(session.name);
                        },
                      );
                    },
                  ),
                ),
                const SizedBox(height: 16),
              ],
            ),
          ),
        );
      },
    );
  }

  /// Get the icon color for a window based on its flags and active state.
  Color _windowIconColor(
    TmuxWindow window,
    bool isActive,
    ColorScheme colorScheme,
  ) {
    if (isActive) return colorScheme.primary;
    if (window.hasBell) return DesignColors.error;
    if (window.hasActivity) return Colors.orange;
    if (window.hasSilence) return Colors.grey;
    return colorScheme.onSurface.withValues(alpha: 0.6);
  }

  /// Build an activity/bell/silence badge for a window.
  Widget? _windowFlagBadge(TmuxWindow window, bool isDark) {
    final TmuxWindowFlag? flag;
    if (window.hasBell) {
      flag = TmuxWindowFlag.bell;
    } else if (window.hasActivity) {
      flag = TmuxWindowFlag.activity;
    } else if (window.hasSilence) {
      flag = TmuxWindowFlag.silence;
    } else {
      return null;
    }

    final Color bgColor;
    final Color borderColor;
    final Color textColor;
    final String label;
    switch (flag) {
      case TmuxWindowFlag.bell:
        bgColor = DesignColors.error.withValues(alpha: isDark ? 0.15 : 0.1);
        borderColor = DesignColors.error.withValues(alpha: 0.3);
        textColor = DesignColors.error;
        label = 'Bell';
      case TmuxWindowFlag.activity:
        bgColor = Colors.orange.withValues(alpha: isDark ? 0.15 : 0.1);
        borderColor = Colors.orange.withValues(alpha: 0.3);
        textColor = Colors.orange;
        label = 'Activity';
      case TmuxWindowFlag.silence:
        bgColor = Colors.grey.withValues(alpha: isDark ? 0.15 : 0.1);
        borderColor = Colors.grey.withValues(alpha: 0.3);
        textColor = Colors.grey;
        label = 'Silence';
      default:
        return null;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: borderColor),
      ),
      child: Text(
        label,
        style: GoogleFonts.jetBrainsMono(
          fontSize: 9,
          fontWeight: FontWeight.w600,
          color: textColor,
        ),
      ),
    );
  }

  /// Show window selection dialog.
  ///
  /// Refreshes the session tree first so window flags (bell, activity,
  /// silence) are up-to-date when the modal opens.
  Future<void> _showWindowSelector(TmuxState tmuxState) async {
    final session = tmuxState.activeSession;
    if (session == null) return;

    // Quick tree refresh so flags are current
    final sshClient = ref.read(sshProvider.notifier).client;
    if (sshClient != null && sshClient.isConnected) {
      try {
        final output =
            await sshClient.execPersistent(TmuxCommands.listAllPanes());
        if (mounted && !_isDisposed) {
          ref.read(tmuxProvider.notifier).parseAndUpdateFullTree(output);
        }
      } catch (_) {}
    }
    if (!mounted || _isDisposed) return;

    // Re-read updated state
    final freshState = ref.read(tmuxProvider);
    final freshSession = freshState.activeSession ?? session;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      isDismissible: true,
      enableDrag: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetContext) {
        final colorScheme = Theme.of(sheetContext).colorScheme;
        final isDark = Theme.of(sheetContext).brightness == Brightness.dark;
        final maxHeight = MediaQuery.of(sheetContext).size.height * 0.6;
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maxHeight),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.only(
                    left: 16,
                    top: 16,
                    bottom: 16,
                    right: 4,
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.tab, color: colorScheme.primary),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Select Window',
                          style: GoogleFonts.spaceGrotesk(
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                            color: colorScheme.onSurface,
                          ),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.add),
                        tooltip: 'New Window',
                        onPressed: () async {
                          Navigator.pop(sheetContext);
                          final name = await showDialog<String>(
                            context: context,
                            builder: (_) => TmuxNewItemDialog(
                              itemType: 'Window',
                              existingNames: freshSession.windows
                                  .map((w) => w.name)
                                  .toList(),
                            ),
                          );
                          if (name != null) {
                            final ok = await _execTmuxAndRefreshTree(
                              TmuxCommands.newWindow(
                                sessionName: freshSession.name,
                                windowName: name,
                                background: true,
                              ),
                            );
                            if (ok && mounted) {
                              final updated = ref
                                  .read(tmuxProvider)
                                  .sessions
                                  .where((s) => s.name == freshSession.name)
                                  .firstOrNull;
                              final newWindow = updated?.windows
                                  .where((w) => w.name == name)
                                  .lastOrNull;
                              if (newWindow != null) {
                                _selectWindow(
                                  freshSession.name,
                                  newWindow.index,
                                );
                              }
                            }
                          }
                        },
                      ),
                    ],
                  ),
                ),
                Divider(height: 1, color: colorScheme.outline),
                Flexible(
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: freshSession.windows.length,
                    itemBuilder: (context, index) {
                      final window = freshSession.windows[index];
                      final isActive =
                          window.index == freshState.activeWindowIndex;
                      final canDelete = freshSession.windows.length > 1;
                      final flagBadge = _windowFlagBadge(window, isDark);
                      return ListTile(
                        leading: Icon(
                          Icons.tab,
                          color: _windowIconColor(
                            window,
                            isActive,
                            colorScheme,
                          ),
                        ),
                        title: Text(
                          '${window.index}: ${window.name}',
                          style: TextStyle(
                            color: isActive
                                ? colorScheme.primary
                                : colorScheme.onSurface,
                            fontWeight: isActive
                                ? FontWeight.bold
                                : FontWeight.normal,
                          ),
                        ),
                        subtitle: Row(
                          children: [
                            Text(
                              '${window.paneCount} panes',
                              style: TextStyle(
                                color: colorScheme.onSurface.withValues(
                                  alpha: 0.38,
                                ),
                              ),
                            ),
                            if (flagBadge != null) ...[
                              const SizedBox(width: 8),
                              flagBadge,
                            ],
                            if (window.isZoomed) ...[
                              const SizedBox(width: 8),
                              Icon(
                                Icons.fullscreen,
                                size: 14,
                                color: colorScheme.onSurface.withValues(
                                  alpha: 0.5,
                                ),
                              ),
                            ],
                          ],
                        ),
                        trailing: PopupMenuButton<String>(
                          icon: Icon(
                            Icons.more_vert,
                            size: 20,
                            color: colorScheme.onSurface.withValues(alpha: 0.6),
                          ),
                          onSelected: (action) async {
                            Navigator.pop(sheetContext);
                            switch (action) {
                              case 'rename':
                                final newName = await showDialog<String>(
                                  context: context,
                                  builder: (_) => TmuxRenameDialog(
                                    currentName: window.name,
                                    itemType: 'Window',
                                  ),
                                );
                                if (newName != null) {
                                  await _execTmuxManagement(
                                    TmuxCommands.renameWindow(
                                      freshSession.name,
                                      window.index,
                                      newName,
                                    ),
                                  );
                                }
                              case 'delete':
                                final confirmed = await showDialog<bool>(
                                  context: context,
                                  builder: (_) => TmuxConfirmDeleteDialog(
                                    itemType: 'Window',
                                    itemName:
                                        '${window.index}: ${window.name}',
                                  ),
                                );
                                if (confirmed == true) {
                                  await _execTmuxManagement(
                                    TmuxCommands.killWindow(
                                      freshSession.name,
                                      window.index,
                                    ),
                                  );
                                }
                            }
                          },
                          itemBuilder: (_) => [
                            const PopupMenuItem(
                              value: 'rename',
                              child: ListTile(
                                leading: Icon(Icons.edit),
                                title: Text('Rename'),
                                dense: true,
                                contentPadding: EdgeInsets.zero,
                              ),
                            ),
                            if (canDelete)
                              PopupMenuItem(
                                value: 'delete',
                                child: ListTile(
                                  leading: Icon(
                                    Icons.delete,
                                    color: DesignColors.error,
                                  ),
                                  title: Text(
                                    'Delete',
                                    style:
                                        TextStyle(color: DesignColors.error),
                                  ),
                                  dense: true,
                                  contentPadding: EdgeInsets.zero,
                                ),
                              ),
                          ],
                        ),
                        onTap: () {
                          Navigator.pop(sheetContext);
                          _selectWindow(freshSession.name, window.index);
                        },
                      );
                    },
                  ),
                ),
                const SizedBox(height: 16),
              ],
            ),
          ),
        );
      },
    );
  }

  /// Show pane selection dialog
  void _showPaneSelector(TmuxState tmuxState) {
    final window = tmuxState.activeWindow;
    final session = tmuxState.activeSession;
    if (window == null || session == null) return;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      isDismissible: true,
      enableDrag: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetContext) {
        final colorScheme = Theme.of(sheetContext).colorScheme;
        final maxHeight = MediaQuery.of(sheetContext).size.height * 0.7;
        final activePaneId = tmuxState.activePaneId;
        final layoutTarget =
            '${session.name}:${window.index}';
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maxHeight),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.only(
                    left: 16,
                    top: 16,
                    bottom: 16,
                    right: 4,
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.terminal, color: colorScheme.primary),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Select Pane',
                          style: GoogleFonts.spaceGrotesk(
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                            color: colorScheme.onSurface,
                          ),
                        ),
                      ),
                      PopupMenuButton<String>(
                        icon: const Icon(Icons.add),
                        tooltip: 'Split / Layout',
                        onSelected: (action) async {
                          Navigator.pop(sheetContext);
                          switch (action) {
                            case 'split_h':
                              if (activePaneId != null) {
                                final ok = await _execTmuxAndRefreshTree(
                                  TmuxCommands.splitWindowHorizontal(
                                    target: activePaneId,
                                  ),
                                );
                                if (ok && mounted) {
                                  final w = ref
                                      .read(tmuxProvider)
                                      .activeWindow;
                                  final newPane = w?.panes
                                      .where((p) =>
                                          p.active &&
                                          p.id != activePaneId)
                                      .firstOrNull;
                                  if (newPane != null) {
                                    _selectPane(newPane.id);
                                  }
                                }
                              }
                            case 'split_v':
                              if (activePaneId != null) {
                                final ok = await _execTmuxAndRefreshTree(
                                  TmuxCommands.splitWindowVertical(
                                    target: activePaneId,
                                  ),
                                );
                                if (ok && mounted) {
                                  final w = ref
                                      .read(tmuxProvider)
                                      .activeWindow;
                                  final newPane = w?.panes
                                      .where((p) =>
                                          p.active &&
                                          p.id != activePaneId)
                                      .firstOrNull;
                                  if (newPane != null) {
                                    _selectPane(newPane.id);
                                  }
                                }
                              }
                            case 'layout_even_h':
                              await _execTmuxManagement(
                                TmuxCommands.selectLayout(
                                  layoutTarget,
                                  TmuxLayout.evenHorizontal,
                                ),
                              );
                            case 'layout_even_v':
                              await _execTmuxManagement(
                                TmuxCommands.selectLayout(
                                  layoutTarget,
                                  TmuxLayout.evenVertical,
                                ),
                              );
                            case 'layout_main_h':
                              await _execTmuxManagement(
                                TmuxCommands.selectLayout(
                                  layoutTarget,
                                  TmuxLayout.mainHorizontal,
                                ),
                              );
                            case 'layout_main_v':
                              await _execTmuxManagement(
                                TmuxCommands.selectLayout(
                                  layoutTarget,
                                  TmuxLayout.mainVertical,
                                ),
                              );
                            case 'layout_tiled':
                              await _execTmuxManagement(
                                TmuxCommands.selectLayout(
                                  layoutTarget,
                                  TmuxLayout.tiled,
                                ),
                              );
                          }
                        },
                        itemBuilder: (_) => [
                          const PopupMenuItem(
                            value: 'split_h',
                            child: ListTile(
                              leading: Icon(Icons.vertical_split),
                              title: Text('Split Horizontal'),
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                            ),
                          ),
                          const PopupMenuItem(
                            value: 'split_v',
                            child: ListTile(
                              leading: Icon(Icons.horizontal_split),
                              title: Text('Split Vertical'),
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                            ),
                          ),
                          const PopupMenuDivider(),
                          const PopupMenuItem(
                            value: 'layout_even_h',
                            child: ListTile(
                              leading: Icon(Icons.view_column),
                              title: Text('Even Horizontal'),
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                            ),
                          ),
                          const PopupMenuItem(
                            value: 'layout_even_v',
                            child: ListTile(
                              leading: Icon(Icons.view_stream),
                              title: Text('Even Vertical'),
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                            ),
                          ),
                          const PopupMenuItem(
                            value: 'layout_main_h',
                            child: ListTile(
                              leading: Icon(Icons.vertical_align_top),
                              title: Text('Main Horizontal'),
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                            ),
                          ),
                          const PopupMenuItem(
                            value: 'layout_main_v',
                            child: ListTile(
                              leading: Icon(Icons.align_horizontal_left),
                              title: Text('Main Vertical'),
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                            ),
                          ),
                          const PopupMenuItem(
                            value: 'layout_tiled',
                            child: ListTile(
                              leading: Icon(Icons.grid_view),
                              title: Text('Tiled'),
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                Divider(height: 1, color: colorScheme.outline),
                // Visual display of pane layout
                if (window.panes.length > 1)
                  _PaneLayoutVisualizer(
                    panes: window.panes,
                    activePaneId: tmuxState.activePaneId,
                    onPaneSelected: (paneId) {
                      Navigator.pop(sheetContext);
                      _selectPane(paneId);
                    },
                  ),
                Divider(height: 1, color: colorScheme.outline),
                // Pane list
                Flexible(
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: window.panes.length,
                    itemBuilder: (context, index) {
                      final pane = window.panes[index];
                      final isActive = pane.id == tmuxState.activePaneId;
                      final canDelete = window.panes.length > 1;
                      // Prioritize title display, then command name, then Pane index
                      final paneTitle = pane.title?.isNotEmpty == true
                          ? pane.title!
                          : (pane.currentCommand?.isNotEmpty == true
                                ? pane.currentCommand!
                                : 'Pane ${pane.index}');
                      return ListTile(
                        leading: Container(
                          width: 32,
                          height: 32,
                          decoration: BoxDecoration(
                            color: isActive
                                ? colorScheme.primary.withValues(alpha: 0.2)
                                : colorScheme.onSurface.withValues(alpha: 0.05),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: isActive
                                  ? colorScheme.primary.withValues(alpha: 0.5)
                                  : colorScheme.onSurface.withValues(
                                      alpha: 0.1,
                                    ),
                            ),
                          ),
                          child: Center(
                            child: Text(
                              '${pane.index}',
                              style: GoogleFonts.jetBrainsMono(
                                fontSize: 14,
                                fontWeight: FontWeight.w700,
                                color: isActive
                                    ? colorScheme.primary
                                    : colorScheme.onSurface.withValues(
                                        alpha: 0.6,
                                      ),
                              ),
                            ),
                          ),
                        ),
                        title: Text(
                          paneTitle,
                          style: TextStyle(
                            color: isActive
                                ? colorScheme.primary
                                : colorScheme.onSurface,
                            fontWeight: isActive
                                ? FontWeight.bold
                                : FontWeight.normal,
                          ),
                        ),
                        subtitle: Text(
                          '${pane.width}x${pane.height}',
                          style: TextStyle(
                            color: colorScheme.onSurface.withValues(
                              alpha: 0.38,
                            ),
                          ),
                        ),
                        trailing: PopupMenuButton<String>(
                          icon: Icon(
                            Icons.more_vert,
                            size: 20,
                            color: colorScheme.onSurface.withValues(alpha: 0.6),
                          ),
                          onSelected: (action) async {
                            Navigator.pop(sheetContext);
                            switch (action) {
                              case 'zoom':
                                await _execTmuxManagement(
                                  TmuxCommands.resizePane(pane.id),
                                );
                              case 'resize':
                                final settings = ref.read(settingsProvider);
                                final displayState =
                                    ref.read(terminalDisplayProvider);
                                final result =
                                    await showDialog<ViewportResizeResult>(
                                  context: context,
                                  builder: (_) => ViewportResizeDialog(
                                    currentColumns: pane.width,
                                    currentRows: pane.height,
                                    availableWidth: displayState.screenWidth,
                                    fontSize: displayState.effectiveFontSize,
                                    fontFamily: settings.fontFamily,
                                  ),
                                );
                                if (result != null && mounted) {
                                  // Use resize-window for single-pane windows,
                                  // resize-pane for multi-pane windows.
                                  final isSinglePane = window.panes.length == 1;
                                  final colCmd = isSinglePane
                                      ? TmuxCommands.resizeWindowColumns(
                                          '${tmuxState.activeSessionName}:${window.index}',
                                          result.columns,
                                        )
                                      : TmuxCommands.resizePaneColumns(
                                          pane.id,
                                          result.columns,
                                        );
                                  await _execTmuxManagement(colCmd);
                                  if (result.rows != null && mounted) {
                                    final rowCmd =
                                        TmuxCommands.resizePaneRows(
                                      pane.id,
                                      result.rows!,
                                    );
                                    await _execTmuxManagement(rowCmd);
                                  }
                                }
                              case 'delete':
                                final confirmed = await showDialog<bool>(
                                  context: context,
                                  builder: (_) => TmuxConfirmDeleteDialog(
                                    itemType: 'Pane',
                                    itemName: paneTitle,
                                  ),
                                );
                                if (confirmed == true) {
                                  await _execTmuxManagement(
                                    TmuxCommands.killPane(pane.id),
                                  );
                                }
                            }
                          },
                          itemBuilder: (_) => [
                            const PopupMenuItem(
                              value: 'zoom',
                              child: ListTile(
                                leading: Icon(Icons.fullscreen),
                                title: Text('Toggle Zoom'),
                                dense: true,
                                contentPadding: EdgeInsets.zero,
                              ),
                            ),
                            const PopupMenuItem(
                              value: 'resize',
                              child: ListTile(
                                leading: Icon(Icons.aspect_ratio),
                                title: Text('Resize'),
                                dense: true,
                                contentPadding: EdgeInsets.zero,
                              ),
                            ),
                            if (canDelete)
                              PopupMenuItem(
                                value: 'delete',
                                child: ListTile(
                                  leading: Icon(
                                    Icons.delete,
                                    color: DesignColors.error,
                                  ),
                                  title: Text(
                                    'Kill Pane',
                                    style:
                                        TextStyle(color: DesignColors.error),
                                  ),
                                  dense: true,
                                  contentPadding: EdgeInsets.zero,
                                ),
                              ),
                          ],
                        ),
                        onTap: () {
                          Navigator.pop(sheetContext);
                          _selectPane(pane.id);
                        },
                      );
                    },
                  ),
                ),
                const SizedBox(height: 16),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildBreadcrumbItem(
    String label, {
    IconData? icon,
    bool isActive = false,
    bool isSelected = false,
    Color? alertColor,
    VoidCallback? onTap,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: isSelected
            ? BoxDecoration(
                color: colorScheme.onSurface.withValues(alpha: 0.05),
                borderRadius: BorderRadius.circular(4),
                border: Border.all(
                  color: alertColor?.withValues(alpha: 0.3) ??
                      colorScheme.onSurface.withValues(alpha: 0.05),
                ),
              )
            : null,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(
                icon,
                size: 12,
                color: alertColor ??
                    (isActive
                        ? colorScheme.primary
                        : (isSelected
                              ? colorScheme.onSurface
                              : colorScheme.onSurface.withValues(alpha: 0.6))),
              ),
              const SizedBox(width: 4),
            ],
            Text(
              label.isEmpty ? '...' : label,
              style: GoogleFonts.jetBrainsMono(
                fontSize: 11,
                fontWeight: isActive || isSelected
                    ? FontWeight.w700
                    : FontWeight.w400,
                color: isActive
                    ? colorScheme.primary
                    : (isSelected
                          ? colorScheme.onSurface
                          : colorScheme.onSurface.withValues(alpha: 0.5)),
              ),
            ),
            if (onTap != null) ...[
              const SizedBox(width: 2),
              Icon(
                Icons.arrow_drop_down,
                size: 14,
                color: isActive
                    ? colorScheme.primary.withValues(alpha: 0.7)
                    : colorScheme.onSurface.withValues(alpha: 0.38),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildBreadcrumbSeparator() {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Text(
        '/',
        style: GoogleFonts.jetBrainsMono(
          fontSize: 10,
          fontWeight: FontWeight.w300,
          color: colorScheme.onSurface.withValues(alpha: 0.2),
        ),
      ),
    );
  }

  /// Show terminal menu
  void _showTerminalMenu() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final menuBgColor = isDark
        ? DesignColors.surfaceDark
        : DesignColors.surfaceLight;
    final textColor = isDark ? Colors.white : Colors.black87;
    final mutedTextColor = isDark ? Colors.white38 : Colors.black38;
    final inactiveIconColor = isDark ? Colors.white60 : Colors.black45;
    final canAttachImage =
        ref.read(sshProvider).isConnected &&
        ref.read(tmuxProvider.notifier).currentTarget != null;

    showModalBottomSheet(
      context: context,
      backgroundColor: menuBgColor,
      isDismissible: true,
      enableDrag: true,
      isScrollControlled: true,
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.7,
      ),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    Icon(Icons.tune, color: DesignColors.primary),
                    const SizedBox(width: 8),
                    Text(
                      'Terminal Options',
                      style: GoogleFonts.spaceGrotesk(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        color: textColor,
                      ),
                    ),
                  ],
                ),
              ),
              Divider(
                height: 1,
                color: isDark ? const Color(0xFF2A2B36) : Colors.grey.shade300,
              ),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    // Reset zoom
                    ListTile(
                      leading: Icon(
                        Icons.zoom_out_map,
                        color: _zoomScale != 1.0
                            ? DesignColors.warning
                            : inactiveIconColor,
                      ),
                      title: Text(
                        'Reset Zoom',
                        style: TextStyle(
                          color: _zoomScale != 1.0 ? textColor : mutedTextColor,
                        ),
                      ),
                      subtitle: Text(
                        _zoomScale != 1.0
                            ? 'Current: ${(_zoomScale * 100).toStringAsFixed(0)}%'
                            : 'Pinch to zoom in/out',
                        style: TextStyle(color: mutedTextColor, fontSize: 12),
                      ),
                      enabled: _zoomScale != 1.0,
                      onTap: _zoomScale != 1.0
                          ? () {
                              _paneTerminalViewKey.currentState?.resetZoom();
                              setState(() {
                                _zoomScale = 1.0;
                              });
                              Navigator.pop(context);
                            }
                          : null,
                    ),
                    Divider(
                      height: 1,
                      color: isDark ? const Color(0xFF2A2B36) : Colors.grey.shade300,
                    ),
                    // Attach Image
                    ListTile(
                      leading: Icon(
                        Icons.image_outlined,
                        color: canAttachImage
                            ? DesignColors.primary
                            : inactiveIconColor,
                      ),
                      title: Text(
                        'Attach Image',
                        style: TextStyle(
                          color: canAttachImage ? textColor : mutedTextColor,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      enabled: canAttachImage,
                      onTap: canAttachImage
                          ? () {
                              Navigator.pop(context);
                              unawaited(_attachImageFromDevice());
                            }
                          : null,
                    ),
                    // Touch Selection
                    ListTile(
                      leading: Icon(
                        Icons.touch_app,
                        color: _terminalMode == TerminalMode.select
                            ? DesignColors.warning
                            : inactiveIconColor,
                      ),
                      title: Text(
                        'Touch Selection',
                        style: TextStyle(
                          color: _terminalMode == TerminalMode.select
                              ? DesignColors.warning
                              : textColor,
                        ),
                      ),
                      onTap: () {
                        _toggleSelectMode();
                        Navigator.pop(context);
                      },
                    ),
                    // Paste from clipboard
                    ListTile(
                      leading: Icon(
                        Icons.content_paste,
                        color: inactiveIconColor,
                      ),
                      title: Text(
                        'Paste Clipboard',
                        style: TextStyle(color: textColor),
                      ),
                      onTap: () {
                        Navigator.pop(context);
                        _pasteFromClipboard();
                      },
                    ),
                    Divider(
                      height: 1,
                      color: isDark ? const Color(0xFF2A2B36) : Colors.grey.shade300,
                    ),
                    // Go to settings screen
                    ListTile(
                      leading: Icon(Icons.settings, color: inactiveIconColor),
                      title: Text('Settings', style: TextStyle(color: textColor)),
                      subtitle: Text(
                        'Font, theme, and other options',
                        style: TextStyle(color: mutedTextColor, fontSize: 12),
                      ),
                      onTap: () {
                        Navigator.pop(context);
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (context) => const SettingsScreen(),
                          ),
                        );
                      },
                    ),
                    Divider(
                      height: 1,
                      color: isDark ? const Color(0xFF2A2B36) : Colors.grey.shade300,
                    ),
                    // Disconnect button
                    ListTile(
                      leading: Icon(
                        Icons.power_settings_new,
                        color: DesignColors.error,
                      ),
                      title: Text(
                        'Disconnect',
                        style: TextStyle(
                          color: DesignColors.error,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      subtitle: Text(
                        'Close SSH connection',
                        style: TextStyle(color: mutedTextColor, fontSize: 12),
                      ),
                      onTap: () {
                        Navigator.pop(context);
                        _showDisconnectConfirmation();
                      },
                    ),
                    const SizedBox(height: 16),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// Show disconnect confirmation dialog
  void _showDisconnectConfirmation() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: isDark
              ? DesignColors.surfaceDark
              : DesignColors.surfaceLight,
          title: Text(
            'Disconnect?',
            style: TextStyle(color: isDark ? Colors.white : Colors.black87),
          ),
          content: Text(
            'Are you sure you want to disconnect from the server?',
            style: TextStyle(color: isDark ? Colors.white70 : Colors.black54),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(
                'Cancel',
                style: TextStyle(
                  color: isDark ? Colors.white60 : Colors.black54,
                ),
              ),
            ),
            ElevatedButton(
              onPressed: () async {
                Navigator.pop(context); // Close dialog
                await _disconnect();
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: DesignColors.error,
                foregroundColor: Colors.white,
              ),
              child: const Text('Disconnect'),
            ),
          ],
        );
      },
    );
  }

  /// Disconnect SSH and go back to the previous screen
  Future<void> _disconnect() async {
    await _stopControlClient(resetRestartState: true);

    // Disconnect SSH
    await ref.read(sshProvider.notifier).disconnect();

    // Go back to previous screen
    if (mounted) {
      Navigator.pop(context);
    }
  }

  /// Connection status indicator (displays latency, bandwidth, or reconnect status).
  Widget _buildConnectionIndicator({
    required int latency,
    required int bandwidthBitsPerSecond,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        border: Border(left: BorderSide(color: colorScheme.outline, width: 1)),
      ),
      child: _sshState.isReconnecting
          ? _buildReconnectingIndicator()
          : GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _rotateConnectionIndicatorMode,
              child: switch (_connectionIndicatorMode) {
                _ConnectionIndicatorMode.latency => _buildLatencyIndicator(
                  latency,
                ),
                _ConnectionIndicatorMode.bandwidth => _buildBandwidthIndicator(
                  bandwidthBitsPerSecond,
                ),
              },
            ),
    );
  }

  /// Latency indicator
  Widget _buildLatencyIndicator(int latency) {
    // Determine color based on latency
    Color indicatorColor;
    if (latency < 100) {
      indicatorColor = DesignColors.success; // Green: good
    } else if (latency < 300) {
      indicatorColor = DesignColors.primary; // Cyan: normal
    } else if (latency < 500) {
      indicatorColor = DesignColors.warning; // Orange: somewhat slow
    } else {
      indicatorColor = DesignColors.error; // Red: slow
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          Icons.bolt,
          size: 10,
          color: indicatorColor.withValues(alpha: 0.8),
        ),
        const SizedBox(width: 4),
        Text(
          '${latency}ms',
          style: GoogleFonts.jetBrainsMono(
            fontSize: 10,
            color: indicatorColor.withValues(alpha: 0.8),
          ),
        ),
      ],
    );
  }

  Widget _buildBandwidthIndicator(int bitsPerSecond) {
    final indicatorColor = bitsPerSecond > 0
        ? DesignColors.primary
        : Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.55);

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          Icons.swap_vert,
          size: 10,
          color: indicatorColor.withValues(alpha: 0.8),
        ),
        const SizedBox(width: 4),
        Text(
          _formatBandwidth(bitsPerSecond),
          style: GoogleFonts.jetBrainsMono(
            fontSize: 10,
            color: indicatorColor.withValues(alpha: 0.8),
          ),
        ),
      ],
    );
  }

  void _rotateConnectionIndicatorMode() {
    if (_sshState.isReconnecting || !mounted) {
      return;
    }

    setState(() {
      _connectionIndicatorMode = switch (_connectionIndicatorMode) {
        _ConnectionIndicatorMode.latency => _ConnectionIndicatorMode.bandwidth,
        _ConnectionIndicatorMode.bandwidth => _ConnectionIndicatorMode.latency,
      };
    });
  }

  String _formatBandwidth(int bitsPerSecond) {
    if (bitsPerSecond >= 1000 * 1000) {
      final megabits = bitsPerSecond / (1000 * 1000);
      final precision = megabits >= 10 ? 0 : 1;
      return '${megabits.toStringAsFixed(precision)}Mbit/s';
    }

    if (bitsPerSecond >= 1000) {
      final kilobits = bitsPerSecond / 1000;
      final precision = kilobits >= 10 ? 0 : 1;
      return '${kilobits.toStringAsFixed(precision)}kbit/s';
    }

    return '$bitsPerSecond bit/s';
  }

  /// Reconnecting indicator
  Widget _buildReconnectingIndicator() {
    final attempt = _sshState.reconnectAttempt;
    final isWaitingForNetwork = _sshState.isWaitingForNetwork;
    final nextRetryAt = _sshState.nextRetryAt;
    final queuedCount = _inputQueue.length;

    // Calculate seconds until next retry
    String? countdownText;
    if (nextRetryAt != null && !isWaitingForNetwork) {
      final remaining = nextRetryAt.difference(DateTime.now()).inSeconds;
      if (remaining > 0) {
        countdownText = '${remaining}s';
      }
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Spinner or offline icon
        if (isWaitingForNetwork)
          Icon(
            Icons.signal_wifi_off,
            size: 12,
            color: DesignColors.warning.withValues(alpha: 0.8),
          )
        else
          SizedBox(
            width: 10,
            height: 10,
            child: CircularProgressIndicator(
              strokeWidth: 1.5,
              color: DesignColors.warning.withValues(alpha: 0.8),
            ),
          ),
        const SizedBox(width: 6),

        // Status text
        Text(
          isWaitingForNetwork
              ? 'Offline'
              : 'Reconnecting${attempt > 1 ? ' ($attempt)' : ''}',
          style: GoogleFonts.jetBrainsMono(
            fontSize: 10,
            color: DesignColors.warning.withValues(alpha: 0.8),
          ),
        ),

        // Countdown
        if (countdownText != null) ...[
          const SizedBox(width: 4),
          Text(
            countdownText,
            style: GoogleFonts.jetBrainsMono(
              fontSize: 9,
              color: DesignColors.textMuted,
            ),
          ),
        ],

        // Queuing status
        if (queuedCount > 0) ...[
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
            decoration: BoxDecoration(
              color: DesignColors.primary.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              '$queuedCount chars',
              style: GoogleFonts.jetBrainsMono(
                fontSize: 9,
                color: DesignColors.primary,
              ),
            ),
          ),
        ],

        // Reconnect now button
        const SizedBox(width: 8),
        GestureDetector(
          onTap: () {
            ref.read(sshProvider.notifier).reconnectNow();
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              border: Border.all(
                color: DesignColors.warning.withValues(alpha: 0.5),
              ),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              'Retry',
              style: GoogleFonts.jetBrainsMono(
                fontSize: 9,
                color: DesignColors.warning,
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// Top-right pane indicator
  ///
  /// Displays the layout based on actual pane size ratios
  Widget _buildPaneIndicator(TmuxState tmuxState) {
    final window = tmuxState.activeWindow;
    final panes = window?.panes ?? [];
    final activePaneId = tmuxState.activePaneId;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final colorScheme = Theme.of(context).colorScheme;

    if (panes.isEmpty) {
      return const SizedBox.shrink();
    }

    // Overall indicator size
    const double indicatorSize = 48.0;

    return GestureDetector(
      onTap: () => _showPaneSelector(tmuxState),
      child: Opacity(
        opacity: 0.5,
        child: Container(
          width: indicatorSize,
          height: indicatorSize,
          padding: const EdgeInsets.all(2),
          decoration: BoxDecoration(
            color: isDark ? Colors.black26 : Colors.black12,
            borderRadius: BorderRadius.circular(4),
          ),
          child: CustomPaint(
            size: Size(indicatorSize - 4, indicatorSize - 4),
            painter: _PaneLayoutPainter(
              panes: panes,
              activePaneId: activePaneId,
              activeColor: colorScheme.primary,
              isDark: isDark,
            ),
          ),
        ),
      ),
    );
  }
}

/// CustomPainter that draws the pane layout
///
/// Uses pane_left/pane_top obtained from tmux
/// to accurately reproduce the actual layout
class _PaneLayoutPainter extends CustomPainter {
  final List<TmuxPane> panes;
  final String? activePaneId;
  final Color activeColor;
  final bool isDark;

  _PaneLayoutPainter({
    required this.panes,
    this.activePaneId,
    required this.activeColor,
    required this.isDark,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (panes.isEmpty) return;

    // Calculate the overall window size (range encompassing all panes)
    int maxRight = 0;
    int maxBottom = 0;
    for (final pane in panes) {
      final right = pane.left + pane.width;
      final bottom = pane.top + pane.height;
      if (right > maxRight) maxRight = right;
      if (bottom > maxBottom) maxBottom = bottom;
    }

    if (maxRight == 0 || maxBottom == 0) return;

    // Calculate scale factors
    final scaleX = size.width / maxRight;
    final scaleY = size.height / maxBottom;
    final gap = 1.0;

    // Draw each pane
    for (final pane in panes) {
      final isActive = pane.id == activePaneId;

      // Calculate Rect from actual position and size
      final left = pane.left * scaleX;
      final top = pane.top * scaleY;
      final width = pane.width * scaleX - gap;
      final height = pane.height * scaleY - gap;

      final rect = Rect.fromLTWH(left, top, width, height);

      // Background
      final bgPaint = Paint()
        ..color = isActive
            ? activeColor.withValues(alpha: 0.3)
            : (isDark ? Colors.black45 : Colors.grey.shade300);
      canvas.drawRect(rect, bgPaint);

      // Border
      final borderPaint = Paint()
        ..color = isActive
            ? activeColor
            : (isDark ? Colors.white30 : Colors.grey.shade500)
        ..style = PaintingStyle.stroke
        ..strokeWidth = isActive ? 1.5 : 1.0;
      canvas.drawRect(rect, borderPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _PaneLayoutPainter oldDelegate) {
    return panes != oldDelegate.panes ||
        activePaneId != oldDelegate.activePaneId ||
        activeColor != oldDelegate.activeColor ||
        isDark != oldDelegate.isDark;
  }
}

/// Widget that interactively displays the pane layout
///
/// Each pane can be selected by tapping. Also displays pane numbers.
class _PaneLayoutVisualizer extends StatelessWidget {
  final List<TmuxPane> panes;
  final String? activePaneId;
  final void Function(String paneId) onPaneSelected;

  const _PaneLayoutVisualizer({
    required this.panes,
    this.activePaneId,
    required this.onPaneSelected,
  });

  @override
  Widget build(BuildContext context) {
    if (panes.isEmpty) return const SizedBox.shrink();

    // Calculate the overall window size (range encompassing all panes)
    int maxRight = 0;
    int maxBottom = 0;
    for (final pane in panes) {
      final right = pane.left + pane.width;
      final bottom = pane.top + pane.height;
      if (right > maxRight) maxRight = right;
      if (bottom > maxBottom) maxBottom = bottom;
    }

    if (maxRight == 0 || maxBottom == 0) return const SizedBox.shrink();

    // Calculate aspect ratio
    final aspectRatio = maxRight / maxBottom;

    return Container(
      padding: const EdgeInsets.all(16),
      child: AspectRatio(
        aspectRatio: aspectRatio.clamp(0.5, 3.0),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final containerWidth = constraints.maxWidth;
            final containerHeight = constraints.maxHeight;

            // Calculate scale factors
            final scaleX = containerWidth / maxRight;
            final scaleY = containerHeight / maxBottom;
            const gap = 2.0;

            return Stack(
              children: panes.map((pane) {
                final isActive = pane.id == activePaneId;

                // Calculate Rect from actual position and size
                final left = pane.left * scaleX;
                final top = pane.top * scaleY;
                final width = pane.width * scaleX - gap;
                final height = pane.height * scaleY - gap;

                return Positioned(
                  left: left,
                  top: top,
                  width: width,
                  height: height,
                  child: GestureDetector(
                    onTap: () => onPaneSelected(pane.id),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      decoration: BoxDecoration(
                        color: isActive
                            ? DesignColors.primary.withValues(alpha: 0.3)
                            : Colors.black45,
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(
                          color: isActive
                              ? DesignColors.primary
                              : Colors.white.withValues(alpha: 0.3),
                          width: isActive ? 2 : 1,
                        ),
                      ),
                      child: Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              '${pane.index}',
                              style: GoogleFonts.jetBrainsMono(
                                fontSize: width > 60 ? 18 : 14,
                                fontWeight: FontWeight.w700,
                                color: isActive
                                    ? DesignColors.primary
                                    : Colors.white.withValues(alpha: 0.7),
                              ),
                            ),
                            if (width > 80 && height > 50) ...[
                              const SizedBox(height: 2),
                              Text(
                                '${pane.width}x${pane.height}',
                                style: GoogleFonts.jetBrainsMono(
                                  fontSize: 9,
                                  color: Colors.white.withValues(alpha: 0.5),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              }).toList(),
            );
          },
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Custom ScrollController / ScrollPosition that prevents xterm's internal
// stick-to-bottom from pushing short terminal content off-screen when the
// keyboard opens.
//
// The xterm package scrolls to maxScrollExtent in three places:
//   1. RenderTerminal.performLayout via _offset.correctBy (stick-to-bottom)
//   2. _onKeyboardShow → _scrollToBottom → position.jumpTo(maxScrollExtent)
//   3. _onInsert / onDelete / onAction → _scrollToBottom
//
// Suppression is only active when ALL of the following are true:
//   • [suppressScrollToMax] is true (keyboard visible)
//   • The scroll position is near the top (pixels ≤ threshold)
//   • The content would have fit without the keyboard
//     (maxScrollExtent ≤ viewportShrinkBudget)
//
// This allows genuinely long content to scroll to bottom normally while
// keeping short terminal content anchored at the top.
// ---------------------------------------------------------------------------

class _StableScrollController extends ScrollController {
  /// When true, scroll-to-bottom calls may be suppressed (see conditions
  /// above).
  bool suppressScrollToMax = false;

  int _unsuppressedStickToBottomPasses = 0;

  /// Total height lost by the viewport when the keyboard opened (keyboard
  /// inset + SpecialKeysBar estimate).  Used to decide whether content would
  /// have fit without the keyboard.
  double viewportShrinkBudget = 0;

  bool get shouldPreserveTopAnchorForShortContent {
    if (!hasClients) {
      return false;
    }

    final position = this.position;
    return TerminalScrollPolicy.shouldSuppressStickToBottom(
      suppressScrollToMax: suppressScrollToMax,
      pixels: position.pixels,
      maxScrollExtent: position.maxScrollExtent,
      viewportShrinkBudget: viewportShrinkBudget,
    );
  }

  void armUnsuppressedStickToBottom([int passes = 2]) {
    if (passes <= 0) {
      return;
    }
    _unsuppressedStickToBottomPasses = passes;
  }

  bool consumeUnsuppressedStickToBottom() {
    if (_unsuppressedStickToBottomPasses <= 0) {
      return false;
    }
    _unsuppressedStickToBottomPasses -= 1;
    return true;
  }

  @override
  ScrollPosition createScrollPosition(
    ScrollPhysics physics,
    ScrollContext context,
    ScrollPosition? oldPosition,
  ) {
    return _StableScrollPosition(
      physics: physics,
      context: context,
      oldPosition: oldPosition,
      initialPixels: initialScrollOffset,
      controller: this,
    );
  }
}

class _StableScrollPosition extends ScrollPositionWithSingleContext {
  _StableScrollPosition({
    required super.physics,
    required super.context,
    super.oldPosition,
    super.initialPixels,
    required this.controller,
  });

  final _StableScrollController controller;

  bool get _shouldSuppress {
    return TerminalScrollPolicy.shouldSuppressStickToBottom(
      suppressScrollToMax: controller.suppressScrollToMax,
      pixels: pixels,
      maxScrollExtent: maxScrollExtent,
      viewportShrinkBudget: controller.viewportShrinkBudget,
    );
  }

  @override
  void jumpTo(double value) {
    // Suppress xterm's _scrollToBottom which calls jumpTo(maxScrollExtent)
    if (_shouldSuppress && value >= maxScrollExtent - 1 && value > pixels) {
      if (controller.consumeUnsuppressedStickToBottom()) {
        super.jumpTo(value);
      }
      return;
    }
    super.jumpTo(value);
  }

  @override
  void correctBy(double correction) {
    // Suppress xterm's RenderTerminal._stickToBottom correctBy in
    // performLayout. The correction is always positive when sticking to
    // a newly-larger maxScrollExtent after a viewport shrink.
    if (_shouldSuppress && correction > 0) {
      if (controller.consumeUnsuppressedStickToBottom()) {
        super.correctBy(correction);
      }
      return;
    }
    super.correctBy(correction);
  }
}
