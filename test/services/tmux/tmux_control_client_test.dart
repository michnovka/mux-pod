import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_muxpod/services/ssh/ssh_client.dart';
import 'package:flutter_muxpod/services/tmux/tmux_control_client.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('TmuxControlClient', () {
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

    test('completes pending control command futures with error on %error', () async {
      final client = TmuxControlClient(SshClient());
      final future = client.debugPrimePendingCommand();

      client.debugAddBytes(Uint8List.fromList(utf8.encode('%begin 1 2 0\n')));
      client.debugAddBytes(
        Uint8List.fromList(
          utf8.encode('no current client\n%error 1 2 0\n'),
        ),
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
    });
  });
}
