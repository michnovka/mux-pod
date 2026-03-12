import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_muxpod/services/terminal/terminal_output_normalizer.dart';
import 'package:xterm/xterm.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('normalizeTerminalOutput', () {
    test('fixes xterm cursor position reports to one-based coordinates', () {
      final outputs = <String>[];
      final terminal = Terminal(onOutput: outputs.add);

      terminal.write('\x1b[6;4H');
      terminal.write('\x1b[6n');

      expect(outputs, hasLength(1));
      expect(outputs.single, '\x1b[5;3R');
      expect(normalizeTerminalOutput(outputs.single), '\x1b[6;4R');
    });

    test('leaves non-CPR terminal output untouched', () {
      expect(normalizeTerminalOutput('hello'), 'hello');
      expect(normalizeTerminalOutput('\x1b[0n'), '\x1b[0n');
    });

    test('fixes CPR sequences when they are embedded in larger output', () {
      expect(
        normalizeTerminalOutput('\x1b[0n\x1b[5;3R\x1b[?25h'),
        '\x1b[0n\x1b[6;4R\x1b[?25h',
      );
    });
  });
}
