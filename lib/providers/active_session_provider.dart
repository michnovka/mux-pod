import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/tmux/tmux_parser.dart';

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
      lastAccessedAt: lastAccessedAtStr != null ? DateTime.parse(lastAccessedAtStr) : null,
    );
  }

  /// Unique key for the session
  String get key => '$connectionId:$sessionName';
}

/// State for the list of active sessions
class ActiveSessionsState {
  final List<ActiveSession> sessions;
  final String? currentSessionKey; // connectionId:sessionName

  const ActiveSessionsState({
    this.sessions = const [],
    this.currentSessionKey,
  });

  ActiveSessionsState copyWith({
    List<ActiveSession>? sessions,
    String? currentSessionKey,
    bool clearCurrentSession = false,
  }) {
    return ActiveSessionsState(
      sessions: sessions ?? this.sessions,
      currentSessionKey:
          clearCurrentSession ? null : (currentSessionKey ?? this.currentSessionKey),
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

  @override
  ActiveSessionsState build() {
    // Load from storage on initialization
    _loadFromStorage();
    return const ActiveSessionsState();
  }

  /// Load session information from storage
  Future<void> _loadFromStorage() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonStr = prefs.getString(_storageKey);
      if (jsonStr != null) {
        final jsonList = jsonDecode(jsonStr) as List<dynamic>;
        final sessions = jsonList
            .map((json) => ActiveSession.fromJson(json as Map<String, dynamic>))
            .toList();
        state = state.copyWith(sessions: sessions);
      }
    } catch (e) {
      // Ignore load errors (e.g., on first launch)
    }
  }

  /// Save session information to storage
  Future<void> _saveToStorage() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonList = state.sessions.map((s) => s.toJson()).toList();
      await prefs.setString(_storageKey, jsonEncode(jsonList));
    } catch (e) {
      // Ignore save errors
    }
  }

  /// Add or update a session
  void addOrUpdateSession({
    required String connectionId,
    required String connectionName,
    required String host,
    required String sessionName,
    required int windowCount,
    bool isAttached = true,
    int? lastWindowIndex,
    String? lastPaneId,
  }) {
    final key = '$connectionId:$sessionName';
    final existingIndex = state.sessions.indexWhere(
      (s) => s.key == key,
    );

    final existingSession = existingIndex >= 0 ? state.sessions[existingIndex] : null;
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
    _saveToStorage();
  }

  /// Update the last opened pane information for a session
  void updateLastPane({
    required String connectionId,
    required String sessionName,
    required int windowIndex,
    required String paneId,
  }) {
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
    _saveToStorage();
  }

  /// Update the last accessed time when a session is opened
  void touchSession(String connectionId, String sessionName) {
    final key = '$connectionId:$sessionName';
    final existingIndex = state.sessions.indexWhere((s) => s.key == key);
    if (existingIndex < 0) return;

    final sessions = [...state.sessions];
    sessions[existingIndex] = sessions[existingIndex].copyWith(
      lastAccessedAt: DateTime.now(),
    );

    state = state.copyWith(sessions: sessions);
    _saveToStorage();
  }

  /// Update the session list for a connection (from tmux session list)
  /// Preserves lastWindowIndex/lastPaneId/lastAccessedAt of existing sessions
  void updateSessionsForConnection({
    required String connectionId,
    required String connectionName,
    required String host,
    required List<TmuxSession> tmuxSessions,
  }) {
    // Save existing session information to a map
    final existingMap = <String, ActiveSession>{};
    for (final s in state.sessions.where((s) => s.connectionId == connectionId)) {
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
    _saveToStorage();
  }

  /// Set the current session
  void setCurrentSession(String connectionId, String sessionName) {
    state = state.copyWith(currentSessionKey: '$connectionId:$sessionName');
  }

  /// Clear the current session
  void clearCurrentSession() {
    state = state.copyWith(clearCurrentSession: true);
  }

  /// Explicitly close (delete) a session
  void closeSession(String connectionId, String sessionName) {
    final sessions = state.sessions
        .where((s) => !(s.connectionId == connectionId && s.sessionName == sessionName))
        .toList();
    state = state.copyWith(sessions: sessions);
    _saveToStorage();
  }

  /// Remove a session (alias for closeSession)
  void removeSession(String connectionId, String sessionName) {
    closeSession(connectionId, sessionName);
  }

  /// Remove all sessions for a connection
  void removeSessionsForConnection(String connectionId) {
    final sessions =
        state.sessions.where((s) => s.connectionId != connectionId).toList();
    state = state.copyWith(sessions: sessions);
    _saveToStorage();
  }

  /// Clear all sessions
  void clear() {
    state = const ActiveSessionsState();
    _saveToStorage();
  }
}

/// Active sessions provider
final activeSessionsProvider =
    NotifierProvider<ActiveSessionsNotifier, ActiveSessionsState>(() {
  return ActiveSessionsNotifier();
});
