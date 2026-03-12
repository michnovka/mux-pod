import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Connection settings
class Connection {
  final String id;
  final String name;
  final String host;
  final int port;
  final String username;
  final String authMethod; // 'password' | 'key'
  final String? keyId;
  final String? tmuxPath;
  final DateTime createdAt;
  final DateTime? lastConnectedAt;

  const Connection({
    required this.id,
    required this.name,
    required this.host,
    this.port = 22,
    required this.username,
    this.authMethod = 'password',
    this.keyId,
    this.tmuxPath,
    required this.createdAt,
    this.lastConnectedAt,
  });

  Connection copyWith({
    String? id,
    String? name,
    String? host,
    int? port,
    String? username,
    String? authMethod,
    String? keyId,
    String? tmuxPath,
    DateTime? createdAt,
    DateTime? lastConnectedAt,
  }) {
    return Connection(
      id: id ?? this.id,
      name: name ?? this.name,
      host: host ?? this.host,
      port: port ?? this.port,
      username: username ?? this.username,
      authMethod: authMethod ?? this.authMethod,
      keyId: keyId ?? this.keyId,
      tmuxPath: tmuxPath ?? this.tmuxPath,
      createdAt: createdAt ?? this.createdAt,
      lastConnectedAt: lastConnectedAt ?? this.lastConnectedAt,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'host': host,
      'port': port,
      'username': username,
      'authMethod': authMethod,
      'keyId': keyId,
      'tmuxPath': tmuxPath,
      'createdAt': createdAt.toIso8601String(),
      'lastConnectedAt': lastConnectedAt?.toIso8601String(),
    };
  }

  factory Connection.fromJson(Map<String, dynamic> json) {
    return Connection(
      id: json['id'] as String,
      name: json['name'] as String,
      host: json['host'] as String,
      port: json['port'] as int? ?? 22,
      username: json['username'] as String,
      authMethod: json['authMethod'] as String? ?? 'password',
      keyId: json['keyId'] as String?,
      tmuxPath: json['tmuxPath'] as String?,
      createdAt: DateTime.parse(json['createdAt'] as String),
      lastConnectedAt: json['lastConnectedAt'] != null
          ? DateTime.parse(json['lastConnectedAt'] as String)
          : null,
    );
  }
}

/// State for the connections list
class ConnectionsState {
  final List<Connection> connections;
  final bool isLoading;
  final String? error;

  const ConnectionsState({
    this.connections = const [],
    this.isLoading = false,
    this.error,
  });

  ConnectionsState copyWith({
    List<Connection>? connections,
    bool? isLoading,
    String? error,
  }) {
    return ConnectionsState(
      connections: connections ?? this.connections,
      isLoading: isLoading ?? this.isLoading,
      error: error,
    );
  }
}

/// Notifier that manages the connections list
class ConnectionsNotifier extends Notifier<ConnectionsState> {
  static const String _storageKey = 'connections';

  @override
  ConnectionsState build() {
    // Initial state
    _loadConnections();
    return const ConnectionsState(isLoading: true);
  }

  Future<void> _loadConnections() async {
    developer.log('_loadConnections() started', name: 'ConnectionsProvider');
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonString = prefs.getString(_storageKey);
      developer.log(
        'JSON from storage: ${jsonString != null ? 'exists' : 'null'}',
        name: 'ConnectionsProvider',
      );

      if (jsonString != null) {
        final jsonList = jsonDecode(jsonString) as List<dynamic>;
        final connections = jsonList
            .map((json) => Connection.fromJson(json as Map<String, dynamic>))
            .toList();

        developer.log(
          'Loaded ${connections.length} connections from storage',
          name: 'ConnectionsProvider',
        );

        // Sorting is done by filteredConnectionsProvider, so no sorting here
        state = ConnectionsState(connections: connections);
        developer.log(
          'State updated with ${connections.length} connections',
          name: 'ConnectionsProvider',
        );
      } else {
        state = const ConnectionsState();
        developer.log(
          'No saved connections, initialized empty state',
          name: 'ConnectionsProvider',
        );
      }
    } catch (e, stackTrace) {
      developer.log(
        'Error loading connections: $e',
        name: 'ConnectionsProvider',
        error: e,
        stackTrace: stackTrace,
      );
      state = ConnectionsState(error: e.toString());
    }
  }

  Future<void> _saveConnections() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonList = state.connections.map((c) => c.toJson()).toList();
    await prefs.setString(_storageKey, jsonEncode(jsonList));
  }

  /// Add a connection
  Future<void> add(Connection connection) async {
    developer.log(
      'add() called: ${connection.name} (${connection.id})',
      name: 'ConnectionsProvider',
    );
    developer.log(
      'Current connections count: ${state.connections.length}',
      name: 'ConnectionsProvider',
    );

    final connections = [...state.connections, connection];
    developer.log(
      'New connections count: ${connections.length}',
      name: 'ConnectionsProvider',
    );

    state = state.copyWith(connections: connections);
    developer.log(
      'State updated, saving to SharedPreferences...',
      name: 'ConnectionsProvider',
    );

    await _saveConnections();
    developer.log(
      'Connections saved. Final count: ${state.connections.length}',
      name: 'ConnectionsProvider',
    );
  }

  /// Remove a connection
  Future<void> remove(String id) async {
    developer.log('remove() called: $id', name: 'ConnectionsProvider');
    final connections = state.connections.where((c) => c.id != id).toList();
    state = state.copyWith(connections: connections);
    await _saveConnections();
    developer.log(
      'Connection removed. Remaining: ${state.connections.length}',
      name: 'ConnectionsProvider',
    );
  }

  /// Update a connection
  Future<void> update(Connection connection) async {
    developer.log(
      'update() called: ${connection.name} (${connection.id})',
      name: 'ConnectionsProvider',
    );
    final connections = state.connections.map((c) {
      return c.id == connection.id ? connection : c;
    }).toList();
    state = state.copyWith(connections: connections);
    await _saveConnections();
    developer.log('Connection updated and saved', name: 'ConnectionsProvider');
  }

  /// Update the last connected time
  Future<void> updateLastConnected(String id) async {
    final connections = state.connections.map((c) {
      if (c.id == id) {
        return c.copyWith(lastConnectedAt: DateTime.now());
      }
      return c;
    }).toList();
    state = state.copyWith(connections: connections);
    await _saveConnections();
  }

  /// Get a connection
  Connection? getById(String id) {
    try {
      return state.connections.firstWhere((c) => c.id == id);
    } catch (e) {
      return null;
    }
  }

  /// Resolve a connection once the async initial load has completed.
  Future<Connection?> getByIdWhenReady(
    String id, {
    Duration timeout = const Duration(seconds: 3),
    Duration pollInterval = const Duration(milliseconds: 50),
    bool reloadIfMissing = true,
  }) async {
    var connection = getById(id);
    if (connection != null) {
      return connection;
    }

    final deadline = DateTime.now().add(timeout);
    while (state.isLoading && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(pollInterval);
      connection = getById(id);
      if (connection != null) {
        return connection;
      }
    }

    if (connection != null || !reloadIfMissing) {
      return connection;
    }

    await reload();
    return getById(id);
  }

  /// Reload
  Future<void> reload() async {
    state = state.copyWith(isLoading: true, error: null);
    await _loadConnections();
  }
}

/// Connections list provider
final connectionsProvider =
    NotifierProvider<ConnectionsNotifier, ConnectionsState>(() {
      return ConnectionsNotifier();
    });

/// Notifier that manages the selected connection ID
class SelectedConnectionIdNotifier extends Notifier<String?> {
  @override
  String? build() => null;

  void select(String? id) {
    state = id;
  }
}

/// Notifier that manages the search query
class ConnectionSearchNotifier extends Notifier<String> {
  @override
  String build() => '';

  void setQuery(String query) {
    state = query;
  }

  void clear() {
    state = '';
  }
}

/// Search query provider
final connectionSearchProvider =
    NotifierProvider<ConnectionSearchNotifier, String>(() {
      return ConnectionSearchNotifier();
    });

/// Sort options
enum ConnectionSortOption {
  nameAsc,
  nameDesc,
  lastConnectedDesc,
  lastConnectedAsc,
  hostAsc,
  hostDesc,
}

/// Notifier that manages the sort option
class ConnectionSortNotifier extends Notifier<ConnectionSortOption> {
  @override
  ConnectionSortOption build() => ConnectionSortOption.lastConnectedDesc;

  void setSort(ConnectionSortOption option) {
    state = option;
  }
}

/// Sort option provider
final connectionSortProvider =
    NotifierProvider<ConnectionSortNotifier, ConnectionSortOption>(() {
      return ConnectionSortNotifier();
    });

/// Filtered and sorted connections list provider
final filteredConnectionsProvider = Provider<List<Connection>>((ref) {
  final connectionsState = ref.watch(connectionsProvider);
  final searchQuery = ref.watch(connectionSearchProvider).toLowerCase();
  final sortOption = ref.watch(connectionSortProvider);

  // Search filtering (create a copy to avoid modifying the original list)
  var connections = List.of(connectionsState.connections);
  if (searchQuery.isNotEmpty) {
    connections = connections.where((c) {
      return c.name.toLowerCase().contains(searchQuery) ||
          c.host.toLowerCase().contains(searchQuery) ||
          c.username.toLowerCase().contains(searchQuery);
    }).toList();
  }

  // Sort
  switch (sortOption) {
    case ConnectionSortOption.nameAsc:
      connections.sort((a, b) => a.name.compareTo(b.name));
    case ConnectionSortOption.nameDesc:
      connections.sort((a, b) => b.name.compareTo(a.name));
    case ConnectionSortOption.lastConnectedDesc:
      connections.sort((a, b) {
        final aTime = a.lastConnectedAt ?? a.createdAt;
        final bTime = b.lastConnectedAt ?? b.createdAt;
        return bTime.compareTo(aTime);
      });
    case ConnectionSortOption.lastConnectedAsc:
      connections.sort((a, b) {
        final aTime = a.lastConnectedAt ?? a.createdAt;
        final bTime = b.lastConnectedAt ?? b.createdAt;
        return aTime.compareTo(bTime);
      });
    case ConnectionSortOption.hostAsc:
      connections.sort((a, b) => a.host.compareTo(b.host));
    case ConnectionSortOption.hostDesc:
      connections.sort((a, b) => b.host.compareTo(a.host));
  }

  return connections;
});

/// Currently selected connection ID provider
final selectedConnectionIdProvider =
    NotifierProvider<SelectedConnectionIdNotifier, String?>(() {
      return SelectedConnectionIdNotifier();
    });

/// Currently selected connection provider
final selectedConnectionProvider = Provider<Connection?>((ref) {
  final id = ref.watch(selectedConnectionIdProvider);
  if (id == null) return null;

  final state = ref.watch(connectionsProvider);
  try {
    return state.connections.firstWhere((c) => c.id == id);
  } catch (e) {
    return null;
  }
});
