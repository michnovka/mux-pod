import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_muxpod/services/ssh/ssh_client.dart';
import 'package:flutter_muxpod/services/tmux/tmux_control_client.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('TmuxControlClient', () {
    test('builds a control-mode startup command with ignore-size', () {
      final command = TmuxControlClient.debugBuildStartupCommand(
        tmuxBinary: '/usr/local/bin/tmux',
        sessionName: 'demo-session',
      );

      expect(command, contains("exec '/usr/local/bin/tmux' -C"));
      expect(command, contains('attach-session -f ignore-size -t'));
      expect(command, contains("'demo-session'"));
    });

    test('parses pane output notifications and unescapes octal payloads', () {
      final outputs = <({String paneId, String data})>[];
      final client = TmuxControlClient(
        SshClient(),
        onPaneOutput: (paneId, data) {
          outputs.add((paneId: paneId, data: data));
        },
      );

      client.debugAddBytes(
        Uint8List.fromList(
          utf8.encode('%output %1 hello\\040world\\015\\012\n'),
        ),
      );

      expect(outputs, hasLength(1));
      expect(outputs.single.paneId, '%1');
      expect(outputs.single.data, 'hello world\r\n');
    });

    test('buffers partial lines across data chunks', () {
      final outputs = <({String paneId, String data})>[];
      final client = TmuxControlClient(
        SshClient(),
        onPaneOutput: (paneId, data) {
          outputs.add((paneId: paneId, data: data));
        },
      );

      client.debugAddBytes(Uint8List.fromList(utf8.encode('%output %1 hel')));
      client.debugAddBytes(Uint8List.fromList(utf8.encode('lo\\012\n')));

      expect(outputs, hasLength(1));
      expect(outputs.single.paneId, '%1');
      expect(outputs.single.data, 'hello\n');
    });

    test('preserves leading spaces in pane output payloads', () {
      final outputs = <({String paneId, String data})>[];
      final client = TmuxControlClient(
        SshClient(),
        onPaneOutput: (paneId, data) {
          outputs.add((paneId: paneId, data: data));
        },
      );

      client.debugAddBytes(
        Uint8List.fromList(utf8.encode('%output %1    prompt redraw\n')),
      );

      expect(outputs, hasLength(1));
      expect(outputs.single.paneId, '%1');
      expect(outputs.single.data, '   prompt redraw');
    });

    test('preserves leading spaces in extended output payloads', () {
      final outputs = <({String paneId, String data})>[];
      final client = TmuxControlClient(
        SshClient(),
        onPaneOutput: (paneId, data) {
          outputs.add((paneId: paneId, data: data));
        },
      );

      client.debugAddBytes(
        Uint8List.fromList(
          utf8.encode('%extended-output %1 0 :   prompt redraw\n'),
        ),
      );

      expect(outputs, hasLength(1));
      expect(outputs.single.paneId, '%1');
      expect(outputs.single.data, '  prompt redraw');
    });

    test('parses control notifications outside command blocks', () {
      final notifications = <TmuxControlNotification>[];
      final client = TmuxControlClient(
        SshClient(),
        onNotification: notifications.add,
      );

      client.debugAddBytes(
        Uint8List.fromList(
          utf8.encode(
            '%layout-change @1 b25f,80x24,0,0,2 b25f,80x24,0,0,2 *\n',
          ),
        ),
      );

      expect(notifications, hasLength(1));
      expect(notifications.single.name, 'layout-change');
      expect(notifications.single.arguments.first, '@1');
    });

    test('completes pending control command responses on %end', () async {
      final client = TmuxControlClient(SshClient());
      final future = client.debugPrimePendingCommand();

      client.debugAddBytes(Uint8List.fromList(utf8.encode('%begin 1 2 0\n')));
      client.debugAddBytes(
        Uint8List.fromList(
          utf8.encode('%1 1 bash\n%window-add @1\n%end 1 2 0\n'),
        ),
      );

      expect(await future, '%1 1 bash\n%window-add @1');
    });

    test(
      'completes pending control command futures with error on %error',
      () async {
        final client = TmuxControlClient(SshClient());
        final future = client.debugPrimePendingCommand();

        client.debugAddBytes(Uint8List.fromList(utf8.encode('%begin 1 2 0\n')));
        client.debugAddBytes(
          Uint8List.fromList(utf8.encode('no current client\n%error 1 2 0\n')),
        );

        await expectLater(
          future,
          throwsA(
            isA<TmuxControlClientError>().having(
              (error) => error.message,
              'message',
              'no current client',
            ),
          ),
        );
      },
    );

    test('unescapes mixed raw Unicode and octal escapes without overflow', () {
      final outputs = <({String paneId, String data})>[];
      final client = TmuxControlClient(
        SshClient(),
        onPaneOutput: (paneId, data) {
          outputs.add((paneId: paneId, data: data));
        },
      );

      // Raw multibyte Unicode (éééé) mixed with octal escape (\012 = newline)
      client.debugAddBytes(
        Uint8List.fromList(utf8.encode('%output %1 éééé\\012\n')),
      );

      expect(outputs, hasLength(1));
      expect(outputs.single.paneId, '%1');
      expect(outputs.single.data, 'éééé\n');
    });

    test('unescapes CJK characters mixed with octal escapes', () {
      final outputs = <({String paneId, String data})>[];
      final client = TmuxControlClient(
        SshClient(),
        onPaneOutput: (paneId, data) {
          outputs.add((paneId: paneId, data: data));
        },
      );

      // Raw CJK (漢漢) mixed with octal escape (\012 = newline)
      client.debugAddBytes(
        Uint8List.fromList(utf8.encode('%output %1 漢漢\\012\n')),
      );

      expect(outputs, hasLength(1));
      expect(outputs.single.paneId, '%1');
      expect(outputs.single.data, '漢漢\n');
    });

    test('tolerates malformed utf8 bytes in pane output', () {
      final outputs = <({String paneId, String data})>[];
      final client = TmuxControlClient(
        SshClient(),
        onPaneOutput: (paneId, data) {
          outputs.add((paneId: paneId, data: data));
        },
      );

      final bytes = <int>[
        ...ascii.encode('%output %1 '),
        0xC3,
        0x28,
        ...ascii.encode(r'\012'),
        0x0A,
      ];

      expect(
        () => client.debugAddBytes(Uint8List.fromList(bytes)),
        returnsNormally,
      );

      expect(outputs, hasLength(1));
      expect(outputs.single.paneId, '%1');
      expect(outputs.single.data, '\uFFFD(\n');
    });

    test('continues parsing later output after a malformed line', () {
      final outputs = <({String paneId, String data})>[];
      final client = TmuxControlClient(
        SshClient(),
        onPaneOutput: (paneId, data) {
          outputs.add((paneId: paneId, data: data));
        },
      );

      final bytes = <int>[
        ...ascii.encode('%output %1 '),
        0xC3,
        0x28,
        ...ascii.encode(r'\012'),
        0x0A,
        ...ascii.encode('%output %1 ok'),
        ...ascii.encode(r'\012'),
        0x0A,
      ];

      client.debugAddBytes(Uint8List.fromList(bytes));

      expect(outputs, hasLength(2));
      expect(outputs[0], (paneId: '%1', data: '\uFFFD(\n'));
      expect(outputs[1], (paneId: '%1', data: 'ok\n'));
    });

    test('preserves multibyte utf8 split across byte chunks', () {
      final outputs = <({String paneId, String data})>[];
      final client = TmuxControlClient(
        SshClient(),
        onPaneOutput: (paneId, data) {
          outputs.add((paneId: paneId, data: data));
        },
      );

      final encoded = utf8.encode('%output %1 é\\012\n');
      client.debugAddBytes(Uint8List.fromList(encoded.sublist(0, 12)));
      client.debugAddBytes(Uint8List.fromList(encoded.sublist(12)));

      expect(outputs, hasLength(1));
      expect(outputs.single, (paneId: '%1', data: 'é\n'));
    });
  });
}
