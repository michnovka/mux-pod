import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_muxpod/services/terminal/xterm_input_adapter.dart';
import 'package:xterm/xterm.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('XtermInputAdapter', () {
    test('applyModifiersToTmuxKey uses tmux modifier order', () {
      final key = XtermInputAdapter.applyModifiersToTmuxKey(
        'c',
        ctrl: true,
        alt: true,
      );

      expect(key, 'C-M-c');
    });

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

    test('encodeTmuxKey returns the generated output sequence', () {
      final encoded = XtermInputAdapter.encodeTmuxKey('Escape');

      expect(encoded, '\x1b');
    });

    test('encodeOutputWithModifiers applies Ctrl to a plain character', () {
      final encoded = XtermInputAdapter.encodeOutputWithModifiers(
        'c',
        ctrl: true,
      );

      expect(encoded, '\x03');
    });

    test('encodeOutputWithModifiers applies Alt to multi-character text', () {
      final encoded = XtermInputAdapter.encodeOutputWithModifiers(
        'paste',
        alt: true,
      );

      expect(encoded, '\x1bpaste');
    });

    test(
      'encodeOutputWithModifiers returns null for unsupported Ctrl text',
      () {
        final encoded = XtermInputAdapter.encodeOutputWithModifiers(
          'paste',
          ctrl: true,
        );

        expect(encoded, isNull);
      },
    );

    test('returns false for unknown tmux key labels', () {
      final terminal = Terminal();

      final handled = XtermInputAdapter.sendTmuxKey(terminal, 'NotARealKey');

      expect(handled, isFalse);
    });
  });
}
