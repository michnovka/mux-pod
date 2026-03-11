import 'package:flutter/foundation.dart';

/// tmux command output parser
///
/// Parses tmux command output and converts it into objects.
/// Provides parsers corresponding to format strings.
class TmuxParser {
  /// Default field delimiter (uses ||| because tabs may be converted over SSH)
  static const String defaultDelimiter = '|||';

  // ===== Sessions =====

  /// Parse session list
  ///
  /// Supported format: `#{session_name}\t#{session_created}\t#{session_attached}\t#{session_windows}\t#{session_id}`
  static List<TmuxSession> parseSessions(String output, {String delimiter = defaultDelimiter}) {
    debugPrint('parseSessions: raw output="${output.trim()}"');
    if (!isServerRunning(output)) {
      debugPrint('parseSessions: isServerRunning=false, returning empty');
      return [];
    }

    final sessions = <TmuxSession>[];

    for (final line in output.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;

      final session = parseSessionLine(trimmed, delimiter: delimiter);
      if (session != null) {
        sessions.add(session);
      }
    }

    return sessions;
  }

  /// Parse a single session line
  static TmuxSession? parseSessionLine(String line, {String delimiter = defaultDelimiter}) {
    final parts = line.split(delimiter);
    // Lines without delimiters are not tmux output (e.g. shell errors)
    if (parts.length < 2) {
      debugPrint('parseSessionLine: skipping line with ${parts.length} fields (expected ≥2): "$line"');
      return null;
    }

    final name = parts[0];
    if (name.isEmpty) {
      debugPrint('parseSessionLine: skipping line with empty session name: "$line"');
      return null;
    }

    return TmuxSession(
      name: name,
      id: parts.length > 4 ? parts[4] : null,
      created: parts.length > 1 ? _parseTimestamp(parts[1]) : null,
      attached: parts.length > 2 ? parts[2] == '1' : false,
      windowCount: parts.length > 3 ? int.tryParse(parts[3]) ?? 0 : 0,
    );
  }

  /// Parse sessions in simple format
  ///
  /// Format: `#{session_name}:#{session_windows}:#{session_attached}`
  static List<TmuxSession> parseSessionsSimple(String output) {
    if (!isServerRunning(output)) return [];

    final sessions = <TmuxSession>[];

    for (final line in output.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;

      final parts = trimmed.split(':');
      if (parts.length >= 3) {
        sessions.add(TmuxSession(
          name: parts[0],
          windowCount: int.tryParse(parts[1]) ?? 0,
          attached: parts[2] == '1',
        ));
      }
    }

    return sessions;
  }

  // ===== Windows =====

  /// Parse window list
  ///
  /// Supported format: `#{window_index}\t#{window_id}\t#{window_name}\t#{window_active}\t#{window_panes}\t#{window_flags}`
  static List<TmuxWindow> parseWindows(String output, {String delimiter = defaultDelimiter}) {
    final windows = <TmuxWindow>[];

    for (final line in output.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;

      final window = parseWindowLine(trimmed, delimiter: delimiter);
      if (window != null) {
        windows.add(window);
      }
    }

    return windows;
  }

  /// Parse a single window line
  static TmuxWindow? parseWindowLine(String line, {String delimiter = defaultDelimiter}) {
    final parts = line.split(delimiter);
    if (parts.length < 2) {
      debugPrint('parseWindowLine: skipping line with ${parts.length} fields (expected ≥2): "$line"');
      return null;
    }

    final index = int.tryParse(parts[0]);
    if (index == null) {
      debugPrint('parseWindowLine: skipping line with non-integer index "${parts[0]}": "$line"');
      return null;
    }

    return TmuxWindow(
      index: index,
      id: parts.length > 1 ? parts[1] : null,
      name: parts.length > 2 ? parts[2] : 'window-$index',
      active: parts.length > 3 ? parts[3] == '1' : false,
      paneCount: parts.length > 4 ? int.tryParse(parts[4]) ?? 1 : 1,
      flags: parts.length > 5 ? _parseWindowFlags(parts[5]) : const {},
    );
  }

  /// Parse windows in simple format
  ///
  /// Format: `#{window_index}:#{window_name}:#{window_active}:#{window_panes}`
  static List<TmuxWindow> parseWindowsSimple(String output) {
    final windows = <TmuxWindow>[];

    for (final line in output.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;

      final parts = trimmed.split(':');
      if (parts.length >= 4) {
        windows.add(TmuxWindow(
          index: int.tryParse(parts[0]) ?? 0,
          name: parts[1],
          active: parts[2] == '1',
          paneCount: int.tryParse(parts[3]) ?? 1,
        ));
      }
    }

    return windows;
  }

  // ===== Panes =====

  /// Parse pane list
  ///
  /// Supported format: `#{pane_index}\t#{pane_id}\t#{pane_active}\t#{pane_current_command}\t#{pane_title}\t#{pane_width}\t#{pane_height}\t#{cursor_x}\t#{cursor_y}`
  static List<TmuxPane> parsePanes(String output, {String delimiter = defaultDelimiter}) {
    final panes = <TmuxPane>[];

    for (final line in output.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;

      final pane = parsePaneLine(trimmed, delimiter: delimiter);
      if (pane != null) {
        panes.add(pane);
      }
    }

    return panes;
  }

  /// Parse a single pane line
  static TmuxPane? parsePaneLine(String line, {String delimiter = defaultDelimiter}) {
    final parts = line.split(delimiter);
    if (parts.length < 2) {
      debugPrint('parsePaneLine: skipping line with ${parts.length} fields (expected ≥2): "$line"');
      return null;
    }

    final index = int.tryParse(parts[0]);
    if (index == null) {
      debugPrint('parsePaneLine: skipping line with non-integer index "${parts[0]}": "$line"');
      return null;
    }

    final id = parts[1];
    if (id.isEmpty) {
      debugPrint('parsePaneLine: skipping line with empty pane id: "$line"');
      return null;
    }

    return TmuxPane(
      index: index,
      id: id,
      active: parts.length > 2 ? parts[2] == '1' : false,
      currentCommand: parts.length > 3 ? parts[3] : null,
      title: parts.length > 4 ? parts[4] : null,
      width: parts.length > 5 ? int.tryParse(parts[5]) ?? 80 : 80,
      height: parts.length > 6 ? int.tryParse(parts[6]) ?? 24 : 24,
      cursorX: parts.length > 7 ? int.tryParse(parts[7]) ?? 0 : 0,
      cursorY: parts.length > 8 ? int.tryParse(parts[8]) ?? 0 : 0,
    );
  }

  /// Parse panes in simple format
  ///
  /// Format: `#{pane_index}:#{pane_id}:#{pane_active}:#{pane_width}x#{pane_height}`
  static List<TmuxPane> parsePanesSimple(String output) {
    final panes = <TmuxPane>[];

    for (final line in output.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;

      final parts = trimmed.split(':');
      if (parts.length >= 4) {
        final size = _parseSize(parts[3]);
        panes.add(TmuxPane(
          index: int.tryParse(parts[0]) ?? 0,
          id: parts[1],
          active: parts[2] == '1',
          width: size.width,
          height: size.height,
        ));
      }
    }

    return panes;
  }

  // ===== Pane Content =====

  /// Parse capture-pane output (with ANSI escape sequences)
  static TmuxPaneContent parsePaneContent(String output, {int? width, int? height}) {
    final lines = output.split('\n');

    // Remove trailing empty lines
    while (lines.isNotEmpty && lines.last.trim().isEmpty) {
      lines.removeLast();
    }

    return TmuxPaneContent(
      lines: lines,
      width: width ?? _guessWidth(lines),
      height: lines.length,
      hasAnsiColors: output.contains('\x1b['),
    );
  }

  /// Extract plain text from capture-pane output
  static String stripAnsiCodes(String text) {
    // Remove ANSI escape sequences
    return text.replaceAll(RegExp(r'\x1b\[[0-9;]*[a-zA-Z]'), '');
  }

  // ===== Full Session Tree =====

  /// Parse the entire session tree
  ///
  /// Builds a complete tree from `tmux list-panes -a -F "..."` output
  static List<TmuxSession> parseFullTree(String output, {String delimiter = defaultDelimiter}) {
    debugPrint('parseFullTree: raw output="${output.trim()}"');
    if (!isServerRunning(output)) {
      debugPrint('parseFullTree: isServerRunning=false, returning empty');
      return [];
    }

    final sessionsMap = <String, TmuxSession>{};
    final windowsMap = <String, Map<int, TmuxWindow>>{};

    for (final line in output.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;

      final parts = trimmed.split(delimiter);
      if (parts.length < 10) {
        debugPrint('parseFullTree: skipping line with ${parts.length} fields (expected ≥10): "$trimmed"');
        continue;
      }

      // Format: session_name, session_id, window_index, window_id, window_name, window_active,
      //         pane_index, pane_id, pane_active, pane_width, pane_height, pane_left, pane_top,
      //         pane_title, pane_current_command, cursor_x, cursor_y
      final sessionName = parts[0];
      final sessionId = parts[1];
      final windowIndex = int.tryParse(parts[2]) ?? 0;
      final windowId = parts[3];
      final windowName = parts[4];
      final windowActive = parts[5] == '1';
      final paneIndex = int.tryParse(parts[6]) ?? 0;
      final paneId = parts[7];
      final paneActive = parts[8] == '1';
      final paneWidth = int.tryParse(parts[9]) ?? 80;
      final paneHeight = parts.length > 10 ? int.tryParse(parts[10]) ?? 24 : 24;
      final paneLeft = parts.length > 11 ? int.tryParse(parts[11]) ?? 0 : 0;
      final paneTop = parts.length > 12 ? int.tryParse(parts[12]) ?? 0 : 0;
      final paneTitle = parts.length > 13 && parts[13].isNotEmpty ? parts[13] : null;
      final paneCurrentCommand = parts.length > 14 && parts[14].isNotEmpty ? parts[14] : null;
      final cursorX = parts.length > 15 ? int.tryParse(parts[15]) ?? 0 : 0;
      final cursorY = parts.length > 16 ? int.tryParse(parts[16]) ?? 0 : 0;

      // Get or create session
      sessionsMap.putIfAbsent(
        sessionName,
        () => TmuxSession(name: sessionName, id: sessionId),
      );

      final windowFlags = parts.length > 17 ? _parseWindowFlags(parts[17]) : const <TmuxWindowFlag>{};

      // Get or create window map
      windowsMap.putIfAbsent(sessionName, () => {});
      final windows = windowsMap[sessionName]!;

      // Get or create window
      windows.putIfAbsent(
        windowIndex,
        () => TmuxWindow(
          index: windowIndex,
          id: windowId,
          name: windowName,
          active: windowActive,
          flags: windowFlags,
        ),
      );

      // Add pane
      windows[windowIndex]!.panes.add(TmuxPane(
        index: paneIndex,
        id: paneId,
        active: paneActive,
        width: paneWidth,
        height: paneHeight,
        left: paneLeft,
        top: paneTop,
        title: paneTitle,
        currentCommand: paneCurrentCommand,
        cursorX: cursorX,
        cursorY: cursorY,
      ));
    }

    // Build tree
    final sessions = <TmuxSession>[];
    for (final entry in sessionsMap.entries) {
      final session = entry.value;
      final windows = windowsMap[entry.key]?.values.toList() ?? [];
      windows.sort((a, b) => a.index.compareTo(b.index));
      sessions.add(session.copyWith(
        windows: windows,
        windowCount: windows.length,
      ));
    }

    return sessions;
  }

  // ===== Utilities =====

  /// Parse Unix timestamp
  static DateTime? _parseTimestamp(String value) {
    final seconds = int.tryParse(value);
    if (seconds == null) return null;
    return DateTime.fromMillisecondsSinceEpoch(seconds * 1000);
  }

  /// Parse size string (e.g. "80x24")
  static ({int width, int height}) _parseSize(String value) {
    final parts = value.split('x');
    return (
      width: parts.isNotEmpty ? int.tryParse(parts[0]) ?? 80 : 80,
      height: parts.length > 1 ? int.tryParse(parts[1]) ?? 24 : 24,
    );
  }

  /// Parse window flags
  static Set<TmuxWindowFlag> _parseWindowFlags(String flags) {
    final result = <TmuxWindowFlag>{};
    if (flags.contains('*')) result.add(TmuxWindowFlag.current);
    if (flags.contains('-')) result.add(TmuxWindowFlag.last);
    if (flags.contains('#')) result.add(TmuxWindowFlag.activity);
    if (flags.contains('!')) result.add(TmuxWindowFlag.bell);
    if (flags.contains('~')) result.add(TmuxWindowFlag.silence);
    if (flags.contains('M')) result.add(TmuxWindowFlag.marked);
    if (flags.contains('Z')) result.add(TmuxWindowFlag.zoomed);
    return result;
  }

  /// Guess width from lines
  static int _guessWidth(List<String> lines) {
    if (lines.isEmpty) return 80;
    int maxWidth = 0;
    for (final line in lines) {
      final stripped = stripAnsiCodes(line);
      if (stripped.length > maxWidth) {
        maxWidth = stripped.length;
      }
    }
    return maxWidth > 0 ? maxWidth : 80;
  }

  /// Check if tmux is running (server startup verification)
  static bool isServerRunning(String output) {
    final lower = output.toLowerCase();
    return !lower.contains('no server running') &&
        !lower.contains('error connecting') &&
        !lower.contains('failed to connect') &&
        !lower.contains('command not found') &&
        !lower.contains('no such file or directory') &&
        !lower.contains('permission denied');
  }

  /// Extract error message
  static String? extractError(String output) {
    final lower = output.toLowerCase();
    if (lower.contains('no server running')) {
      return 'tmux server is not running';
    }
    if (lower.contains('session not found')) {
      return 'Session not found';
    }
    if (lower.contains('window not found')) {
      return 'Window not found';
    }
    if (lower.contains('pane not found') || lower.contains("can't find pane")) {
      return 'Pane not found';
    }
    if (lower.contains('error')) {
      // Return the first error line
      for (final line in output.split('\n')) {
        if (line.toLowerCase().contains('error')) {
          return line.trim();
        }
      }
    }
    return null;
  }
}

// ===== Data Models =====

/// Window flags
enum TmuxWindowFlag {
  current,  // * - current window
  last,     // - - last active window
  activity, // # - activity detected
  bell,     // ! - bell detected
  silence,  // ~ - silence detected
  marked,   // M - marked
  zoomed,   // Z - zoomed
}

/// tmux session
class TmuxSession {
  final String name;
  final String? id;
  final DateTime? created;
  final bool attached;
  final int windowCount;
  final List<TmuxWindow> windows;

  const TmuxSession({
    required this.name,
    this.id,
    this.created,
    this.attached = false,
    this.windowCount = 0,
    this.windows = const [],
  });

  TmuxSession copyWith({
    String? name,
    String? id,
    DateTime? created,
    bool? attached,
    int? windowCount,
    List<TmuxWindow>? windows,
  }) {
    return TmuxSession(
      name: name ?? this.name,
      id: id ?? this.id,
      created: created ?? this.created,
      attached: attached ?? this.attached,
      windowCount: windowCount ?? this.windowCount,
      windows: windows ?? this.windows,
    );
  }

  /// Get the target string for this session
  String get target => name;

  @override
  String toString() => 'TmuxSession($name, windows: $windowCount, attached: $attached)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TmuxSession && runtimeType == other.runtimeType && name == other.name;

  @override
  int get hashCode => name.hashCode;
}

/// tmux window
class TmuxWindow {
  final int index;
  final String? id;
  final String name;
  final bool active;
  final int paneCount;
  final Set<TmuxWindowFlag> flags;
  final List<TmuxPane> panes;

  TmuxWindow({
    required this.index,
    this.id,
    required this.name,
    this.active = false,
    this.paneCount = 1,
    this.flags = const {},
    List<TmuxPane>? panes,
  }) : panes = panes ?? [];

  TmuxWindow copyWith({
    int? index,
    String? id,
    String? name,
    bool? active,
    int? paneCount,
    Set<TmuxWindowFlag>? flags,
    List<TmuxPane>? panes,
  }) {
    return TmuxWindow(
      index: index ?? this.index,
      id: id ?? this.id,
      name: name ?? this.name,
      active: active ?? this.active,
      paneCount: paneCount ?? this.paneCount,
      flags: flags ?? this.flags,
      panes: panes ?? this.panes,
    );
  }

  /// Get the target string for this window
  String target(String sessionName) => '$sessionName:$index';

  /// Whether this is the current window
  bool get isCurrent => flags.contains(TmuxWindowFlag.current);

  /// Whether this window is zoomed
  bool get isZoomed => flags.contains(TmuxWindowFlag.zoomed);

  @override
  String toString() => 'TmuxWindow($index: $name, panes: $paneCount, active: $active)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TmuxWindow && runtimeType == other.runtimeType && index == other.index && id == other.id;

  @override
  int get hashCode => Object.hash(index, id);
}

/// tmux pane
class TmuxPane {
  final int index;
  final String id;
  final bool active;
  final String? currentCommand;
  final String? title;
  final int width;
  final int height;
  final int left;
  final int top;
  final int cursorX;
  final int cursorY;

  const TmuxPane({
    required this.index,
    required this.id,
    this.active = false,
    this.currentCommand,
    this.title,
    this.width = 80,
    this.height = 24,
    this.left = 0,
    this.top = 0,
    this.cursorX = 0,
    this.cursorY = 0,
  });

  TmuxPane copyWith({
    int? index,
    String? id,
    bool? active,
    String? currentCommand,
    String? title,
    int? width,
    int? height,
    int? left,
    int? top,
    int? cursorX,
    int? cursorY,
  }) {
    return TmuxPane(
      index: index ?? this.index,
      id: id ?? this.id,
      active: active ?? this.active,
      currentCommand: currentCommand ?? this.currentCommand,
      title: title ?? this.title,
      width: width ?? this.width,
      height: height ?? this.height,
      left: left ?? this.left,
      top: top ?? this.top,
      cursorX: cursorX ?? this.cursorX,
      cursorY: cursorY ?? this.cursorY,
    );
  }

  /// Get the target string for this pane
  String get target => id;

  /// Get size in "80x24" format
  String get sizeString => '${width}x$height';

  @override
  String toString() => 'TmuxPane($index: $id, ${width}x$height, active: $active)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TmuxPane && runtimeType == other.runtimeType && id == other.id;

  @override
  int get hashCode => id.hashCode;
}

/// Pane content
class TmuxPaneContent {
  final List<String> lines;
  final int width;
  final int height;
  final bool hasAnsiColors;

  const TmuxPaneContent({
    required this.lines,
    required this.width,
    required this.height,
    this.hasAnsiColors = false,
  });

  /// Get plain text
  String get plainText {
    if (!hasAnsiColors) {
      return lines.join('\n');
    }
    return lines.map(TmuxParser.stripAnsiCodes).join('\n');
  }

  /// Get raw text (including ANSI codes)
  String get rawText => lines.join('\n');

  /// Whether the content is empty
  bool get isEmpty => lines.isEmpty || lines.every((line) => line.trim().isEmpty);

  @override
  String toString() => 'TmuxPaneContent(${width}x$height, ${lines.length} lines)';
}

// ===== Aliases for backward compatibility =====

/// @deprecated Use [TmuxSession] instead
typedef TmuxSessionInfo = TmuxSession;

/// @deprecated Use [TmuxWindow] instead
typedef TmuxWindowInfo = TmuxWindow;

/// @deprecated Use [TmuxPane] instead
typedef TmuxPaneInfo = TmuxPane;
