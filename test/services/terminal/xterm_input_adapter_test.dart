import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_muxpod/services/terminal/xterm_input_adapter.dart';
import 'package:xterm/xterm.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('XtermInputAdapter', () {
    test('sendText forwards plain text to terminal output', () {
      final output = <String>[];
      final terminal = Terminal(onOutput: output.add);

      final handled = XtermInputAdapter.sendText(terminal, 'abc');

      expect(handled, isTrue);
      expect(output, ['abc']);
    });

    test('sendTmuxKey Enter emits carriage return', () {
      final output = <String>[];
      final terminal = Terminal(onOutput: output.add);

      final handled = XtermInputAdapter.sendTmuxKey(terminal, 'Enter');

      expect(handled, isTrue);
      expect(output, ['\r']);
    });

    test('sendTmuxKey reverse tab emits xterm back-tab sequence', () {
      final output = <String>[];
      final terminal = Terminal(onOutput: output.add);

      final handled = XtermInputAdapter.sendTmuxKey(terminal, 'BTab');

      expect(handled, isTrue);
      expect(output, ['\x1b[Z']);
    });

    test('sendTmuxKey control character emits ETX for C-c', () {
      final output = <String>[];
      final terminal = Terminal(onOutput: output.add);

      final handled = XtermInputAdapter.sendTmuxKey(terminal, 'C-c');

      expect(handled, isTrue);
      expect(output, ['\x03']);
    });

    test('returns false for unknown tmux key labels', () {
      final terminal = Terminal();

      final handled = XtermInputAdapter.sendTmuxKey(terminal, 'NotARealKey');

      expect(handled, isFalse);
    });
  });
}
