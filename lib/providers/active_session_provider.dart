import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/storage/versioned_json_storage.dart';
import '../services/tmux/tmux_parser.dart';
import 'shared_preferences_provider.dart';

/// Active session information
class ActiveSession {
  final String connectionId;
  final String connectionName;
  final String host;
  final String sessionName;
  final int windowCount;
  final DateTime connectedAt;
  final bool isAttached;

  /// Last opened window index
  final int? lastWindowIndex;

  /// Last opened pane ID
  final String? lastPaneId;

  /// Last accessed time (used for history sorting)
  final DateTime? lastAccessedAt;

  const ActiveSession({
    required this.connectionId,
    required this.connectionName,
    required this.host,
    required this.sessionName,
    required this.windowCount,
    required this.connectedAt,
    this.isAttached = true,
    this.lastWindowIndex,
    this.lastPaneId,
    this.lastAccessedAt,
  });

  ActiveSession copyWith({
    String? connectionId,
    String? connectionName,
    String? host,
    String? sessionName,
    int? windowCount,
    DateTime? connectedAt,
    bool? isAttached,
    int? lastWindowIndex,
    String? lastPaneId,
    DateTime? lastAccessedAt,
    bool clearLastPane = false,
  }) {
    return ActiveSession(
      connectionId: connectionId ?? this.connectionId,
      connectionName: connectionName ?? this.connectionName,
      host: host ?? this.host,
      sessionName: sessionName ?? this.sessionName,
      windowCount: windowCount ?? this.windowCount,
      connectedAt: connectedAt ?? this.connectedAt,
      isAttached: isAttached ?? this.isAttached,
      lastWindowIndex: lastWindowIndex ?? this.lastWindowIndex,
      lastPaneId: clearLastPane ? null : (lastPaneId ?? this.lastPaneId),
      lastAccessedAt: lastAccessedAt ?? this.lastAccessedAt,
    );
  }

  /// Serialize to JSON format
  Map<String, dynamic> toJson() {
    return {
      'connectionId': connectionId,
      'connectionName': connectionName,
      'host': host,
      'sessionName': sessionName,
      'windowCount': windowCount,
      'connectedAt': connectedAt.toIso8601String(),
      'isAttached': isAttached,
      'lastWindowIndex': lastWindowIndex,
      'lastPaneId': lastPaneId,
      'lastAccessedAt': lastAccessedAt?.toIso8601String(),
    };
  }

  /// Deserialize from JSON
  factory ActiveSession.fromJson(Map<String, dynamic> json) {
    final lastAccessedAtStr = json['lastAccessedAt'] as String?;
    return ActiveSession(
      connectionId: json['connectionId'] as String,
      connectionName: json['connectionName'] as String,
      host: json['host'] as String,
      sessionName: json['sessionName'] as String,
      windowCount: json['windowCount'] as int? ?? 0,
      connectedAt: DateTime.parse(json['connectedAt'] as String),
      isAttached: json['isAttached'] as bool? ?? false,
      lastWindowIndex: json['lastWindowIndex'] as int?,
      lastPaneId: json['lastPaneId'] as String?,
      lastAccessedAt: lastAccessedAtStr != null
          ? DateTime.parse(lastAccessedAtStr)
          : null,
    );
  }

  /// Unique key for the session
  String get key => '$connectionId:$sessionName';
}

/// State for the list of active sessions
class ActiveSessionsState {
  final List<ActiveSession> sessions;
  final String? currentSessionKey; // connectionId:sessionName

  const ActiveSessionsState({this.sessions = const [], this.currentSessionKey});

  ActiveSessionsState copyWith({
    List<ActiveSession>? sessions,
    String? currentSessionKey,
    bool clearCurrentSession = false,
  }) {
    return ActiveSessionsState(
      sessions: sessions ?? this.sessions,
      currentSessionKey: clearCurrentSession
          ? null
          : (currentSessionKey ?? this.currentSessionKey),
    );
  }

  /// Get the list of sessions for a given connection
  List<ActiveSession> getSessionsForConnection(String connectionId) {
    return sessions.where((s) => s.connectionId == connectionId).toList();
  }

  /// Get the current session
  ActiveSession? get currentSession {
    if (currentSessionKey == null) return null;
    try {
      return sessions.firstWhere(
        (s) => '${s.connectionId}:${s.sessionName}' == currentSessionKey,
      );
    } catch (e) {
      return null;
    }
  }
}

/// Notifier that manages active sessions
class ActiveSessionsNotifier extends Notifier<ActiveSessionsState> {
  static const _storageKey = 'active_sessions';
  final Completer<void> _initialLoadCompleter = Completer<void>();
  SharedPreferences? _sharedPreferences;

  @override
  ActiveSessionsState build() {
    final prefs = _sharedPreferences = ref.read(sharedPreferencesProvider);
    if (prefs != null) {
      final state = _loadFromStorageSync(prefs);
      if (!_initialLoadCompleter.isCompleted) {
        _initialLoadCompleter.complete();
      }
      return state;
    }

    _loadFromStorage();
    return const ActiveSessionsState();
  }

  ActiveSessionsState _loadFromStorageSync(SharedPreferences prefs) {
    try {
      final jsonStr = prefs.getString(_storageKey);
      if (jsonStr == null) {
        return const ActiveSessionsState();
      }

      final loaded = decodeVersionedJsonEnvelope<List<ActiveSession>>(
        raw: jsonStr,
        storageKey: _storageKey,
        versionReaders: {
          sharedPreferencesSchemaVersion1: (data) =>
              _decodeActiveSessionsList(data),
        },
        legacyReader: (legacy) => _decodeActiveSessionsList(legacy),
      );
      final sessions = loaded.value
          .toList();
      return ActiveSessionsState(sessions: sessions);
    } catch (e) {
      return const ActiveSessionsState();
    }
  }

  List<ActiveSession> _decodeActiveSessionsList(Object? data) {
    final jsonList = data as List<dynamic>;
    return jsonList
        .map((json) => ActiveSession.fromJson(json as Map<String, dynamic>))
        .toList();
  }

  Future<SharedPreferences> _getPrefs() async {
    final prefs = _sharedPreferences;
    if (prefs != null) {
      return prefs;
    }

    final loadedPrefs = await SharedPreferences.getInstance();
    _sharedPreferences = loadedPrefs;
    return loadedPrefs;
  }

  /// Load session information from storage
  Future<void> _loadFromStorage() async {
    try {
      state = _loadFromStorageSync(await _getPrefs());
    } catch (e) {
      // Ignore load errors (e.g., on first launch)
    } finally {
      if (!_initialLoadCompleter.isCompleted) {
        _initialLoadCompleter.complete();
      }
    }
  }

  bool get _hasLoadedInitialState => _initialLoadCompleter.isCompleted;

  /// Save session information to storage
  Future<void> _saveToStorage() async {
    try {
      final prefs = await _getPrefs();
      final jsonList = state.sessions.map((s) => s.toJson()).toList();
      await prefs.setString(_storageKey, encodeVersionedJsonEnvelope(jsonList));
    } catch (e) {
      // Ignore save errors
    }
  }

  /// Add or update a session
  Future<void> addOrUpdateSession({
    required String connectionId,
    required String connectionName,
    required String host,
    required String sessionName,
    required int windowCount,
    bool isAttached = true,
    int? lastWindowIndex,
    String? lastPaneId,
  }) async {
    if (!_hasLoadedInitialState) {
      await _initialLoadCompleter.future;
    }
    final key = '$connectionId:$sessionName';
    final existingIndex = state.sessions.indexWhere((s) => s.key == key);

    final existingSession = existingIndex >= 0
        ? state.sessions[existingIndex]
        : null;
    final now = DateTime.now();

    final session = ActiveSession(
      connectionId: connectionId,
      connectionName: connectionName,
      host: host,
      sessionName: sessionName,
      windowCount: windowCount,
      connectedAt: existingSession?.connectedAt ?? now,
      isAttached: isAttached,
      lastWindowIndex: lastWindowIndex ?? existingSession?.lastWindowIndex,
      lastPaneId: lastPaneId ?? existingSession?.lastPaneId,
      lastAccessedAt: isAttached ? now : existingSession?.lastAccessedAt,
    );

    final sessions = [...state.sessions];
    if (existingIndex >= 0) {
      sessions[existingIndex] = session;
    } else {
      sessions.add(session);
    }

    state = state.copyWith(sessions: sessions);
    await _saveToStorage();
  }

  /// Update the last opened pane information for a session
  Future<void> updateLastPane({
    required String connectionId,
    required String sessionName,
    required int windowIndex,
    required String paneId,
  }) async {
    if (!_hasLoadedInitialState) {
      await _initialLoadCompleter.future;
    }
    final key = '$connectionId:$sessionName';
    final existingIndex = state.sessions.indexWhere((s) => s.key == key);
    if (existingIndex < 0) return;

    final sessions = [...state.sessions];
    sessions[existingIndex] = sessions[existingIndex].copyWith(
      lastWindowIndex: windowIndex,
      lastPaneId: paneId,
      lastAccessedAt: DateTime.now(),
    );

    state = state.copyWith(sessions: sessions);
    await _saveToStorage();
  }

  /// Update the last accessed time when a session is opened
  Future<void> touchSession(String connectionId, String sessionName) async {
    if (!_hasLoadedInitialState) {
      await _initialLoadCompleter.future;
    }
    final key = '$connectionId:$sessionName';
    final existingIndex = state.sessions.indexWhere((s) => s.key == key);
    if (existingIndex < 0) return;

    final sessions = [...state.sessions];
    sessions[existingIndex] = sessions[existingIndex].copyWith(
      lastAccessedAt: DateTime.now(),
    );

    state = state.copyWith(sessions: sessions);
    await _saveToStorage();
  }

  /// Update the session list for a connection (from tmux session list)
  /// Preserves lastWindowIndex/lastPaneId/lastAccessedAt of existing sessions
  Future<void> updateSessionsForConnection({
    required String connectionId,
    required String connectionName,
    required String host,
    required List<TmuxSession> tmuxSessions,
  }) async {
    if (!_hasLoadedInitialState) {
      await _initialLoadCompleter.future;
    }
    // Save existing session information to a map
    final existingMap = <String, ActiveSession>{};
    for (final s in state.sessions.where(
      (s) => s.connectionId == connectionId,
    )) {
      existingMap[s.sessionName] = s;
    }

    // Preserve sessions from other connections
    final otherSessions = state.sessions
        .where((s) => s.connectionId != connectionId)
        .toList();

    final newSessions = tmuxSessions.map((ts) {
      final existing = existingMap[ts.name];
      return ActiveSession(
        connectionId: connectionId,
        connectionName: connectionName,
        host: host,
        sessionName: ts.name,
        windowCount: ts.windowCount,
        connectedAt: existing?.connectedAt ?? DateTime.now(),
        isAttached: ts.attached,
        lastWindowIndex: existing?.lastWindowIndex,
        lastPaneId: existing?.lastPaneId,
        lastAccessedAt: existing?.lastAccessedAt,
      );
    }).toList();

    state = state.copyWith(sessions: [...otherSessions, ...newSessions]);
    await _saveToStorage();
  }

  /// Set the current session
  Future<void> setCurrentSession(
    String connectionId,
    String sessionName,
  ) async {
    if (!_hasLoadedInitialState) {
      await _initialLoadCompleter.future;
    }
    state = state.copyWith(currentSessionKey: '$connectionId:$sessionName');
  }

  /// Clear the current session
  Future<void> clearCurrentSession() async {
    if (!_hasLoadedInitialState) {
      await _initialLoadCompleter.future;
    }
    state = state.copyWith(clearCurrentSession: true);
  }

  /// Explicitly close (delete) a session
  Future<void> closeSession(String connectionId, String sessionName) async {
    if (!_hasLoadedInitialState) {
      await _initialLoadCompleter.future;
    }
    final sessions = state.sessions
        .where(
          (s) =>
              !(s.connectionId == connectionId &&
                  s.sessionName == sessionName),
        )
        .toList();
    state = state.copyWith(sessions: sessions);
    await _saveToStorage();
  }

  /// Remove a session (alias for closeSession)
  Future<void> removeSession(String connectionId, String sessionName) {
    return closeSession(connectionId, sessionName);
  }

  /// Remove all sessions for a connection
  Future<void> removeSessionsForConnection(String connectionId) async {
    if (!_hasLoadedInitialState) {
      await _initialLoadCompleter.future;
    }
    final sessions = state.sessions
        .where((s) => s.connectionId != connectionId)
        .toList();
    state = state.copyWith(sessions: sessions);
    await _saveToStorage();
  }

  /// Clear all sessions
  Future<void> clear() async {
    if (!_hasLoadedInitialState) {
      await _initialLoadCompleter.future;
    }
    state = const ActiveSessionsState();
    await _saveToStorage();
  }
}

/// Active sessions provider
final activeSessionsProvider =
    NotifierProvider<ActiveSessionsNotifier, ActiveSessionsState>(() {
      return ActiveSessionsNotifier();
    });
