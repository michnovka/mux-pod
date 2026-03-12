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
