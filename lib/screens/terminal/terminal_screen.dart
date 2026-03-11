import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:xterm/xterm.dart';

import '../../providers/active_session_provider.dart';
import '../../providers/connection_provider.dart';
import '../../providers/settings_provider.dart';
import '../../providers/ssh_provider.dart';
import '../../providers/tmux_provider.dart';
import '../../services/keychain/secure_storage.dart';
import '../../services/network/network_monitor.dart';
import '../../services/ssh/input_queue.dart';
import '../../services/ssh/ssh_client.dart' show SshConnectOptions;
import '../../services/terminal/xterm_input_adapter.dart';
import '../../services/tmux/pane_navigator.dart';
import '../../services/tmux/tmux_commands.dart';
import '../../services/tmux/tmux_control_client.dart';
import '../../services/tmux/tmux_parser.dart' show TmuxPane;
import '../../theme/design_colors.dart';
import '../../widgets/special_keys_bar.dart';
import '../../providers/terminal_display_provider.dart';
import '../settings/settings_screen.dart';
import 'widgets/pane_terminal_view.dart';

/// Terminal mode used by the mobile UI.
enum TerminalMode {
  normal,
  select,
}

/// Terminal display data used to seed or resync the emulator surface.
///
/// Managed via ValueNotifier to avoid parent widget setState().
/// This prevents parent rebuilds during BottomSheet display,
/// enabling stable operation even with isDismissible: true.
class _TerminalViewData {
  final String content;
  final int paneWidth;
  final int paneHeight;
  final int cursorX;
  final int cursorY;

  const _TerminalViewData({
    this.content = '',
    this.paneWidth = 80,
    this.paneHeight = 24,
    this.cursorX = 0,
    this.cursorY = 0,
  });

  _TerminalViewData copyWith({
    String? content,
    int? paneWidth,
    int? paneHeight,
    int? cursorX,
    int? cursorY,
  }) =>
      _TerminalViewData(
        content: content ?? this.content,
        paneWidth: paneWidth ?? this.paneWidth,
        paneHeight: paneHeight ?? this.paneHeight,
        cursorX: cursorX ?? this.cursorX,
        cursorY: cursorY ?? this.cursorY,
      );
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
  final _secureStorage = SecureStorageService();
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  final _paneTerminalViewKey = GlobalKey<PaneTerminalViewState>();
  final _terminalScrollController = ScrollController();
  late Terminal _terminal;
  final _terminalController = TerminalController();
  int _terminalScrollbackLines = AppSettings().scrollbackLines;

  // Connection state (managed locally)
  bool _isConnecting = false;
  String? _connectionError;
  SshState _sshState = const SshState();

  // Terminal display data used for bootstrap/resync (managed via ValueNotifier)
  final _viewNotifier = ValueNotifier<_TerminalViewData>(const _TerminalViewData());
  final _latencyNotifier = ValueNotifier<int>(0);
  final _deferredStreamOutput = StringBuffer();

  TmuxControlClient? _controlClient;
  String? _controlClientSessionName;
  Timer? _controlSyncTimer;
  bool _isResyncingPane = false;
  bool _shouldResyncAfterControlRefresh = false;
  bool _isDisposed = false;

  // For frame skipping (optimization for infrequent snapshot resyncs)
  static const _minFrameInterval = Duration(milliseconds: 16); // ~60fps
  DateTime _lastFrameTime = DateTime.now();
  bool _pendingUpdate = false;
  _TerminalViewData _pendingViewData = const _TerminalViewData();

  // Initial scroll completed flag
  bool _hasInitialScrolled = false;

  // Terminal mode
  TerminalMode _terminalMode = TerminalMode.normal;

  // Zoom scale
  double _zoomScale = 1.0;

  // EnterCommand input content retention (persists even after closing bottom sheet)
  String _savedCommandInput = '';

  // Input queue (holds input during disconnection)
  final _inputQueue = InputQueue();

  // Background state
  bool _isInBackground = false;

  // Local cache of directInput setting (to avoid ref.watch)
  bool _directInputEnabled = true;

  // Riverpod listeners
  ProviderSubscription<SshState>? _sshSubscription;
  ProviderSubscription<TmuxState>? _tmuxSubscription;
  ProviderSubscription<AppSettings>? _settingsSubscription;
  ProviderSubscription<AsyncValue<NetworkStatus>>? _networkSubscription;

  @override
  void initState() {
    super.initState();
    _terminal = Terminal(
      maxLines: _terminalScrollbackLines,
      reflowEnabled: false,
    )..onOutput = _handleTerminalOutput;
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
    unawaited(_stopControlClient());
    WakelockPlus.disable();
  }

  /// Resume live terminal streaming when returning to foreground.
  void _resumePolling() {
    if (!_isInBackground || _isDisposed) return;
    _isInBackground = false;
    _applyKeepScreenOn();
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
    _sshSubscription = ref.listenManual<SshState>(
      sshProvider,
      (previous, next) {
        if (!mounted || _isDisposed) return;
        setState(() {
          _sshState = next;
        });
      },
      fireImmediately: true,
    );

    // Monitor Tmux state changes
    // Note: Parent setState() is not needed. Breadcrumbs and pane indicators
    // directly watch tmuxProvider via Consumer widgets, so they are
    // only rebuilt within the subtree.
    _tmuxSubscription = ref.listenManual<TmuxState>(
      tmuxProvider,
      (previous, next) {
        // Consumer widgets directly watch tmuxProvider, so
        // parent setState() is not needed (removed for BottomSheet stability)
      },
      fireImmediately: true,
    );

    // Monitor settings changes (for Keep screen on / directInput)
    _settingsSubscription = ref.listenManual<AppSettings>(
      settingsProvider,
      (previous, next) {
        if (!mounted || _isDisposed) return;
        if (previous?.keepScreenOn != next.keepScreenOn) {
          _applyKeepScreenOn();
        }
        if (previous?.directInputEnabled != next.directInputEnabled) {
          setState(() {
            _directInputEnabled = next.directInputEnabled;
          });
        }
        if (previous?.scrollbackLines != next.scrollbackLines) {
          _reconfigureTerminal(next);
          unawaited(_resyncActivePane(refreshTree: false));
        }
      },
      fireImmediately: false,
    );

    // Explicitly set initial value
    _directInputEnabled = ref.read(settingsProvider).directInputEnabled;
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
    final sshNotifier = ref.read(sshProvider.notifier);
    sshNotifier.onReconnectSuccess = _onReconnectSuccess;
  }

  /// Handler for successful reconnection
  Future<void> _onReconnectSuccess() async {
    if (!mounted || _isDisposed) return;

    await _stopControlClient();
    await _refreshSessionTree(syncActive: true);
    await _restartTerminalStream(restartControlClient: true, refreshTree: false);
    await _flushInputQueue();

    // Update UI
    if (mounted) setState(() {});
  }

  /// Send queued input
  Future<void> _flushInputQueue() async {
    if (_inputQueue.isEmpty) return;

    final queuedInput = _inputQueue.flush();
    if (queuedInput.isNotEmpty) {
      await _sendTerminalData(queuedInput);
    }
  }

  void _reconfigureTerminal(AppSettings settings) {
    if (_terminalScrollbackLines == settings.scrollbackLines) {
      _terminal.onOutput = _handleTerminalOutput;
      return;
    }
    _terminalScrollbackLines = settings.scrollbackLines;
    _terminal = Terminal(
      maxLines: settings.scrollbackLines,
      reflowEnabled: false,
    )..onOutput = _handleTerminalOutput;
    if (mounted) {
      setState(() {});
    }
  }

  /// Connect via SSH and set up tmux session
  Future<void> _connectAndSetup() async {
    if (!mounted) {
      return;
    }
    setState(() {
      _isConnecting = true;
      _connectionError = null;
    });

    try {
      // 1. Get connection info
      final connection = ref.read(connectionsProvider.notifier).getById(widget.connectionId);
      if (connection == null) {
        throw Exception('Connection not found');
      }

      // 2. Get authentication info
      final options = await _getAuthOptions(connection);
      if (!mounted || _isDisposed) {
        return;
      }

      // 3. SSH connection (no shell startup - exec only)
      final sshNotifier = ref.read(sshProvider.notifier);
      await sshNotifier.connectWithoutShell(connection, options);
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
          await sshClient?.execPersistent(TmuxCommands.newSession(
            name: widget.sessionName!,
            detached: true,
          ));
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
    } catch (e) {
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

  Future<void> _startControlClient(String sessionName) async {
    if (_isDisposed || _isInBackground) {
      return;
    }
    if (_controlClient != null &&
        _controlClientSessionName == sessionName &&
        _controlClient!.isStarted) {
      return;
    }

    await _stopControlClient();

    final sshClient = ref.read(sshProvider.notifier).client;
    if (sshClient == null || !sshClient.isConnected) {
      return;
    }

    final controlClient = TmuxControlClient(
      sshClient,
      onPaneOutput: _handleControlPaneOutput,
      onNotification: _handleControlNotification,
      onError: _handleControlClientError,
      onClosed: _handleControlClientClosed,
    );

    await controlClient.start(sessionName: sessionName);
    _controlClient = controlClient;
    _controlClientSessionName = sessionName;
  }

  Future<void> _stopControlClient() async {
    _controlSyncTimer?.cancel();
    _controlSyncTimer = null;
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
      await _stopControlClient();
      return;
    }

    if (restartControlClient ||
        _controlClientSessionName != sessionName ||
        _controlClient == null ||
        !_controlClient!.isStarted) {
      await _startControlClient(sessionName);
    }

    await _resyncActivePane(refreshTree: refreshTree);
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

    _terminal.write(data);
    if (!_hasInitialScrolled) {
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
    unawaited(_restartTerminalStream(restartControlClient: true));
  }

  void _handleControlClientClosed() {
    if (_isDisposed || _isInBackground) {
      return;
    }

    final sshState = ref.read(sshProvider);
    if (!sshState.isConnected) {
      if (!sshState.isReconnecting) {
        unawaited(_attemptReconnect());
      }
      return;
    }

    unawaited(_restartTerminalStream(restartControlClient: true));
  }

  void _flushDeferredStreamOutput() {
    if (_deferredStreamOutput.length == 0 ||
        _terminalMode == TerminalMode.select ||
        _isResyncingPane) {
      return;
    }

    final bufferedOutput = _deferredStreamOutput.toString();
    _deferredStreamOutput.clear();
    _terminal.write(bufferedOutput);
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
        _viewNotifier.value = _viewNotifier.value.copyWith(content: '');
        _applyTerminalFrame(_viewNotifier.value);
        _hasInitialScrolled = false;
        return;
      }

      final scrollbackLines = ref.read(settingsProvider).scrollbackLines;
      final metadataCommand = TmuxCommands.getPaneSnapshotMetadata(activePane.id);
      final snapshotCommand = '''
__muxpod_meta=\$($metadataCommand);
__muxpod_alt=\${__muxpod_meta%%,*};
if [ "\$__muxpod_alt" = "1" ]; then
  ${TmuxCommands.capturePane(activePane.id, escapeSequences: true, alternateScreen: true, quiet: true)};
else
  ${TmuxCommands.capturePane(activePane.id, escapeSequences: true, startLine: -scrollbackLines)};
fi;
printf '%s\n' "\$__muxpod_meta"
''';

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

      final lines = combinedOutput.split('\n');
      final metadataLine = lines.isNotEmpty ? lines.removeLast() : '';
      final rawSnapshot = lines.join('\n');
      final processedSnapshot = rawSnapshot.endsWith('\n')
          ? rawSnapshot.substring(0, rawSnapshot.length - 1)
          : rawSnapshot;

      var nextView = _viewNotifier.value.copyWith(
        content: processedSnapshot,
        paneWidth: activePane.width,
        paneHeight: activePane.height,
        cursorX: activePane.cursorX,
        cursorY: activePane.cursorY,
      );

      final metadataParts = metadataLine.trim().split(',');
      if (metadataParts.length >= 5) {
        final x = int.tryParse(metadataParts[1]);
        final y = int.tryParse(metadataParts[2]);
        final w = int.tryParse(metadataParts[3]);
        final h = int.tryParse(metadataParts[4]);

        if (w != null && h != null) {
          nextView = nextView.copyWith(
            paneWidth: w,
            paneHeight: h,
          );
          ref.read(terminalDisplayProvider.notifier).updatePane(
            activePane.copyWith(width: w, height: h),
          );
        }

        if (x != null && y != null) {
          ref.read(tmuxProvider.notifier).updateCursorPosition(activePane.id, x, y);
          nextView = nextView.copyWith(cursorX: x, cursorY: y);
        }
      }

      _scheduleUpdate(nextView);
    } catch (_) {
      final currentState = ref.read(sshProvider);
      if (!currentState.isReconnecting) {
        unawaited(_attemptReconnect());
      }
    } finally {
      _isResyncingPane = false;
      _flushDeferredStreamOutput();
    }
  }

  /// Schedule update considering frame skipping
  ///
  /// Throttle to avoid updating every frame during high-frequency updates (htop, etc.).
  /// Consecutive updates within 16ms (~60fps) are deferred to the next frame.
  void _scheduleUpdate(_TerminalViewData viewData) {
    _pendingViewData = viewData;

    // Do nothing if an update is already scheduled
    if (_pendingUpdate) return;

    final now = DateTime.now();
    final elapsed = now.difference(_lastFrameTime);

    if (elapsed >= _minFrameInterval) {
      // Enough time has elapsed, update immediately
      _applyUpdate();
    } else {
      // Frame skip: update on the next frame
      _pendingUpdate = true;
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _isDisposed) return;
        _pendingUpdate = false;
        _applyUpdate();
      });
    }
  }

  /// Apply pending update
  void _applyUpdate() {
    if (!mounted || _isDisposed) return;
    _lastFrameTime = DateTime.now();
    _viewNotifier.value = _pendingViewData;
    _applyTerminalFrame(_pendingViewData);
    if (_terminalMode == TerminalMode.normal) {
      _paneTerminalViewKey.currentState?.scrollToBottom();
    }

    // Scroll to bottom on first content received
    if (!_hasInitialScrolled && _pendingViewData.content.isNotEmpty) {
      _hasInitialScrolled = true;
      _paneTerminalViewKey.currentState?.scrollToBottom();
    }
  }

  void _applyTerminalFrame(_TerminalViewData viewData) {
    final cursorRow = viewData.cursorY + 1;
    final cursorColumn = viewData.cursorX + 1;
    final cursorVisibility = ref.read(settingsProvider).showTerminalCursor
        ? '\x1b[?25h'
        : '\x1b[?25l';
    final frame =
        '\x1b[?25l\x1b[H\x1b[2J\x1b[3J${viewData.content}'
        '\x1b[$cursorRow;${cursorColumn}H'
        '$cursorVisibility';

    _terminal.resize(viewData.paneWidth, viewData.paneHeight);
    _terminal.mainBuffer.clear();
    _terminal.altBuffer.clear();
    _terminal.buffer.clear();
    _terminalController.clearSelection();
    _terminal.write(frame);
  }

  void _handleTerminalOutput(String data) {
    if (_terminalMode == TerminalMode.select) {
      return;
    }
    unawaited(_sendTerminalData(data));
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
    ref.read(sshProvider.notifier).onReconnectSuccess = null;
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
    unawaited(_stopControlClient());
    // Dispose ValueNotifier
    _viewNotifier.dispose();
    _latencyNotifier.dispose();
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
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: _terminalMode == TerminalMode.select
                          ? DesignColors.warning
                          : Colors.transparent,
                      width: 3,
                    ),
                  ),
                  child: Stack(
                    children: [
                      RepaintBoundary(
                        child: ValueListenableBuilder<_TerminalViewData>(
                          valueListenable: _viewNotifier,
                          builder: (context, viewData, _) {
                            return PaneTerminalView(
                              key: _paneTerminalViewKey,
                              terminal: _terminal,
                              terminalController: _terminalController,
                              paneWidth: viewData.paneWidth,
                              paneHeight: viewData.paneHeight,
                              backgroundColor:
                                  Theme.of(context).scaffoldBackgroundColor,
                              foregroundColor: Theme.of(context)
                                  .colorScheme
                                  .onSurface
                                  .withValues(alpha: 0.9),
                              mode: _terminalMode == TerminalMode.select
                                  ? PaneTerminalMode.select
                                  : PaneTerminalMode.normal,
                              zoomEnabled: true,
                              showCursor:
                                  ref.watch(settingsProvider).showTerminalCursor,
                              onZoomChanged: (scale) {
                                setState(() {
                                  _zoomScale = scale;
                                });
                              },
                              verticalScrollController:
                                  _terminalScrollController,
                              onTwoFingerSwipe: _handleTwoFingerSwipe,
                              navigableDirections: _getNavigableDirections(),
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
                    ],
                  ),
                ),
              ),
              SpecialKeysBar(
                onKeyPressed: _sendLiteralKey,
                onSpecialKeyPressed: _sendSpecialKey,
                onInputTap: _terminalMode == TerminalMode.select
                    ? null
                    : _showInputDialog,
                directInputEnabled: _directInputEnabled,
                onDirectInputToggle: () {
                  ref.read(settingsProvider.notifier).toggleDirectInput();
                },
              ),
            ],
          ),
          // Loading overlay
          if (_isConnecting || sshState.isConnecting)
            Container(
              color: isDark ? Colors.black54 : Colors.white70,
              child: const Center(
                child: CircularProgressIndicator(),
              ),
            ),
          // Error overlay
          if (_connectionError != null || sshState.hasError)
            _buildErrorOverlay(sshState.error ?? _connectionError),
        ],
      ),
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
      await sshClient.execPersistentInput(
        TmuxCommands.sendKeys(target, data, literal: true),
        timeout: const Duration(seconds: 2),
      );
    } catch (_) {
      // Silently ignore key send errors.
    }
  }

  void _sendLiteralKey(String key) {
    if (_terminalMode == TerminalMode.select) {
      return;
    }
    XtermInputAdapter.sendText(_terminal, key);
  }

  void _sendSpecialKey(String tmuxKey) {
    if (_terminalMode == TerminalMode.select) {
      return;
    }
    XtermInputAdapter.sendTmuxKey(_terminal, tmuxKey);
  }

  /// Select session
  Future<void> _selectSession(String sessionName) async {
    final sshClient = ref.read(sshProvider.notifier).client;
    if (sshClient == null) return;

    final previousPaneId = ref.read(tmuxProvider).activePaneId;
    await _refreshSessionTree();
    // Update active session in tmux_provider
    ref.read(tmuxProvider.notifier).setActiveSession(sessionName);

    final nextPane = ref.read(tmuxProvider).activePane;
    if (nextPane == null) {
      await _stopControlClient();
      _viewNotifier.value = _viewNotifier.value.copyWith(content: '');
      _applyTerminalFrame(_viewNotifier.value);
      _hasInitialScrolled = false;
      return;
    }

    try {
      if (previousPaneId != null && previousPaneId != nextPane.id) {
        await sshClient.execPersistentInput(
          TmuxCommands.sendKeys(previousPaneId, '\x1b[O', literal: true),
        );
      }
      await _restartTerminalStream(
        restartControlClient: true,
        refreshTree: false,
      );
      await sshClient.execPersistentInput(
        TmuxCommands.sendKeys(nextPane.id, '\x1b[I', literal: true),
      );
    } catch (_) {
      return;
    }
  }

  /// Select window
  Future<void> _selectWindow(String sessionName, int windowIndex) async {
    final sshClient = ref.read(sshProvider.notifier).client;
    if (sshClient == null || !sshClient.isConnected) return;

    // Also switch session if it differs
    final currentSession = ref.read(tmuxProvider).activeSessionName;
    if (currentSession != sessionName) {
      ref.read(tmuxProvider.notifier).setActiveSession(sessionName);
    }

    try {
      await sshClient.execPersistent(TmuxCommands.selectWindow(sessionName, windowIndex));
      await _refreshSessionTree(syncActive: true);
    } catch (_) {
      return;
    }
    if (!mounted || _isDisposed) return;

    // Update active window in tmux_provider
    ref.read(tmuxProvider.notifier).setActiveWindow(windowIndex);

    final activePane = ref.read(tmuxProvider).activePane;
    if (activePane == null) {
      _viewNotifier.value = _viewNotifier.value.copyWith(content: '');
      _applyTerminalFrame(_viewNotifier.value);
      _hasInitialScrolled = false;
      return;
    }

    try {
      await _restartTerminalStream(refreshTree: false);
      await sshClient.execPersistentInput(
        TmuxCommands.sendKeys(activePane.id, '\x1b[I', literal: true),
      );
    } catch (_) {
      return;
    }
  }

  /// Select pane
  Future<void> _selectPane(String paneId) async {
    final sshClient = ref.read(sshProvider.notifier).client;
    if (sshClient == null || !sshClient.isConnected) return;

    final oldPaneId = ref.read(tmuxProvider).activePaneId;

    try {
      // Send focus-out to the previous pane
      if (oldPaneId != null && oldPaneId != paneId) {
        await sshClient.execPersistentInput(
          TmuxCommands.sendKeys(oldPaneId, '\x1b[O', literal: true),
        );
      }

      await sshClient.execPersistent(TmuxCommands.selectPane(paneId));
      await _refreshSessionTree(syncActive: true);

      // Send focus-in to the new pane (so apps like Claude Code can detect focus)
      await sshClient.execPersistentInput(
        TmuxCommands.sendKeys(paneId, '\x1b[I', literal: true),
      );
    } catch (_) {
      return;
    }
    if (!mounted || _isDisposed) return;

    // Update active pane in tmux_provider
    ref.read(tmuxProvider.notifier).setActivePane(paneId);

    // Notify TerminalDisplayProvider of pane info (for font size calculation)
    final activePane = ref.read(tmuxProvider).activePane;
    final tmuxState = ref.read(tmuxProvider);
    if (activePane != null) {
      ref.read(terminalDisplayProvider.notifier).updatePane(activePane);
      _viewNotifier.value = _viewNotifier.value.copyWith(
        paneWidth: activePane.width,
        paneHeight: activePane.height,
        content: '',
      );
      await _restartTerminalStream(refreshTree: false);

      // Save session info (for restoration)
      final sessionName = tmuxState.activeSessionName;
      final windowIndex = tmuxState.activeWindowIndex;
      if (sessionName != null && windowIndex != null) {
        ref.read(activeSessionsProvider.notifier).updateLastPane(
              connectionId: widget.connectionId,
              sessionName: sessionName,
              windowIndex: windowIndex,
              paneId: paneId,
            );
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
              color: isWaitingForNetwork ? DesignColors.warning : colorScheme.error,
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
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: DesignColors.primary.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.keyboard,
                      size: 16,
                      color: DesignColors.primary,
                    ),
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
                  border: Border.all(color: DesignColors.warning.withValues(alpha: 0.5)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.content_copy, size: 12, color: DesignColors.warning),
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
            // Latency / Reconnect indicator
            ValueListenableBuilder<int>(
              valueListenable: _latencyNotifier,
              builder: (context, latency, _) => _buildConnectionIndicator(latency),
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
                      final isActive = session.name == tmuxState.activeSessionName;
                      return ListTile(
                        leading: Icon(
                          Icons.folder,
                          color: isActive ? colorScheme.primary : colorScheme.onSurface.withValues(alpha: 0.6),
                        ),
                        title: Text(
                          session.name,
                          style: TextStyle(
                            color: isActive ? colorScheme.primary : colorScheme.onSurface,
                            fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
                          ),
                        ),
                        subtitle: Text(
                          '${session.windowCount} windows',
                          style: TextStyle(color: colorScheme.onSurface.withValues(alpha: 0.38)),
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
                      final isActive = window.index == tmuxState.activeWindowIndex;
                      return ListTile(
                        leading: Icon(
                          Icons.tab,
                          color: isActive ? colorScheme.primary : colorScheme.onSurface.withValues(alpha: 0.6),
                        ),
                        title: Text(
                          '${window.index}: ${window.name}',
                          style: TextStyle(
                            color: isActive ? colorScheme.primary : colorScheme.onSurface,
                            fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
                          ),
                        ),
                        subtitle: Text(
                          '${window.paneCount} panes',
                          style: TextStyle(color: colorScheme.onSurface.withValues(alpha: 0.38)),
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
                                  : colorScheme.onSurface.withValues(alpha: 0.1),
                            ),
                          ),
                          child: Center(
                            child: Text(
                              '${pane.index}',
                              style: GoogleFonts.jetBrainsMono(
                                fontSize: 14,
                                fontWeight: FontWeight.w700,
                                color: isActive ? colorScheme.primary : colorScheme.onSurface.withValues(alpha: 0.6),
                              ),
                            ),
                          ),
                        ),
                        title: Text(
                          paneTitle,
                          style: TextStyle(
                            color: isActive ? colorScheme.primary : colorScheme.onSurface,
                            fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
                          ),
                        ),
                        subtitle: Text(
                          '${pane.width}x${pane.height}',
                          style: TextStyle(color: colorScheme.onSurface.withValues(alpha: 0.38)),
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
                border: Border.all(color: colorScheme.onSurface.withValues(alpha: 0.05)),
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
                    : (isSelected ? colorScheme.onSurface : colorScheme.onSurface.withValues(alpha: 0.6)),
              ),
              const SizedBox(width: 4),
            ],
            Text(
              label.isEmpty ? '...' : label,
              style: GoogleFonts.jetBrainsMono(
                fontSize: 11,
                fontWeight: isActive || isSelected ? FontWeight.w700 : FontWeight.w400,
                color: isActive
                    ? colorScheme.primary
                    : (isSelected ? colorScheme.onSurface : colorScheme.onSurface.withValues(alpha: 0.5)),
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
    final menuBgColor = isDark ? DesignColors.surfaceDark : DesignColors.surfaceLight;
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
              Divider(height: 1, color: isDark ? const Color(0xFF2A2B36) : Colors.grey.shade300),
              // Mode switching (Normal / Scroll & Select)
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
                      : 'Normal Mode',
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
                  _terminalMode == TerminalMode.select
                      ? 'Selection is local and input is paused'
                      : 'Tap to enable touch selection and copying',
                  style: TextStyle(color: mutedTextColor, fontSize: 12),
                ),
                trailing: Switch(
                  value: _terminalMode == TerminalMode.select,
                  onChanged: (value) {
                    final newMode = value
                        ? TerminalMode.select
                        : TerminalMode.normal;
                    setState(() {
                      _terminalMode = newMode;
                    });
                    if (newMode == TerminalMode.normal) {
                      _flushDeferredStreamOutput();
                    } else {
                      _terminalController.clearSelection();
                    }
                    Navigator.pop(context);
                  },
                  activeThumbColor: DesignColors.warning,
                ),
                onTap: () {
                  final isSelecting = _terminalMode == TerminalMode.select;
                  final newMode = isSelecting
                      ? TerminalMode.normal
                      : TerminalMode.select;
                  setState(() {
                    _terminalMode = newMode;
                  });
                  if (newMode == TerminalMode.normal) {
                    _flushDeferredStreamOutput();
                  } else {
                    _terminalController.clearSelection();
                  }
                  Navigator.pop(context);
                },
              ),
              // Reset zoom
              ListTile(
                leading: Icon(
                  Icons.zoom_out_map,
                  color: _zoomScale != 1.0 ? DesignColors.warning : inactiveIconColor,
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
              Divider(height: 1, color: isDark ? const Color(0xFF2A2B36) : Colors.grey.shade300),
              // Go to settings screen
              ListTile(
                leading: Icon(
                  Icons.settings,
                  color: inactiveIconColor,
                ),
                title: Text(
                  'Settings',
                  style: TextStyle(color: textColor),
                ),
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
              Divider(height: 1, color: isDark ? const Color(0xFF2A2B36) : Colors.grey.shade300),
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
          backgroundColor: isDark ? DesignColors.surfaceDark : DesignColors.surfaceLight,
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
                style: TextStyle(color: isDark ? Colors.white60 : Colors.black54),
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
    await _stopControlClient();

    // Disconnect SSH
    await ref.read(sshProvider.notifier).disconnect();

    // Go back to previous screen
    if (mounted) {
      Navigator.pop(context);
    }
  }

  /// Connection status indicator (displays latency or reconnection status)
  Widget _buildConnectionIndicator(int latency) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        border: Border(
          left: BorderSide(color: colorScheme.outline, width: 1),
        ),
      ),
      child: _sshState.isReconnecting
          ? _buildReconnectingIndicator()
          : _buildLatencyIndicator(latency),
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

  void _showInputDialog() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) => _InputDialogContent(
        initialValue: _savedCommandInput,
        onValueChanged: (value) {
          // Save input content in real time
          _savedCommandInput = value;
        },
        onSend: (value) async {
          await _sendMultilineText(value);
          // Clear input content on successful send
          _savedCommandInput = '';
          if (sheetContext.mounted) Navigator.pop(sheetContext);
        },
      ),
    );
  }

  Future<void> _sendMultilineText(String text) async {
    if (text.isEmpty) {
      return;
    }
    final normalized = text.replaceAll('\r\n', '\n');
    final payload = normalized.replaceAll('\n', '\r');
    await _sendTerminalData(payload.endsWith('\r') ? payload : '$payload\r');
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
        ..color = isActive ? activeColor : (isDark ? Colors.white30 : Colors.grey.shade500)
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

/// Input dialog content (supports multiline, Shift+Enter for newline)
class _InputDialogContent extends StatefulWidget {
  final String initialValue;
  final void Function(String value) onValueChanged;
  final Future<void> Function(String value) onSend;

  const _InputDialogContent({
    this.initialValue = '',
    required this.onValueChanged,
    required this.onSend,
  });

  @override
  State<_InputDialogContent> createState() => _InputDialogContentState();
}

class _InputDialogContentState extends State<_InputDialogContent> {
  late final TextEditingController _controller;
  late final FocusNode _focusNode;
  late final ScrollController _scrollController;
  bool _isSending = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialValue);
    _focusNode = FocusNode();
    _scrollController = ScrollController();
    // Set onKeyEvent to handle key events
    _focusNode.onKeyEvent = _handleKeyEvent;
    // Notify parent on text changes
    _controller.addListener(_onTextChanged);
    // Auto-focus (place cursor at end)
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusNode.requestFocus();
      // Move cursor to end
      _controller.selection = TextSelection.collapsed(
        offset: _controller.text.length,
      );
    });
  }

  void _onTextChanged() {
    widget.onValueChanged(_controller.text);
  }

  @override
  void dispose() {
    _controller.removeListener(_onTextChanged);
    _focusNode.onKeyEvent = null;
    _focusNode.dispose();
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  /// Handle key events (Shift+Enter for newline, Enter to send)
  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.enter) {
      final isShiftPressed = HardwareKeyboard.instance.isShiftPressed;
      if (isShiftPressed) {
        // Shift+Enter: insert newline
        _insertNewline();
        return KeyEventResult.handled;
      } else {
        // Enter only: send
        _handleSend();
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  /// Insert a newline at the current cursor position
  void _insertNewline() {
    final text = _controller.text;
    final selection = _controller.selection;
    final newText = text.replaceRange(selection.start, selection.end, '\n');
    _controller.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: selection.start + 1),
    );
  }

  Future<void> _handleSend() async {
    if (_isSending) return;
    setState(() => _isSending = true);
    try {
      await widget.onSend(_controller.text);
    } finally {
      if (mounted) {
        setState(() => _isSending = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
        left: 16,
        right: 16,
        top: 16,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text(
                'Enter Command',
                style: GoogleFonts.spaceGrotesk(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: colorScheme.onSurface,
                ),
              ),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: isDark ? DesignColors.keyBackground : DesignColors.keyBackgroundLight,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  'Shift+Enter: New line',
                  style: GoogleFonts.jetBrainsMono(
                    fontSize: 10,
                    color: isDark ? DesignColors.textMuted : DesignColors.textMutedLight,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          ConstrainedBox(
            constraints: const BoxConstraints(
              maxHeight: 200, // Limit max height to enable scrolling
            ),
            child: TextField(
              controller: _controller,
              focusNode: _focusNode,
              scrollController: _scrollController,
              maxLines: null, // Unlimited lines with internal scrolling
              minLines: 1,
              keyboardType: TextInputType.multiline,
              textInputAction: TextInputAction.newline, // Support multiline on paste
              style: GoogleFonts.jetBrainsMono(color: colorScheme.onSurface),
              decoration: InputDecoration(
                hintText: 'Type your command... (Enter to send)',
                hintStyle: GoogleFonts.jetBrainsMono(
                  color: isDark ? DesignColors.textMuted : DesignColors.textMutedLight,
                ),
                filled: true,
                fillColor: isDark ? DesignColors.inputDark : DesignColors.inputLight,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: colorScheme.primary),
                ),
                contentPadding: const EdgeInsets.all(16),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => Navigator.pop(context),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: colorScheme.onSurface,
                    side: BorderSide(color: colorScheme.onSurface.withValues(alpha: 0.3)),
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: Text(
                    'Cancel',
                    style: GoogleFonts.spaceGrotesk(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 2,
                child: ElevatedButton(
                  onPressed: _isSending ? null : _handleSend,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: colorScheme.primary,
                    foregroundColor: colorScheme.onPrimary,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: _isSending
                      ? SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: colorScheme.onPrimary,
                          ),
                        )
                      : Text(
                          'Execute',
                          style: GoogleFonts.spaceGrotesk(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}
