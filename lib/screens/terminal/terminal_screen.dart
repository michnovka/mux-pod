import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
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
import '../../services/terminal/terminal_output_normalizer.dart';
import '../../services/terminal/terminal_snapshot.dart';
import '../../services/terminal/xterm_input_adapter.dart';
import '../../services/tmux/pane_navigator.dart';
import '../../services/tmux/tmux_commands.dart';
import '../../services/tmux/tmux_control_client.dart';
import '../../services/tmux/tmux_parser.dart' show TmuxPane;
import '../../theme/design_colors.dart';
import '../../widgets/special_keys_bar.dart';
import '../../providers/terminal_display_provider.dart';
import '../settings/settings_screen.dart';
import 'widgets/pane_history_view.dart';
import 'widgets/pane_terminal_view.dart';

/// Terminal mode used by the mobile UI.
enum TerminalMode { normal, select, history }

enum _ConnectionIndicatorMode { latency, bandwidth }

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

  const _PendingKeyboardModifiers({required this.ctrl, required this.alt});

  bool get isEmpty => !ctrl && !alt;
}

class _PaneRenderCacheEntry {
  final Terminal terminal;
  final TerminalSnapshotFrame frame;
  final PaneTerminalViewportState viewportState;

  const _PaneRenderCacheEntry({
    required this.terminal,
    required this.frame,
    required this.viewportState,
  });
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

class _PaneHistoryCacheEntry {
  final String paneId;
  final String content;
  final int loadedLineCount;
  final int retainedLineLimit;
  final bool reachedHistoryStart;
  final bool alternateScreen;
  final bool isSeedOnly;

  const _PaneHistoryCacheEntry({
    required this.paneId,
    required this.content,
    required this.loadedLineCount,
    required this.retainedLineLimit,
    required this.reachedHistoryStart,
    required this.alternateScreen,
    required this.isSeedOnly,
  });

  _PaneHistoryCacheEntry copyWith({
    String? content,
    int? loadedLineCount,
    int? retainedLineLimit,
    bool? reachedHistoryStart,
    bool? alternateScreen,
    bool? isSeedOnly,
  }) {
    return _PaneHistoryCacheEntry(
      paneId: paneId,
      content: content ?? this.content,
      loadedLineCount: loadedLineCount ?? this.loadedLineCount,
      retainedLineLimit: retainedLineLimit ?? this.retainedLineLimit,
      reachedHistoryStart: reachedHistoryStart ?? this.reachedHistoryStart,
      alternateScreen: alternateScreen ?? this.alternateScreen,
      isSeedOnly: isSeedOnly ?? this.isSeedOnly,
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
  static const Duration _historyCacheRefreshThrottle = Duration(
    milliseconds: 500,
  );
  static const Duration _initialControlRestartDelay = Duration(
    milliseconds: 250,
  );
  static const Duration _maxControlRestartDelay = Duration(seconds: 4);
  static const double _historyBottomThresholdPx = 24;
  static const double _historyRevealOffsetPx = 96;
  static const String _snapshotMainMarker = '\x01__MUXPOD_MAIN__\x01';
  static const String _snapshotAltMarker = '\x01__MUXPOD_ALT__\x01';
  static const String _snapshotMetadataMarker = '\x01__MUXPOD_META__\x01';

  final _secureStorage = SecureStorageService();
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  final _paneTerminalViewKey = GlobalKey<PaneTerminalViewState>();
  final _terminalScrollController = _StableScrollController();
  final _historyVerticalScrollController = ScrollController();
  final _historyHorizontalScrollController = ScrollController();
  late Terminal _terminal;
  final _terminalController = TerminalController();
  int _terminalScrollbackLines = AppSettings().scrollbackLines;
  final Map<String, _PaneRenderCacheEntry> _paneRenderCache = {};
  final Map<String, _PaneHistoryCacheEntry> _paneHistoryCache = {};
  final _historyPendingLinesNotifier = ValueNotifier<int>(0);

  // Connection state (managed locally)
  bool _isConnecting = false;
  bool _isSwitchingPane = false;
  bool _showSwitchingOverlay = false;
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
  Timer? _latencyTimer;
  Timer? _bandwidthTimer;
  Timer? _historyCacheRefreshTimer;
  int _controlRestartAttempt = 0;
  bool _isLatencyProbeInFlight = false;
  bool _isResyncingPane = false;
  bool _isHistoryLoading = false;
  double _lastKeyboardInset = 0;
  _ConnectionIndicatorMode _connectionIndicatorMode =
      _ConnectionIndicatorMode.latency;
  int _lastBandwidthSampleTotalBytes = 0;
  DateTime? _lastBandwidthSampleAt;

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
    _historyVerticalScrollController.addListener(_handleHistorySurfaceScroll);
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
    _stopLatencyPolling(resetValue: true);
    unawaited(_stopControlClient(resetRestartState: true));
    WakelockPlus.disable();
  }

  /// Resume live terminal streaming when returning to foreground.
  void _resumePolling() {
    if (!_isInBackground || _isDisposed) return;
    _isInBackground = false;
    _applyKeepScreenOn();
    _startLatencyPolling();
    unawaited(_restartTerminalStream(restartControlClient: true));
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
        unawaited(_resyncActivePane(refreshTree: false));
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
    );
    await _flushInputQueue();
    _startLatencyPolling();

    // Update UI
    if (mounted) setState(() {});
  }

  void _startLatencyPolling() {
    _stopLatencyPolling();
    if (_isDisposed || _isInBackground) {
      return;
    }

    _startBandwidthPolling();
    unawaited(_refreshLatency());
    _latencyTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      unawaited(_refreshLatency());
    });
  }

  void _stopLatencyPolling({bool resetValue = false}) {
    _latencyTimer?.cancel();
    _latencyTimer = null;
    _isLatencyProbeInFlight = false;
    _stopBandwidthPolling(resetValue: resetValue);
    if (resetValue && !_isDisposed) {
      _latencyNotifier.value = 0;
    }
  }

  void _startBandwidthPolling() {
    _stopBandwidthPolling();
    if (_isDisposed || _isInBackground) {
      return;
    }

    final sshClient = _sshNotifier?.client;
    _lastBandwidthSampleTotalBytes = sshClient?.totalPayloadBytes ?? 0;
    _lastBandwidthSampleAt = DateTime.now();

    _bandwidthTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _refreshBandwidth();
    });
  }

  void _stopBandwidthPolling({bool resetValue = false}) {
    _bandwidthTimer?.cancel();
    _bandwidthTimer = null;
    _lastBandwidthSampleTotalBytes = 0;
    _lastBandwidthSampleAt = null;
    if (resetValue && !_isDisposed) {
      _bandwidthNotifier.value = 0;
    }
  }

  void _refreshBandwidth() {
    if (_isDisposed || _isInBackground || !mounted) {
      return;
    }

    final sshClient = _sshNotifier?.client;
    if (sshClient == null || !sshClient.isConnected) {
      return;
    }

    final now = DateTime.now();
    final lastSampleAt = _lastBandwidthSampleAt;
    if (lastSampleAt == null) {
      _lastBandwidthSampleAt = now;
      _lastBandwidthSampleTotalBytes = sshClient.totalPayloadBytes;
      return;
    }

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

  Future<void> _refreshLatency() async {
    if (_isDisposed || _isInBackground || _isLatencyProbeInFlight || !mounted) {
      return;
    }

    final sshClient = _sshNotifier?.client;
    if (sshClient == null || !sshClient.isConnected) {
      return;
    }

    _isLatencyProbeInFlight = true;
    final startTime = DateTime.now();

    try {
      await sshClient.exec('true', timeout: const Duration(seconds: 3));
      if (!_isDisposed && mounted) {
        _latencyNotifier.value = DateTime.now()
            .difference(startTime)
            .inMilliseconds;
      }
    } catch (_) {
      // Ignore latency probe failures. Connection keep-alive and reconnect
      // paths already own transport error handling.
    } finally {
      _isLatencyProbeInFlight = false;
    }
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
    _paneHistoryCache.clear();
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
      cursorVisible: _terminal.cursorVisibleMode,
      originMode: _terminal.originMode,
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
    );
  }

  bool _restorePaneRenderState(String? paneId) {
    if (paneId == null) {
      return false;
    }

    final cacheEntry = _paneRenderCache[paneId];
    if (cacheEntry == null) {
      return false;
    }

    _terminalController.clearSelection();
    cacheEntry.terminal.onOutput = _handleTerminalOutput;
    _terminal = cacheEntry.terminal;
    _pendingViewData = cacheEntry.frame;
    _viewNotifier.value = cacheEntry.frame;
    _hasInitialScrolled = true;
    _isHistoryLoading = false;
    _paneTerminalViewKey.currentState?.restoreViewportState(
      cacheEntry.viewportState,
    );
    return true;
  }

  void _showPlaceholderPane(TmuxPane? pane) {
    _terminalController.clearSelection();
    _resetTerminalEmulator();
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
    _isHistoryLoading = false;
  }

  bool _showActivePaneFromCacheOrPlaceholder() {
    final tmuxState = ref.read(tmuxProvider);
    final activePane = tmuxState.activePane;
    final restored = _restorePaneRenderState(activePane?.id);
    if (!restored) {
      _showPlaceholderPane(activePane);
    }

    if (activePane != null) {
      ref.read(terminalDisplayProvider.notifier).updatePane(activePane);
      _seedHistoryCacheForActivePane(rebuild: false);
      _keepHistorySurfacePinnedToLiveTail();
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

  _PaneHistoryCacheEntry? get _activeHistoryEntry {
    final paneId = ref.read(tmuxProvider).activePaneId;
    if (paneId == null) {
      return null;
    }
    return _paneHistoryCache[paneId];
  }

  String _normalizeHistoryText(String text) {
    return _trimSingleTrailingNewline(text.replaceAll('\r\n', '\n'));
  }

  List<String> _historyLines(String content) {
    if (content.isEmpty) {
      return const [];
    }
    return content.split('\n');
  }

  int _historyLineCount(String content) => _historyLines(content).length;

  bool _isNearHistorySurfaceBottom(ScrollMetrics metrics) {
    return (metrics.maxScrollExtent - metrics.pixels) <=
        _historyBottomThresholdPx;
  }

  bool _historyEntriesEqual(
    _PaneHistoryCacheEntry? left,
    _PaneHistoryCacheEntry right,
  ) {
    if (left == null) {
      return false;
    }

    return left.content == right.content &&
        left.loadedLineCount == right.loadedLineCount &&
        left.retainedLineLimit == right.retainedLineLimit &&
        left.reachedHistoryStart == right.reachedHistoryStart &&
        left.alternateScreen == right.alternateScreen &&
        left.isSeedOnly == right.isSeedOnly;
  }

  String _captureVisibleTerminalText() {
    final buffer = _terminal.buffer;
    if (buffer.height <= 0 || buffer.viewWidth <= 0) {
      return '';
    }

    final startLine = math.max(0, buffer.height - buffer.viewHeight);
    final endLine = math.max(0, buffer.height - 1);

    return _normalizeHistoryText(
      buffer.getText(
        BufferRangeLine(
          CellOffset(0, startLine),
          CellOffset(math.max(0, buffer.viewWidth - 1), endLine),
        ),
      ),
    );
  }

  String _captureLiveTailHistoryText() {
    return _normalizeHistoryText(_terminal.buffer.getText());
  }

  int _historyOverlapLineCount(
    List<String> olderLines,
    List<String> liveLines,
  ) {
    if (olderLines.isEmpty || liveLines.isEmpty) {
      return 0;
    }

    final maxOverlap = math.min(olderLines.length, liveLines.length);
    for (var overlap = maxOverlap; overlap > 0; overlap -= 1) {
      var matches = true;
      for (var index = 0; index < overlap; index += 1) {
        if (olderLines[olderLines.length - overlap + index].trimRight() !=
            liveLines[index].trimRight()) {
          matches = false;
          break;
        }
      }
      if (matches) {
        return overlap;
      }
    }

    return 0;
  }

  String _historyContentAboveLiveTail(
    String capturedText, {
    String? liveTailText,
  }) {
    final historyLines = _historyLines(_normalizeHistoryText(capturedText));
    if (historyLines.isEmpty) {
      return '';
    }

    final liveLines = _historyLines(liveTailText ?? _captureVisibleTerminalText());
    final overlap = _historyOverlapLineCount(historyLines, liveLines);
    final olderLines = overlap <= 0
        ? historyLines
        : historyLines.sublist(0, historyLines.length - overlap);
    return olderLines.join('\n');
  }

  List<String> _trimHistoryLinesToRetainedLimit(List<String> lines, int limit) {
    if (limit <= 0 || lines.length <= limit) {
      return lines;
    }
    return lines.sublist(lines.length - limit);
  }

  String _mergeHistoryWithRecentTail({
    required String baseContent,
    required String recentContent,
    required int retainedLineLimit,
  }) {
    final baseLines = _historyLines(baseContent);
    final recentLines = _historyLines(recentContent);
    if (baseLines.isEmpty) {
      return recentContent;
    }
    if (recentLines.isEmpty) {
      return baseContent;
    }

    final overlap = _historyOverlapLineCount(baseLines, recentLines);
    final mergedLines = <String>[
      ...baseLines.take(baseLines.length - overlap),
      ...recentLines,
    ];
    return _trimHistoryLinesToRetainedLimit(
      mergedLines,
      retainedLineLimit,
    ).join('\n');
  }

  bool _seedHistoryCacheForActivePane({bool rebuild = true}) {
    final paneId = ref.read(tmuxProvider).activePaneId;
    if (paneId == null) {
      return false;
    }

    final retainedLineLimit = ref.read(settingsProvider).scrollbackLines;
    final alternateScreen = _viewNotifier.value.alternateScreen;
    final existingEntry = _paneHistoryCache[paneId];

    late final _PaneHistoryCacheEntry nextEntry;
    if (alternateScreen) {
      nextEntry =
          existingEntry?.copyWith(
            retainedLineLimit: retainedLineLimit,
            alternateScreen: true,
            isSeedOnly: true,
          ) ??
          _PaneHistoryCacheEntry(
            paneId: paneId,
            content: '',
            loadedLineCount: 0,
            retainedLineLimit: retainedLineLimit,
            reachedHistoryStart: false,
            alternateScreen: true,
            isSeedOnly: true,
          );
    } else {
      final recentHistoryContent = _historyContentAboveLiveTail(
        _captureLiveTailHistoryText(),
      );
      if (existingEntry != null &&
          !existingEntry.isSeedOnly &&
          !existingEntry.alternateScreen) {
        final mergedContent = _mergeHistoryWithRecentTail(
          baseContent: existingEntry.content,
          recentContent: recentHistoryContent,
          retainedLineLimit: retainedLineLimit,
        );
        nextEntry = existingEntry.copyWith(
          content: mergedContent,
          loadedLineCount: _historyLineCount(mergedContent),
          retainedLineLimit: retainedLineLimit,
          alternateScreen: false,
        );
      } else {
        nextEntry = _PaneHistoryCacheEntry(
          paneId: paneId,
          content: recentHistoryContent,
          loadedLineCount: _historyLineCount(recentHistoryContent),
          retainedLineLimit: retainedLineLimit,
          reachedHistoryStart: false,
          alternateScreen: false,
          isSeedOnly: true,
        );
      }
    }

    if (_historyEntriesEqual(existingEntry, nextEntry)) {
      return false;
    }

    _paneHistoryCache[paneId] = nextEntry;

    if (mounted &&
        rebuild &&
        ref.read(tmuxProvider).activePaneId == paneId) {
      setState(() {});
    }

    return true;
  }

  void _scheduleHistoryCacheRefresh() {
    if (_terminalMode == TerminalMode.history || _isDisposed) {
      return;
    }

    if (_historyCacheRefreshTimer != null) {
      return;
    }

    _historyCacheRefreshTimer = Timer(_historyCacheRefreshThrottle, () {
      _historyCacheRefreshTimer = null;
      if (!mounted || _isDisposed || _terminalMode == TerminalMode.history) {
        return;
      }

      final changed = _seedHistoryCacheForActivePane();
      if (changed) {
        _keepHistorySurfacePinnedToLiveTail();
      }
    });
  }

  void _keepHistorySurfacePinnedToLiveTail() {
    if (_terminalMode == TerminalMode.history) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_historyVerticalScrollController.hasClients) {
        return;
      }

      final position = _historyVerticalScrollController.position;
      if (_isNearHistorySurfaceBottom(position)) {
        position.jumpTo(position.maxScrollExtent);
      }
    });
  }

  void _scrollHistorySurfaceToLiveTail({bool animate = false}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_historyVerticalScrollController.hasClients) {
        return;
      }

      final position = _historyVerticalScrollController.position;
      final target = position.maxScrollExtent;
      if (animate) {
        unawaited(
          position.animateTo(
            target,
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
          ),
        );
      } else {
        position.jumpTo(target);
      }
      _paneTerminalViewKey.currentState?.scrollToBottom();
    });
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

      _terminalScrollController.armUnsuppressedStickToBottom();
      _paneTerminalViewKey.currentState?.scrollToBottom();
      _scrollHistorySurfaceToLiveTail();
    });
  }

  void _handleHistorySurfaceScroll() {
    if (!mounted || !_historyVerticalScrollController.hasClients) {
      return;
    }

    if (_viewNotifier.value.alternateScreen) {
      if (_terminalMode == TerminalMode.history) {
        setState(() {
          _terminalMode = TerminalMode.normal;
        });
      }
      return;
    }

    final browsingHistory = !_isNearHistorySurfaceBottom(
      _historyVerticalScrollController.position,
    );

    if (browsingHistory) {
      if (_terminalMode == TerminalMode.select) {
        _terminalController.clearSelection();
        _flushDeferredStreamOutput();
      }
      if (_terminalMode != TerminalMode.history) {
        _historyCacheRefreshTimer?.cancel();
        _historyCacheRefreshTimer = null;
        _seedHistoryCacheForActivePane(rebuild: false);
        _ensureFullHistoryLoadedForActivePane();
        setState(() {
          _terminalMode = TerminalMode.history;
        });
      }
      return;
    }

    if (_terminalMode == TerminalMode.history) {
      setState(() {
        _terminalMode = TerminalMode.normal;
      });
      _seedHistoryCacheForActivePane();
    }

    if (_historyPendingLinesNotifier.value != 0) {
      _historyPendingLinesNotifier.value = 0;
    }
  }

  void _ensureFullHistoryLoadedForActivePane() {
    final activePane = ref.read(tmuxProvider).activePane;
    if (activePane == null || _viewNotifier.value.alternateScreen) {
      return;
    }

    final retainedLineLimit = ref.read(settingsProvider).scrollbackLines;
    final existingEntry = _paneHistoryCache[activePane.id];
    final alreadyLoaded =
        existingEntry != null &&
        !existingEntry.isSeedOnly &&
        !existingEntry.alternateScreen &&
        existingEntry.retainedLineLimit == retainedLineLimit;
    if (alreadyLoaded) {
      return;
    }

    unawaited(_loadFullHistorySnapshot(activePane.id));
  }

  Future<void> _enterHistoryMode() async {
    if (_terminalMode == TerminalMode.select) {
      setState(() {
        _terminalMode = TerminalMode.normal;
      });
      _flushDeferredStreamOutput();
    }

    if (ref.read(tmuxProvider).activePane == null) {
      return;
    }

    _terminalController.clearSelection();
    _historyPendingLinesNotifier.value = 0;
    final changed = _seedHistoryCacheForActivePane();
    if (changed) {
      _keepHistorySurfacePinnedToLiveTail();
    }
    _ensureFullHistoryLoadedForActivePane();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_historyVerticalScrollController.hasClients) {
        return;
      }
      if (_historyHorizontalScrollController.hasClients) {
        _historyHorizontalScrollController.jumpTo(
          _historyHorizontalScrollController.position.minScrollExtent,
        );
      }

      final position = _historyVerticalScrollController.position;
      final target = math.max(
        position.minScrollExtent,
        position.maxScrollExtent - _historyRevealOffsetPx,
      );
      if ((position.pixels - target).abs() <= 0.5) {
        return;
      }
      unawaited(
        position.animateTo(
          target,
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
        ),
      );
    });
  }

  void _exitHistoryMode({bool jumpToLive = false}) {
    if (_terminalMode != TerminalMode.history && !jumpToLive) {
      return;
    }

    _historyPendingLinesNotifier.value = 0;
    if (_historyHorizontalScrollController.hasClients) {
      _historyHorizontalScrollController.jumpTo(
        _historyHorizontalScrollController.position.minScrollExtent,
      );
    }
    _scrollHistorySurfaceToLiveTail(animate: jumpToLive);
  }

  void _recordHistoryPendingLinesFromTerminalAdvance({
    required int beforeAbsoluteCursorY,
  }) {
    final afterAbsoluteCursorY = _terminal.buffer.absoluteCursorY;
    final delta = afterAbsoluteCursorY - beforeAbsoluteCursorY;
    if (delta > 0) {
      _historyPendingLinesNotifier.value += delta;
    }
  }

  Future<void> _loadFullHistorySnapshot(String paneId) async {
    final activePaneId = ref.read(tmuxProvider).activePaneId;
    if (_isHistoryLoading && activePaneId == paneId) {
      return;
    }

    final sshClient = ref.read(sshProvider.notifier).client;
    if (sshClient == null || !sshClient.isConnected) {
      if (mounted && activePaneId == paneId) {
        setState(() {
          _isHistoryLoading = false;
        });
      }
      return;
    }

    final existingEntry = _paneHistoryCache[paneId];
    if (existingEntry?.alternateScreen == true || _viewNotifier.value.alternateScreen) {
      if (mounted && activePaneId == paneId) {
        setState(() {
          _isHistoryLoading = false;
        });
      }
      return;
    }

    final maxHistoryLines = ref.read(settingsProvider).scrollbackLines;
    if (maxHistoryLines <= 0) {
      if (mounted && activePaneId == paneId) {
        setState(() {
          _isHistoryLoading = false;
        });
      }
      return;
    }

    if (mounted && activePaneId == paneId) {
      setState(() {
        _isHistoryLoading = true;
      });
    }

    try {
      final historyOutput = await sshClient.execPersistent(
        TmuxCommands.capturePane(
          paneId,
          escapeSequences: true,
          preserveTrailingSpaces: true,
          startLine: -maxHistoryLines,
        ),
        timeout: const Duration(seconds: 4),
      );

      final visibleLiveTail = _captureVisibleTerminalText();
      final fullHistoryContent = _historyContentAboveLiveTail(
        historyOutput,
        liveTailText: visibleLiveTail,
      );
      final mergedContent = _mergeHistoryWithRecentTail(
        baseContent: fullHistoryContent,
        recentContent: _historyContentAboveLiveTail(
          _captureLiveTailHistoryText(),
          liveTailText: visibleLiveTail,
        ),
        retainedLineLimit: maxHistoryLines,
      );

      final oldPixels = _historyVerticalScrollController.hasClients
          ? _historyVerticalScrollController.position.pixels
          : 0.0;
      final oldMaxExtent = _historyVerticalScrollController.hasClients &&
              _historyVerticalScrollController.position.hasContentDimensions
          ? _historyVerticalScrollController.position.maxScrollExtent
          : 0.0;
      final keepPinnedToBottom =
          !_historyVerticalScrollController.hasClients ||
          (_historyVerticalScrollController.position.hasContentDimensions &&
              _isNearHistorySurfaceBottom(
                _historyVerticalScrollController.position,
              ));

      final capturedLineCount = _historyLineCount(fullHistoryContent);
      _paneHistoryCache[paneId] = _PaneHistoryCacheEntry(
        paneId: paneId,
        content: mergedContent,
        loadedLineCount: _historyLineCount(mergedContent),
        retainedLineLimit: maxHistoryLines,
        reachedHistoryStart: capturedLineCount < maxHistoryLines,
        alternateScreen: false,
        isSeedOnly: false,
      );

      if (mounted && ref.read(tmuxProvider).activePaneId == paneId) {
        setState(() {
          _isHistoryLoading = false;
        });
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || !_historyVerticalScrollController.hasClients) {
            return;
          }

          final position = _historyVerticalScrollController.position;
          if (keepPinnedToBottom) {
            position.jumpTo(position.maxScrollExtent);
            return;
          }

          final delta = position.maxScrollExtent - oldMaxExtent;
          final target = (oldPixels + delta).clamp(
            position.minScrollExtent,
            position.maxScrollExtent,
          );
          position.jumpTo(target);
        });
      }
    } catch (_) {
      if (mounted && ref.read(tmuxProvider).activePaneId == paneId) {
        setState(() {
          _isHistoryLoading = false;
        });
      }
    }
  }

  String _historyModeTitle(_PaneHistoryCacheEntry? entry) {
    if (entry?.alternateScreen == true) {
      return 'Alternate screen active';
    }
    if (_isHistoryLoading) {
      return 'Loading retained history...';
    }
    if (entry == null) {
      return 'History';
    }
    if (entry.isSeedOnly) {
      return 'Recent history only';
    }
    if (entry.reachedHistoryStart) {
      return 'Start of retained history';
    }
    return 'Retained limit reached';
  }

  String _historyModeDetail(_PaneHistoryCacheEntry? entry) {
    if (entry?.alternateScreen == true) {
      return 'Alternate-screen apps keep their own viewport. Jump to live to interact with them.';
    }
    if (entry == null) {
      return 'Scroll up through retained tmux output while the live terminal stays pinned below.';
    }
    if (_isHistoryLoading) {
      return 'Showing recent local history while tmux fetches up to ${entry.retainedLineLimit} retained lines.';
    }
    if (entry.isSeedOnly) {
      return 'Showing recent local scrollback only.';
    }
    if (entry.reachedHistoryStart) {
      return '${entry.loadedLineCount} retained lines loaded.';
    }
    return 'Showing the newest ${entry.loadedLineCount} of up to ${entry.retainedLineLimit} retained lines.';
  }

  void _leaveHistoryModeBeforeSwitch() {
    if (_terminalMode == TerminalMode.history) {
      _exitHistoryMode();
    }
    _isHistoryLoading = false;
    _historyPendingLinesNotifier.value = 0;
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
    _paneHistoryCache.removeWhere(
      (paneId, _) => !validPaneIds.contains(paneId),
    );
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

      await _restartTerminalStream(
        restartControlClient: true,
        refreshTree: false,
      );
      _startLatencyPolling();

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
      _stopLatencyPolling(resetValue: true);
      if (!mounted) return;
      setState(() {
        _isConnecting = false;
        _connectionError = e.message;
      });
    } catch (e) {
      _stopLatencyPolling(resetValue: true);
      if (!mounted) return;
      setState(() {
        _isConnecting = false;
        _connectionError = e.toString();
      });
      _showErrorSnackBar(e.toString());
    }
  }

  /// Fetch and update the entire session tree.
  Future<void> _refreshSessionTree({bool syncActive = false}) async {
    if (_isDisposed) {
      return;
    }
    final sshClient = ref.read(sshProvider.notifier).client;
    if (sshClient == null || !sshClient.isConnected) {
      return;
    }

    try {
      final cmd = TmuxCommands.listAllPanes();
      final output = await sshClient.execPersistent(cmd);
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

  void _scheduleControlSync({bool resyncPane = false}) {
    _shouldResyncAfterControlRefresh =
        _shouldResyncAfterControlRefresh || resyncPane;
    _controlSyncTimer?.cancel();
    _controlSyncTimer = Timer(const Duration(milliseconds: 120), () async {
      if (!mounted || _isDisposed) {
        return;
      }

      final shouldResync = _shouldResyncAfterControlRefresh;
      _shouldResyncAfterControlRefresh = false;
      await _refreshSessionTree(syncActive: true);
      if (shouldResync) {
        await _resyncActivePane(refreshTree: false);
      }
    });
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
      await _restartTerminalStream(restartControlClient: true);
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
    _cancelControlClientRestart(resetAttempts: resetRestartState);
    final controlClient = _controlClient;
    _controlClient = null;
    _controlClientSessionName = null;
    await controlClient?.dispose();
  }

  Future<void> _restartTerminalStream({
    bool restartControlClient = false,
    bool refreshTree = true,
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

    if (shouldRestartControlClient) {
      await _stopControlClient();
    }

    await _resyncActivePane(refreshTree: refreshTree);

    if (shouldRestartControlClient) {
      await _startControlClient(sessionName);
      if (!mounted || _isDisposed) {
        return;
      }
      await _resyncActivePane(refreshTree: false);
    }
  }

  void _handleControlPaneOutput(String paneId, String data) {
    if (!mounted || _isDisposed || data.isEmpty) {
      return;
    }

    final activePaneId = ref.read(tmuxProvider).activePaneId;
    if (activePaneId != paneId) {
      return;
    }

    if (_terminalMode == TerminalMode.select || _isResyncingPane) {
      _deferredStreamOutput.write(data);
      return;
    }

    final cursorBeforeWrite = _terminal.buffer.absoluteCursorY;
    final shouldAutoScroll =
        _paneTerminalViewKey.currentState?.shouldAutoFollow ?? true;
    _terminal.write(data);
    if (_terminalMode == TerminalMode.history) {
      _recordHistoryPendingLinesFromTerminalAdvance(
        beforeAbsoluteCursorY: cursorBeforeWrite,
      );
      _paneTerminalViewKey.currentState?.scrollToBottom();
      return;
    }
    _scheduleHistoryCacheRefresh();
    if (shouldAutoScroll || !_hasInitialScrolled) {
      _hasInitialScrolled = true;
      _paneTerminalViewKey.currentState?.scrollToBottom();
    }
  }

  void _handleControlNotification(TmuxControlNotification notification) {
    if (!mounted || _isDisposed) {
      return;
    }

    switch (notification.name) {
      case 'layout-change':
      case 'pane-mode-changed':
      case 'session-changed':
      case 'sessions-changed':
      case 'unlinked-window-add':
      case 'unlinked-window-close':
      case 'window-add':
      case 'window-close':
      case 'window-pane-changed':
      case 'window-renamed':
        _scheduleControlSync(resyncPane: true);
        break;
      case 'exit':
        _handleControlClientClosed();
        break;
    }
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
        _isResyncingPane) {
      return;
    }

    final bufferedOutput = _deferredStreamOutput.takeAll();
    final cursorBeforeWrite = _terminal.buffer.absoluteCursorY;
    final shouldAutoScroll =
        _paneTerminalViewKey.currentState?.shouldAutoFollow ?? true;
    _terminal.write(bufferedOutput);
    if (_terminalMode == TerminalMode.history) {
      _recordHistoryPendingLinesFromTerminalAdvance(
        beforeAbsoluteCursorY: cursorBeforeWrite,
      );
      _paneTerminalViewKey.currentState?.scrollToBottom();
      return;
    }
    _scheduleHistoryCacheRefresh();
    if (shouldAutoScroll) {
      _paneTerminalViewKey.currentState?.scrollToBottom();
    }
  }

  String _buildPaneSnapshotCommand(String paneId) {
    final alternateOnCommand = TmuxCommands.getPaneAlternateOn(paneId);
    final metadataCommand = TmuxCommands.getPaneSnapshotMetadata(paneId);
    final mainSnapshotCommand = TmuxCommands.capturePane(
      paneId,
      escapeSequences: true,
      preserveTrailingSpaces: true,
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

  Future<void> _resyncActivePane({bool refreshTree = true}) async {
    if (_isDisposed || _isResyncingPane) {
      return;
    }

    final sshClient = ref.read(sshProvider.notifier).client;
    if (sshClient == null || !sshClient.isConnected) {
      return;
    }

    try {
      _isResyncingPane = true;

      if (refreshTree) {
        await _refreshSessionTree(syncActive: true);
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

      final snapshotCommand = _buildPaneSnapshotCommand(activePane.id);

      final startTime = DateTime.now();
      final combinedOutput = await sshClient.execPersistent(
        snapshotCommand,
        timeout: const Duration(seconds: 2),
      );
      final latency = DateTime.now().difference(startTime).inMilliseconds;
      if (!_isDisposed) {
        _latencyNotifier.value = latency;
      }

      if (!mounted || _isDisposed) {
        return;
      }

      final snapshotPayload = _parseSnapshotPayload(combinedOutput);

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
        final autoWrapMode = _parseTmuxFlag(
          metadataParts.length > 8 ? metadataParts[8] : null,
          fallback: nextView.autoWrapMode,
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
          autoWrapMode: autoWrapMode,
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

      _applyResyncUpdate(nextView);

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
    } else if (_terminalMode == TerminalMode.history) {
      _paneTerminalViewKey.currentState?.scrollToBottom();
    }

    // Scroll to bottom on first content received
    if (!_hasInitialScrolled && _pendingViewData.content.isNotEmpty) {
      _hasInitialScrolled = true;
      _paneTerminalViewKey.currentState?.scrollToBottom();
    }

    if (_terminalMode != TerminalMode.history) {
      final changed = _seedHistoryCacheForActivePane();
      if (changed) {
        _keepHistorySurfacePinnedToLiveTail();
      }
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

  /// Show error SnackBar
  void _showErrorSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.red,
        action: SnackBarAction(
          label: 'Retry',
          textColor: Colors.white,
          onPressed: _connectAndSetup,
        ),
      ),
    );
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
    _historyCacheRefreshTimer?.cancel();
    _historyCacheRefreshTimer = null;
    _stopLatencyPolling();
    unawaited(_stopControlClient(resetRestartState: true));
    // Dispose ValueNotifier
    _viewNotifier.dispose();
    _latencyNotifier.dispose();
    _bandwidthNotifier.dispose();
    _historyPendingLinesNotifier.dispose();
    // Dispose scroll controller
    _terminalScrollController.dispose();
    _historyVerticalScrollController.removeListener(_handleHistorySurfaceScroll);
    _historyVerticalScrollController.dispose();
    _historyHorizontalScrollController.dispose();
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
                  color: switch (_terminalMode) {
                    TerminalMode.select => DesignColors.warning,
                    TerminalMode.history => DesignColors.primary,
                    TerminalMode.normal => Colors.transparent,
                  },
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
                              final historyEntry = _activeHistoryEntry;
                              final historyContent = historyEntry?.content ?? '';
                              final canBrowseHistory = !viewData.alternateScreen;
                              final showHistoryBlock =
                                  canBrowseHistory &&
                                  (historyContent.isNotEmpty || _isHistoryLoading);

                              return LayoutBuilder(
                                builder: (context, constraints) {
                                  final liveHeight = constraints.maxHeight;

                                  return Scrollbar(
                                    controller: _historyVerticalScrollController,
                                    thumbVisibility:
                                        _terminalMode == TerminalMode.history &&
                                        canBrowseHistory,
                                    trackVisibility:
                                        _terminalMode == TerminalMode.history &&
                                        canBrowseHistory,
                                    interactive: true,
                                    child: SingleChildScrollView(
                                      controller:
                                          _historyVerticalScrollController,
                                      physics: canBrowseHistory
                                          ? const ClampingScrollPhysics()
                                          : const NeverScrollableScrollPhysics(),
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.stretch,
                                        children: [
                                          if (showHistoryBlock)
                                            PaneHistoryView(
                                              content: historyContent,
                                              paneWidth: viewData.paneWidth,
                                              backgroundColor: backgroundColor,
                                              foregroundColor: foregroundColor,
                                              zoomScale: _zoomScale,
                                              renderContent:
                                                  _terminalMode ==
                                                  TerminalMode.history,
                                              verticalScrollController:
                                                  _historyVerticalScrollController,
                                              horizontalScrollController:
                                                  _historyHorizontalScrollController,
                                              isLoading: _isHistoryLoading,
                                              alternateScreen:
                                                  historyEntry?.alternateScreen ??
                                                  false,
                                              isSeedOnly:
                                                  historyEntry?.isSeedOnly ?? true,
                                              reachedHistoryStart:
                                                  historyEntry
                                                      ?.reachedHistoryStart ??
                                                  false,
                                              loadedLineCount:
                                                  historyEntry?.loadedLineCount ??
                                                  0,
                                              retainedLineLimit:
                                                  historyEntry
                                                      ?.retainedLineLimit ??
                                                  ref
                                                      .read(settingsProvider)
                                                      .scrollbackLines,
                                            ),
                                          SizedBox(
                                            height: liveHeight,
                                            child: PaneTerminalView(
                                              key: _paneTerminalViewKey,
                                              terminal: _terminal,
                                              terminalController:
                                                  _terminalController,
                                              paneWidth: viewData.paneWidth,
                                              paneHeight: viewData.paneHeight,
                                              backgroundColor: backgroundColor,
                                              foregroundColor: foregroundColor,
                                              mode:
                                                  _terminalMode ==
                                                      TerminalMode.select
                                                  ? PaneTerminalMode.select
                                                  : PaneTerminalMode.normal,
                                              readOnly:
                                                  _terminalMode ==
                                                  TerminalMode.history,
                                              verticalScrollEnabled:
                                                  viewData.alternateScreen,
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
                                              onTwoFingerSwipe:
                                                  _handleTwoFingerSwipe,
                                              navigableDirections:
                                                  _getNavigableDirections(),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  );
                                },
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
                        if (_terminalMode == TerminalMode.history)
                          _buildHistoryModeOverlay(),
                      ],
                    ),
                  ),
                ),
              ),
              // SpecialKeysBar: only shown when the on-screen keyboard is visible
              if (keyboardVisible && _terminalMode != TerminalMode.history)
                SpecialKeysBar(
                  onLiteralKeyPressed: _sendLiteralKey,
                  onSpecialKeyPressed: _sendSpecialKey,
                  onCtrlToggle: _toggleCtrlModifier,
                  onAltToggle: _toggleAltModifier,
                  ctrlPressed: _ctrlModifierPressed,
                  altPressed: _altModifierPressed,
                ),
            ],
          ),
          // Loading overlay. During cached pane restores we keep the terminal
          // visible and only use a transparent barrier so input cannot race the
          // in-flight remote pane/window/session switch.
          if (_isConnecting || _isSwitchingPane || sshState.isConnecting)
            Container(
              color:
                  (_isConnecting ||
                      sshState.isConnecting ||
                      _showSwitchingOverlay)
                  ? (isDark ? Colors.black54 : Colors.white70)
                  : Colors.transparent,
              child:
                  (_isConnecting ||
                      sshState.isConnecting ||
                      _showSwitchingOverlay)
                  ? const Center(child: CircularProgressIndicator())
                  : null,
            ),
          // Error overlay
          if (_connectionError != null || sshState.hasError)
            _buildErrorOverlay(sshState.error ?? _connectionError),
        ],
      ),
    );
  }

  Widget _buildHistoryModeOverlay() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final chipColor = isDark
        ? Colors.black.withValues(alpha: 0.72)
        : Colors.white.withValues(alpha: 0.92);
    final textColor = Theme.of(context).colorScheme.onSurface;
    final historyEntry = _activeHistoryEntry;
    final title = _historyModeTitle(historyEntry);
    final detail = _historyModeDetail(historyEntry);

    return Stack(
      children: [
        Positioned(
          top: 8,
          left: 8,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: chipColor,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(
                color: DesignColors.primary.withValues(alpha: 0.25),
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Padding(
                    padding: EdgeInsets.only(top: 2),
                    child: Icon(
                      Icons.history,
                      size: 16,
                      color: DesignColors.primary,
                    ),
                  ),
                  const SizedBox(width: 8),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 260),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: GoogleFonts.jetBrainsMono(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: textColor,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          detail,
                          style: GoogleFonts.jetBrainsMono(
                            fontSize: 10,
                            height: 1.3,
                            fontWeight: FontWeight.w500,
                            color: textColor.withValues(alpha: 0.76),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        Positioned(
          right: 12,
          bottom: 12,
          child: ValueListenableBuilder<int>(
            valueListenable: _historyPendingLinesNotifier,
            builder: (context, pendingLines, _) {
              return Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: () => _exitHistoryMode(jumpToLive: true),
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
                          pendingLines > 0
                              ? 'Jump to live · $pendingLines new'
                              : 'Jump to live',
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
        ),
      ],
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

  _PendingKeyboardModifiers? _consumePendingKeyboardModifiers() {
    if (!_ctrlModifierPressed && !_altModifierPressed) {
      return null;
    }

    final modifiers = _PendingKeyboardModifiers(
      ctrl: _ctrlModifierPressed,
      alt: _altModifierPressed,
    );
    if (mounted && !_isDisposed) {
      setState(() {
        _ctrlModifierPressed = false;
        _altModifierPressed = false;
      });
    } else {
      _ctrlModifierPressed = false;
      _altModifierPressed = false;
    }
    return modifiers;
  }

  void _ensureTerminalViewportAtBottomForInput() {
    if (_terminalMode == TerminalMode.history) {
      if (mounted) {
        setState(() {
          _terminalMode = TerminalMode.normal;
        });
      } else {
        _terminalMode = TerminalMode.normal;
      }
      _historyPendingLinesNotifier.value = 0;
      _scrollHistorySurfaceToLiveTail();
    }

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

    _leaveHistoryModeBeforeSwitch();
    final previousSelection = _TmuxTargetSelection.fromState(
      ref.read(tmuxProvider),
    );
    if (previousSelection.sessionName == sessionName) {
      return;
    }

    _cachePaneRenderState(paneId: previousSelection.paneId);
    ref.read(tmuxProvider.notifier).setActiveSession(sessionName);

    final nextPane = ref.read(tmuxProvider).activePane;
    final restoredFromCache = _showActivePaneFromCacheOrPlaceholder();
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

    _leaveHistoryModeBeforeSwitch();
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
    final restoredFromCache = _showActivePaneFromCacheOrPlaceholder();
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

    _leaveHistoryModeBeforeSwitch();
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
      await _restartTerminalStream(refreshTree: false);
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
                    _buildBreadcrumbItem(
                      currentWindow,
                      icon: Icons.tab,
                      isSelected: true,
                      onTap: () => _showWindowSelector(tmuxState),
                    ),
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
            // Select mode indicator
            if (_terminalMode == TerminalMode.select)
              Container(
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
                      Icons.content_copy,
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
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      Icon(Icons.folder, color: colorScheme.primary),
                      const SizedBox(width: 8),
                      Text(
                        'Select Session',
                        style: GoogleFonts.spaceGrotesk(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                          color: colorScheme.onSurface,
                        ),
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
                      return ListTile(
                        leading: Icon(
                          Icons.folder,
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
                        trailing: isActive
                            ? Icon(Icons.check, color: colorScheme.primary)
                            : null,
                        onTap: () {
                          Navigator.pop(context);
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

  /// Show window selection dialog
  void _showWindowSelector(TmuxState tmuxState) {
    final session = tmuxState.activeSession;
    if (session == null) return;

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
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      Icon(Icons.tab, color: colorScheme.primary),
                      const SizedBox(width: 8),
                      Text(
                        'Select Window',
                        style: GoogleFonts.spaceGrotesk(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                          color: colorScheme.onSurface,
                        ),
                      ),
                    ],
                  ),
                ),
                Divider(height: 1, color: colorScheme.outline),
                Flexible(
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: session.windows.length,
                    itemBuilder: (context, index) {
                      final window = session.windows[index];
                      final isActive =
                          window.index == tmuxState.activeWindowIndex;
                      return ListTile(
                        leading: Icon(
                          Icons.tab,
                          color: isActive
                              ? colorScheme.primary
                              : colorScheme.onSurface.withValues(alpha: 0.6),
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
                        subtitle: Text(
                          '${window.paneCount} panes',
                          style: TextStyle(
                            color: colorScheme.onSurface.withValues(
                              alpha: 0.38,
                            ),
                          ),
                        ),
                        trailing: isActive
                            ? Icon(Icons.check, color: colorScheme.primary)
                            : null,
                        onTap: () {
                          Navigator.pop(context);
                          _selectWindow(session.name, window.index);
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
    if (window == null) return;

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
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maxHeight),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      Icon(Icons.terminal, color: colorScheme.primary),
                      const SizedBox(width: 8),
                      Text(
                        'Select Pane',
                        style: GoogleFonts.spaceGrotesk(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                          color: colorScheme.onSurface,
                        ),
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
                        trailing: isActive
                            ? Icon(Icons.check, color: colorScheme.primary)
                            : null,
                        onTap: () {
                          Navigator.pop(context);
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
                  color: colorScheme.onSurface.withValues(alpha: 0.05),
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
                color: isActive
                    ? colorScheme.primary
                    : (isSelected
                          ? colorScheme.onSurface
                          : colorScheme.onSurface.withValues(alpha: 0.6)),
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

    showModalBottomSheet(
      context: context,
      backgroundColor: menuBgColor,
      isDismissible: true,
      enableDrag: true,
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
              ListTile(
                leading: Icon(
                  Icons.history,
                  color: _terminalMode == TerminalMode.history
                      ? DesignColors.primary
                      : inactiveIconColor,
                ),
                title: Text(
                  _terminalMode == TerminalMode.history
                      ? 'Browsing History'
                      : 'Browse History',
                  style: TextStyle(
                    color: _terminalMode == TerminalMode.history
                        ? DesignColors.primary
                        : textColor,
                    fontWeight: _terminalMode == TerminalMode.history
                        ? FontWeight.bold
                        : FontWeight.normal,
                  ),
                ),
                subtitle: Text(
                  _terminalMode == TerminalMode.history
                      ? 'Unified scroll view; live output continues in the slab below'
                      : 'Scroll upward or tap here to reveal retained output above the live terminal',
                  style: TextStyle(color: mutedTextColor, fontSize: 12),
                ),
                onTap: () {
                  Navigator.pop(context);
                  if (_terminalMode == TerminalMode.history) {
                    _exitHistoryMode(jumpToLive: true);
                  } else {
                    unawaited(_enterHistoryMode());
                  }
                },
              ),
              ListTile(
                leading: Icon(
                  _terminalMode == TerminalMode.select
                      ? Icons.content_copy
                      : Icons.keyboard,
                  color: _terminalMode == TerminalMode.select
                      ? DesignColors.warning
                      : inactiveIconColor,
                ),
                title: Text(
                  _terminalMode == TerminalMode.select
                      ? 'Select Mode'
                      : 'Touch Selection',
                  style: TextStyle(
                    color: _terminalMode == TerminalMode.select
                        ? DesignColors.warning
                        : textColor,
                    fontWeight: _terminalMode == TerminalMode.select
                        ? FontWeight.bold
                        : FontWeight.normal,
                  ),
                ),
                subtitle: Text(
                  _terminalMode == TerminalMode.history
                      ? 'Unavailable while browsing retained history'
                      : _terminalMode == TerminalMode.select
                      ? 'Selection is local and live terminal input is paused'
                      : 'Enable touch selection and local copying',
                  style: TextStyle(color: mutedTextColor, fontSize: 12),
                ),
                trailing: Switch(
                  value: _terminalMode == TerminalMode.select,
                  onChanged: _terminalMode == TerminalMode.history
                      ? null
                      : (value) {
                          setState(() {
                            _terminalMode = value
                                ? TerminalMode.select
                                : TerminalMode.normal;
                          });
                          if (value) {
                            _terminalController.clearSelection();
                          } else {
                            _flushDeferredStreamOutput();
                          }
                          Navigator.pop(context);
                        },
                  activeThumbColor: DesignColors.warning,
                ),
                onTap: _terminalMode == TerminalMode.history
                    ? null
                    : () {
                        final enteringSelect =
                            _terminalMode != TerminalMode.select;
                        setState(() {
                          _terminalMode = enteringSelect
                              ? TerminalMode.select
                              : TerminalMode.normal;
                        });
                        if (enteringSelect) {
                          _terminalController.clearSelection();
                        } else {
                          _flushDeferredStreamOutput();
                        }
                        Navigator.pop(context);
                      },
              ),
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
                _ConnectionIndicatorMode.bandwidth =>
                  _buildBandwidthIndicator(bandwidthBitsPerSecond),
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

  /// Threshold in pixels — positions within this range from the top are
  /// considered "at the top".
  static const double _nearTopThreshold = 2.0;

  bool get _shouldSuppress {
    if (!controller.suppressScrollToMax || pixels > _nearTopThreshold) {
      return false;
    }
    // Only suppress if the content would have fit in the full viewport
    // (before the keyboard appeared).  For genuinely long content
    // maxScrollExtent far exceeds the viewport shrink budget.
    return maxScrollExtent <= controller.viewportShrinkBudget;
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
