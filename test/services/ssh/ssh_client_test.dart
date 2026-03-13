import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_muxpod/services/ssh/ssh_client.dart';

void main() {
  group('SshClient.isSafeTmuxPath', () {
    test('accepts safe absolute tmux paths', () {
      expect(SshClient.isSafeTmuxPath('/usr/bin/tmux'), isTrue);
      expect(SshClient.isSafeTmuxPath('/opt/homebrew/bin/tmux-3.4'), isTrue);
    });

    test('rejects unsafe or non-absolute tmux paths', () {
      expect(SshClient.isSafeTmuxPath('tmux'), isFalse);
      expect(SshClient.isSafeTmuxPath('/usr/bin/tmux;rm -rf /'), isFalse);
      expect(SshClient.isSafeTmuxPath(r'/tmp/tmux $(id)'), isFalse);
      expect(SshClient.isSafeTmuxPath('/tmp/tmux\nwhoami'), isFalse);
    });
  });

  group('SshClient payload counters', () {
    test('tracks aggregate sent and received payload bytes', () {
      final client = SshClient();

      client.debugRecordPayloadBytes(received: 1536, sent: 512);
      client.debugRecordPayloadBytes(received: 64, sent: 128);

      expect(client.receivedPayloadBytes, 1600);
      expect(client.sentPayloadBytes, 640);
      expect(client.totalPayloadBytes, 2240);
    });
  });
}
