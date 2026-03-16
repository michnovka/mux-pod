import 'package:flutter/foundation.dart';

import 'terminal_search_engine.dart';

/// Immutable state for terminal search.
@immutable
class TerminalSearchState {
  final String query;
  final bool caseSensitive;
  final bool regexEnabled;
  final String? regexError;
  final List<TerminalSearchMatch> matches;
  final int currentMatchIndex;
  final bool isActive;

  const TerminalSearchState({
    this.query = '',
    this.caseSensitive = false,
    this.regexEnabled = false,
    this.regexError,
    this.matches = const [],
    this.currentMatchIndex = -1,
    this.isActive = false,
  });

  int get matchCount => matches.length;

  TerminalSearchMatch? get currentMatch =>
      currentMatchIndex >= 0 && currentMatchIndex < matches.length
          ? matches[currentMatchIndex]
          : null;

  String get matchLabel {
    if (regexError != null) return 'Invalid regex';
    if (query.isEmpty) return '';
    if (matches.isEmpty) return 'No results';
    return '${currentMatchIndex + 1} of ${matches.length}';
  }

  TerminalSearchState copyWith({
    String? query,
    bool? caseSensitive,
    bool? regexEnabled,
    String? Function()? regexError,
    List<TerminalSearchMatch>? matches,
    int? currentMatchIndex,
    bool? isActive,
  }) {
    return TerminalSearchState(
      query: query ?? this.query,
      caseSensitive: caseSensitive ?? this.caseSensitive,
      regexEnabled: regexEnabled ?? this.regexEnabled,
      regexError: regexError != null ? regexError() : this.regexError,
      matches: matches ?? this.matches,
      currentMatchIndex: currentMatchIndex ?? this.currentMatchIndex,
      isActive: isActive ?? this.isActive,
    );
  }
}
