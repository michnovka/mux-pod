// ignore_for_file: unnecessary_brace_in_string_interps
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_muxpod/services/tmux/tmux_parser.dart';

void main() {
  const sep = TmuxParser.defaultDelimiter; // '|||'

  group('TmuxParser', () {
    group('isServerRunning', () {
      test('returns true for normal output', () {
        expect(TmuxParser.isServerRunning('main|||1234|||0|||3|||\$0'), isTrue);
      });

      test('returns false for "no server running"', () {
        expect(TmuxParser.isServerRunning('no server running on /tmp/tmux-1000/default'), isFalse);
      });

      test('returns false for "error connecting"', () {
        expect(TmuxParser.isServerRunning('error connecting to /tmp/tmux-1000/default'), isFalse);
      });

      test('returns false for "failed to connect"', () {
        expect(TmuxParser.isServerRunning('failed to connect to server'), isFalse);
      });

      test('returns false for "command not found"', () {
        expect(TmuxParser.isServerRunning('tmux: command not found'), isFalse);
      });

      test('returns false for "no such file or directory"', () {
        expect(TmuxParser.isServerRunning('/usr/bin/tmux: No such file or directory'), isFalse);
      });

      test('returns false for "permission denied"', () {
        expect(TmuxParser.isServerRunning('Permission denied'), isFalse);
      });

      test('case insensitive', () {
        expect(TmuxParser.isServerRunning('No Server Running'), isFalse);
        expect(TmuxParser.isServerRunning('COMMAND NOT FOUND'), isFalse);
      });
    });

    group('parseSessionLine', () {
      test('parses full 5-field session line', () {
        final line = 'main${sep}1710000000${sep}1${sep}3${sep}\$0';
        final session = TmuxParser.parseSessionLine(line);

        expect(session, isNotNull);
        expect(session!.name, 'main');
        expect(session.created, isNotNull);
        expect(session.created!.millisecondsSinceEpoch, 1710000000000);
        expect(session.attached, isTrue);
        expect(session.windowCount, 3);
        expect(session.id, '\$0');
      });

      test('parses minimal 2-field session line', () {
        final line = 'dev${sep}1710000000';
        final session = TmuxParser.parseSessionLine(line);

        expect(session, isNotNull);
        expect(session!.name, 'dev');
        expect(session.attached, isFalse);
        expect(session.windowCount, 0);
        expect(session.id, isNull);
      });

      test('returns null for single-field line (no delimiter)', () {
        expect(TmuxParser.parseSessionLine('just-a-name'), isNull);
      });

      test('returns null for empty name', () {
        expect(TmuxParser.parseSessionLine('${sep}1710000000'), isNull);
      });

      test('returns null for empty line', () {
        expect(TmuxParser.parseSessionLine(''), isNull);
      });

      test('handles non-numeric timestamp gracefully', () {
        final line = 'main${sep}not-a-number${sep}0${sep}1';
        final session = TmuxParser.parseSessionLine(line);

        expect(session, isNotNull);
        expect(session!.name, 'main');
        expect(session.created, isNull);
      });

      test('handles non-numeric windowCount gracefully', () {
        final line = 'main${sep}1710000000${sep}0${sep}abc';
        final session = TmuxParser.parseSessionLine(line);

        expect(session, isNotNull);
        expect(session!.windowCount, 0);
      });
    });

    group('parseSessions', () {
      test('parses multi-line session output', () {
        final output = 'main${sep}1710000000${sep}1${sep}3${sep}\$0\n'
            'dev${sep}1710000100${sep}0${sep}1${sep}\$1\n';
        final sessions = TmuxParser.parseSessions(output);

        expect(sessions.length, 2);
        expect(sessions[0].name, 'main');
        expect(sessions[1].name, 'dev');
      });

      test('returns empty for server not running', () {
        expect(TmuxParser.parseSessions('no server running'), isEmpty);
      });

      test('skips empty lines', () {
        final output = '\nmain${sep}1710000000${sep}1${sep}3${sep}\$0\n\n';
        final sessions = TmuxParser.parseSessions(output);

        expect(sessions.length, 1);
        expect(sessions[0].name, 'main');
      });

      test('skips malformed lines', () {
        final output = 'main${sep}1710000000${sep}1${sep}3${sep}\$0\n'
            'garbage-no-delimiter\n'
            'dev${sep}1710000100${sep}0${sep}1${sep}\$1\n';
        final sessions = TmuxParser.parseSessions(output);

        expect(sessions.length, 2);
      });

      test('returns empty for empty string', () {
        expect(TmuxParser.parseSessions(''), isEmpty);
      });
    });

    group('parseSessionsSimple', () {
      test('parses colon-delimited simple format', () {
        const output = 'main:3:1\ndev:1:0\n';
        final sessions = TmuxParser.parseSessionsSimple(output);

        expect(sessions.length, 2);
        expect(sessions[0].name, 'main');
        expect(sessions[0].windowCount, 3);
        expect(sessions[0].attached, isTrue);
        expect(sessions[1].name, 'dev');
        expect(sessions[1].attached, isFalse);
      });

      test('skips lines with too few fields', () {
        const output = 'main:3:1\nmalformed\ndev:1:0\n';
        final sessions = TmuxParser.parseSessionsSimple(output);

        expect(sessions.length, 2);
      });
    });

    group('parseWindowLine', () {
      test('parses full 6-field window line', () {
        final line = '0${sep}@0${sep}bash${sep}1${sep}2${sep}*';
        final window = TmuxParser.parseWindowLine(line);

        expect(window, isNotNull);
        expect(window!.index, 0);
        expect(window.id, '@0');
        expect(window.name, 'bash');
        expect(window.active, isTrue);
        expect(window.paneCount, 2);
        expect(window.flags, contains(TmuxWindowFlag.current));
      });

      test('parses minimal 2-field window line', () {
        final line = '1${sep}@1';
        final window = TmuxParser.parseWindowLine(line);

        expect(window, isNotNull);
        expect(window!.index, 1);
        expect(window.id, '@1');
        expect(window.name, 'window-1');
        expect(window.active, isFalse);
      });

      test('returns null for non-integer index', () {
        final line = 'abc${sep}@0${sep}bash';
        expect(TmuxParser.parseWindowLine(line), isNull);
      });

      test('returns null for single field', () {
        expect(TmuxParser.parseWindowLine('0'), isNull);
      });

      test('parses window flags correctly', () {
        final line = '0${sep}@0${sep}vim${sep}1${sep}1${sep}*Z';
        final window = TmuxParser.parseWindowLine(line);

        expect(window!.flags, contains(TmuxWindowFlag.current));
        expect(window.flags, contains(TmuxWindowFlag.zoomed));
        expect(window.isCurrent, isTrue);
        expect(window.isZoomed, isTrue);
      });

      test('handles all window flag types', () {
        final line = '0${sep}@0${sep}test${sep}0${sep}1${sep}*-#!~MZ';
        final window = TmuxParser.parseWindowLine(line);

        expect(window!.flags, containsAll([
          TmuxWindowFlag.current,
          TmuxWindowFlag.last,
          TmuxWindowFlag.activity,
          TmuxWindowFlag.bell,
          TmuxWindowFlag.silence,
          TmuxWindowFlag.marked,
          TmuxWindowFlag.zoomed,
        ]));
      });
    });

    group('parseWindows', () {
      test('parses multi-line window output', () {
        final output = '0${sep}@0${sep}bash${sep}1${sep}1${sep}*\n'
            '1${sep}@1${sep}vim${sep}0${sep}2${sep}-\n';
        final windows = TmuxParser.parseWindows(output);

        expect(windows.length, 2);
        expect(windows[0].name, 'bash');
        expect(windows[1].name, 'vim');
      });
    });

    group('parsePaneLine', () {
      test('parses full 9-field pane line', () {
        final line = '0${sep}%0${sep}1${sep}bash${sep}pane-title${sep}80${sep}24${sep}5${sep}10';
        final pane = TmuxParser.parsePaneLine(line);

        expect(pane, isNotNull);
        expect(pane!.index, 0);
        expect(pane.id, '%0');
        expect(pane.active, isTrue);
        expect(pane.currentCommand, 'bash');
        expect(pane.title, 'pane-title');
        expect(pane.width, 80);
        expect(pane.height, 24);
        expect(pane.cursorX, 5);
        expect(pane.cursorY, 10);
      });

      test('parses minimal 2-field pane line', () {
        final line = '0${sep}%0';
        final pane = TmuxParser.parsePaneLine(line);

        expect(pane, isNotNull);
        expect(pane!.index, 0);
        expect(pane.id, '%0');
        expect(pane.active, isFalse);
        expect(pane.width, 80);
        expect(pane.height, 24);
      });

      test('returns null for single field', () {
        expect(TmuxParser.parsePaneLine('0'), isNull);
      });

      test('returns null for non-integer index', () {
        final line = 'x${sep}%0';
        expect(TmuxParser.parsePaneLine(line), isNull);
      });

      test('returns null for empty pane id', () {
        final line = '0${sep}';
        expect(TmuxParser.parsePaneLine(line), isNull);
      });

      test('handles non-numeric width/height gracefully', () {
        final line = '0${sep}%0${sep}1${sep}bash${sep}title${sep}abc${sep}xyz';
        final pane = TmuxParser.parsePaneLine(line);

        expect(pane, isNotNull);
        expect(pane!.width, 80); // default
        expect(pane.height, 24); // default
      });
    });

    group('parsePanes', () {
      test('parses multi-line pane output', () {
        final output = '0${sep}%0${sep}1${sep}bash${sep}${sep}80${sep}24${sep}0${sep}0\n'
            '1${sep}%1${sep}0${sep}vim${sep}${sep}80${sep}24${sep}0${sep}0\n';
        final panes = TmuxParser.parsePanes(output);

        expect(panes.length, 2);
        expect(panes[0].id, '%0');
        expect(panes[1].id, '%1');
      });
    });

    group('parsePanesSimple', () {
      test('parses colon-delimited simple format with WxH', () {
        const output = '0:%0:1:80x24\n1:%1:0:120x40\n';
        final panes = TmuxParser.parsePanesSimple(output);

        expect(panes.length, 2);
        expect(panes[0].id, '%0');
        expect(panes[0].active, isTrue);
        expect(panes[0].width, 80);
        expect(panes[0].height, 24);
        expect(panes[1].width, 120);
        expect(panes[1].height, 40);
      });

      test('skips lines with too few fields', () {
        const output = '0:%0:1:80x24\nmalformed\n';
        final panes = TmuxParser.parsePanesSimple(output);

        expect(panes.length, 1);
      });

      test('handles malformed size string', () {
        const output = '0:%0:1:invalid\n';
        final panes = TmuxParser.parsePanesSimple(output);

        expect(panes.length, 1);
        expect(panes[0].width, 80); // default
        expect(panes[0].height, 24); // default
      });
    });

    group('parseFullTree', () {
      test('parses complete tree from list-panes -a output', () {
        // session_name, session_id, window_index, window_id, window_name,
        // window_active, pane_index, pane_id, pane_active, pane_width,
        // pane_height, pane_left, pane_top, pane_title, pane_current_command,
        // cursor_x, cursor_y, window_flags
        final output =
            'main${sep}\$0${sep}0${sep}@0${sep}bash${sep}1${sep}0${sep}%0${sep}1${sep}80${sep}24${sep}0${sep}0${sep}title${sep}bash${sep}5${sep}10${sep}*\n'
            'main${sep}\$0${sep}0${sep}@0${sep}bash${sep}1${sep}1${sep}%1${sep}0${sep}80${sep}12${sep}0${sep}12${sep}${sep}vim${sep}0${sep}0${sep}*\n'
            'main${sep}\$0${sep}1${sep}@1${sep}logs${sep}0${sep}0${sep}%2${sep}1${sep}80${sep}24${sep}0${sep}0${sep}${sep}tail${sep}0${sep}0${sep}-\n'
            'dev${sep}\$1${sep}0${sep}@2${sep}code${sep}1${sep}0${sep}%3${sep}1${sep}120${sep}40${sep}0${sep}0${sep}${sep}nvim${sep}10${sep}20${sep}*\n';

        final sessions = TmuxParser.parseFullTree(output);

        expect(sessions.length, 2);

        // Session: main
        final main = sessions.firstWhere((s) => s.name == 'main');
        expect(main.id, '\$0');
        expect(main.windows.length, 2);
        expect(main.windowCount, 2);

        // Window: main:0 (bash)
        final win0 = main.windows[0];
        expect(win0.index, 0);
        expect(win0.name, 'bash');
        expect(win0.active, isTrue);
        expect(win0.panes.length, 2);
        expect(win0.flags, contains(TmuxWindowFlag.current));

        // Pane: main:0.0
        expect(win0.panes[0].id, '%0');
        expect(win0.panes[0].active, isTrue);
        expect(win0.panes[0].width, 80);
        expect(win0.panes[0].title, 'title');
        expect(win0.panes[0].currentCommand, 'bash');
        expect(win0.panes[0].cursorX, 5);
        expect(win0.panes[0].cursorY, 10);

        // Pane: main:0.1
        expect(win0.panes[1].id, '%1');
        expect(win0.panes[1].active, isFalse);

        // Window: main:1 (logs)
        final win1 = main.windows[1];
        expect(win1.index, 1);
        expect(win1.name, 'logs');
        expect(win1.panes.length, 1);
        expect(win1.flags, contains(TmuxWindowFlag.last));

        // Session: dev
        final dev = sessions.firstWhere((s) => s.name == 'dev');
        expect(dev.windows.length, 1);
        expect(dev.windows[0].panes[0].width, 120);
        expect(dev.windows[0].panes[0].height, 40);
      });

      test('returns empty for server not running', () {
        expect(TmuxParser.parseFullTree('no server running'), isEmpty);
      });

      test('returns empty for empty string', () {
        expect(TmuxParser.parseFullTree(''), isEmpty);
      });

      test('skips lines with too few fields', () {
        final output =
            'main${sep}\$0${sep}0${sep}@0${sep}bash${sep}1${sep}0${sep}%0${sep}1${sep}80${sep}24${sep}0${sep}0${sep}${sep}bash${sep}0${sep}0${sep}*\n'
            'malformed line\n';
        final sessions = TmuxParser.parseFullTree(output);

        expect(sessions.length, 1);
        expect(sessions[0].windows[0].panes.length, 1);
      });

      test('windows are sorted by index', () {
        final output =
            'main${sep}\$0${sep}2${sep}@2${sep}third${sep}0${sep}0${sep}%2${sep}1${sep}80${sep}24${sep}0${sep}0${sep}${sep}${sep}0${sep}0\n'
            'main${sep}\$0${sep}0${sep}@0${sep}first${sep}1${sep}0${sep}%0${sep}1${sep}80${sep}24${sep}0${sep}0${sep}${sep}${sep}0${sep}0\n'
            'main${sep}\$0${sep}1${sep}@1${sep}second${sep}0${sep}0${sep}%1${sep}1${sep}80${sep}24${sep}0${sep}0${sep}${sep}${sep}0${sep}0\n';
        final sessions = TmuxParser.parseFullTree(output);

        expect(sessions[0].windows[0].name, 'first');
        expect(sessions[0].windows[1].name, 'second');
        expect(sessions[0].windows[2].name, 'third');
      });

      test('handles pane_left and pane_top fields', () {
        final output =
            'main${sep}\$0${sep}0${sep}@0${sep}bash${sep}1${sep}0${sep}%0${sep}1${sep}40${sep}24${sep}0${sep}0${sep}${sep}${sep}0${sep}0\n'
            'main${sep}\$0${sep}0${sep}@0${sep}bash${sep}1${sep}1${sep}%1${sep}0${sep}39${sep}24${sep}41${sep}0${sep}${sep}${sep}0${sep}0\n';
        final sessions = TmuxParser.parseFullTree(output);

        final panes = sessions[0].windows[0].panes;
        expect(panes[0].left, 0);
        expect(panes[0].top, 0);
        expect(panes[1].left, 41);
        expect(panes[1].top, 0);
      });
    });

    group('parsePaneContent', () {
      test('parses lines and detects ANSI colors', () {
        const output = '\x1b[31mhello\x1b[0m\nworld\n';
        final content = TmuxParser.parsePaneContent(output);

        expect(content.lines.length, 2);
        expect(content.hasAnsiColors, isTrue);
        expect(content.height, 2);
      });

      test('strips trailing empty lines', () {
        const output = 'line1\nline2\n\n\n';
        final content = TmuxParser.parsePaneContent(output);

        expect(content.lines.length, 2);
      });

      test('handles empty input', () {
        final content = TmuxParser.parsePaneContent('');

        expect(content.isEmpty, isTrue);
      });

      test('respects explicit width/height', () {
        const output = 'hello\nworld\n';
        final content = TmuxParser.parsePaneContent(output, width: 120, height: 40);

        expect(content.width, 120);
      });

      test('guesses width from longest line', () {
        const output = 'short\na much longer line here\nhi\n';
        final content = TmuxParser.parsePaneContent(output);

        expect(content.width, 'a much longer line here'.length);
      });
    });

    group('stripAnsiCodes', () {
      test('strips color codes', () {
        expect(TmuxParser.stripAnsiCodes('\x1b[31mred\x1b[0m'), 'red');
      });

      test('strips multiple codes', () {
        expect(
          TmuxParser.stripAnsiCodes('\x1b[1m\x1b[31mbold red\x1b[0m normal'),
          'bold red normal',
        );
      });

      test('leaves plain text unchanged', () {
        expect(TmuxParser.stripAnsiCodes('hello world'), 'hello world');
      });

      test('handles empty string', () {
        expect(TmuxParser.stripAnsiCodes(''), '');
      });
    });

    group('extractError', () {
      test('detects no server running', () {
        expect(
          TmuxParser.extractError('no server running on /tmp/tmux-1000/default'),
          'tmux server is not running',
        );
      });

      test('detects session not found', () {
        expect(
          TmuxParser.extractError('session not found: foo'),
          'Session not found',
        );
      });

      test('detects window not found', () {
        expect(
          TmuxParser.extractError('window not found: 5'),
          'Window not found',
        );
      });

      test('detects pane not found', () {
        expect(TmuxParser.extractError("can't find pane: %5"), 'Pane not found');
        expect(TmuxParser.extractError('pane not found'), 'Pane not found');
      });

      test('extracts generic error line', () {
        expect(
          TmuxParser.extractError('some other error occurred'),
          'some other error occurred',
        );
      });

      test('returns null for normal output', () {
        expect(TmuxParser.extractError('main:3:1'), isNull);
      });
    });

    group('TmuxPaneContent', () {
      test('plainText strips ANSI when hasAnsiColors is true', () {
        const content = TmuxPaneContent(
          lines: ['\x1b[31mhello\x1b[0m', 'world'],
          width: 80,
          height: 2,
          hasAnsiColors: true,
        );
        expect(content.plainText, 'hello\nworld');
      });

      test('plainText returns raw when hasAnsiColors is false', () {
        const content = TmuxPaneContent(
          lines: ['hello', 'world'],
          width: 80,
          height: 2,
        );
        expect(content.plainText, 'hello\nworld');
      });

      test('rawText preserves ANSI codes', () {
        const content = TmuxPaneContent(
          lines: ['\x1b[31mhello\x1b[0m'],
          width: 80,
          height: 1,
          hasAnsiColors: true,
        );
        expect(content.rawText, '\x1b[31mhello\x1b[0m');
      });

      test('isEmpty for all-blank lines', () {
        const content = TmuxPaneContent(
          lines: ['  ', '', '   '],
          width: 80,
          height: 3,
        );
        expect(content.isEmpty, isTrue);
      });
    });

    group('data model', () {
      test('TmuxSession target returns name', () {
        const session = TmuxSession(name: 'main');
        expect(session.target, 'main');
      });

      test('TmuxSession equality by name', () {
        const a = TmuxSession(name: 'main', windowCount: 1);
        const b = TmuxSession(name: 'main', windowCount: 5);
        expect(a, equals(b));
      });

      test('TmuxWindow target includes session name', () {
        final window = TmuxWindow(index: 2, name: 'vim');
        expect(window.target('main'), 'main:2');
      });

      test('TmuxWindow equality by index and id', () {
        final a = TmuxWindow(index: 0, id: '@0', name: 'bash');
        final b = TmuxWindow(index: 0, id: '@0', name: 'different');
        expect(a, equals(b));
      });

      test('TmuxPane target returns id', () {
        const pane = TmuxPane(index: 0, id: '%5');
        expect(pane.target, '%5');
      });

      test('TmuxPane sizeString', () {
        const pane = TmuxPane(index: 0, id: '%0', width: 120, height: 40);
        expect(pane.sizeString, '120x40');
      });

      test('TmuxPane equality by id', () {
        const a = TmuxPane(index: 0, id: '%0', width: 80);
        const b = TmuxPane(index: 1, id: '%0', width: 120);
        expect(a, equals(b));
      });

      test('TmuxSession copyWith', () {
        const original = TmuxSession(name: 'main', windowCount: 1);
        final copy = original.copyWith(windowCount: 5, attached: true);
        expect(copy.name, 'main');
        expect(copy.windowCount, 5);
        expect(copy.attached, isTrue);
      });

      test('TmuxWindow copyWith', () {
        final original = TmuxWindow(index: 0, name: 'bash');
        final copy = original.copyWith(name: 'vim', active: true);
        expect(copy.index, 0);
        expect(copy.name, 'vim');
        expect(copy.active, isTrue);
      });

      test('TmuxPane copyWith', () {
        const original = TmuxPane(index: 0, id: '%0', width: 80);
        final copy = original.copyWith(width: 120, cursorX: 5);
        expect(copy.id, '%0');
        expect(copy.width, 120);
        expect(copy.cursorX, 5);
      });
    });
  });
}
