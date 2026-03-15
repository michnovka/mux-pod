import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_muxpod/services/tmux/tmux_commands.dart';

void main() {
  group('TmuxCommands.sendKeys', () {
    test('encodes literal control bytes through printf-safe octal escapes', () {
      final command = TmuxCommands.sendKeys('%1', '\x1b[I\x7f', literal: true);

      expect(command, contains(r'$(printf'));
      expect(command, contains(r'\033\133\111\177'));
      expect(command, isNot(contains('\x1b')));
      expect(command, isNot(contains('\x7f')));
    });
  });

  group('TmuxCommands.sendKeysLiteralChunks', () {
    test('returns a single command for short literal input', () {
      final commands = TmuxCommands.sendKeysLiteralChunks('%1', 'ping');

      expect(commands, [TmuxCommands.sendKeys('%1', 'ping', literal: true)]);
    });

    test('splits long literal input into bounded chunks', () {
      final commands = TmuxCommands.sendKeysLiteralChunks(
        '%1',
        'abcdefghij',
        maxChunkLength: 4,
      );

      expect(commands, [
        TmuxCommands.sendKeys('%1', 'abcd', literal: true),
        TmuxCommands.sendKeys('%1', 'efgh', literal: true),
        TmuxCommands.sendKeys('%1', 'ij', literal: true),
      ]);
    });

    test('does not split surrogate pairs across chunk boundaries', () {
      final commands = TmuxCommands.sendKeysLiteralChunks(
        '%1',
        'a🙂b',
        maxChunkLength: 2,
      );

      expect(commands, [
        TmuxCommands.sendKeys('%1', 'a', literal: true),
        TmuxCommands.sendKeys('%1', '🙂', literal: true),
        TmuxCommands.sendKeys('%1', 'b', literal: true),
      ]);
    });
  });

  group('TmuxCommands.resizePaneColumns', () {
    test('generates correct resize-pane -x command', () {
      final command = TmuxCommands.resizePaneColumns('%1', 120);
      expect(command, equals('tmux resize-pane -t %1 -x 120'));
    });

    test('escapes special characters in pane id', () {
      final command = TmuxCommands.resizePaneColumns('my pane', 80);
      expect(command, contains('"my pane"'));
      expect(command, contains('-x 80'));
    });
  });

  group('TmuxCommands.resizePaneRows', () {
    test('generates correct resize-pane -y command', () {
      final command = TmuxCommands.resizePaneRows('%1', 50);
      expect(command, equals('tmux resize-pane -t %1 -y 50'));
    });

    test('escapes special characters in pane id', () {
      final command = TmuxCommands.resizePaneRows('my pane', 24);
      expect(command, contains('"my pane"'));
      expect(command, contains('-y 24'));
    });
  });

  group('TmuxCommands.resizeWindowColumns', () {
    test('generates correct resize-window -x command', () {
      final command = TmuxCommands.resizeWindowColumns('main:0', 200);
      expect(command, equals('tmux resize-window -t main:0 -x 200'));
    });

    test('escapes special characters in target', () {
      final command =
          TmuxCommands.resizeWindowColumns('my session:0', 132);
      expect(command, contains('"my session:0"'));
      expect(command, contains('-x 132'));
    });
  });

  group('TmuxCommands.resizeWindowRows', () {
    test('generates correct resize-window -y command', () {
      final command = TmuxCommands.resizeWindowRows('main:0', 50);
      expect(command, equals('tmux resize-window -t main:0 -y 50'));
    });

    test('escapes special characters in target', () {
      final command = TmuxCommands.resizeWindowRows('my session:0', 24);
      expect(command, contains('"my session:0"'));
      expect(command, contains('-y 24'));
    });
  });

  group('TmuxCommands.capturePane', () {
    test('can join wrapped lines for snapshot replay', () {
      final command = TmuxCommands.capturePane(
        '%1',
        escapeSequences: true,
        startLine: -100,
        joinWrappedLines: true,
      );

      expect(command, contains('capture-pane'));
      expect(command, contains(' -e '));
      expect(command, contains(' -J '));
      expect(command, contains(' -S -100'));
    });
  });
}
