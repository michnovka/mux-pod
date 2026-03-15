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

  group('SshClient.resolveForTesting (tmux path resolution)', () {
    const tmuxPath = '/opt/homebrew/bin/tmux';

    test('resolves simple tmux command', () {
      expect(
        SshClient.resolveForTesting('tmux list-sessions', tmuxPath),
        equals('/opt/homebrew/bin/tmux list-sessions'),
      );
    });

    test('resolves tmux after newline+whitespace (multiline script)', () {
      const command = 'echo hello\n  tmux list-sessions';
      expect(
        SshClient.resolveForTesting(command, tmuxPath),
        equals('echo hello\n  /opt/homebrew/bin/tmux list-sessions'),
      );
    });

    test(r'resolves tmux inside $(...) subshell', () {
      const command = r'echo $(tmux display-message -p "#{session_name}")';
      expect(
        SshClient.resolveForTesting(command, tmuxPath),
        equals(
          r'echo $(/opt/homebrew/bin/tmux display-message -p "#{session_name}")',
        ),
      );
    });

    test('does not double-replace already-resolved absolute path', () {
      const command = '/usr/bin/tmux list-sessions';
      // '/usr/bin/tmux' does not match because 'tmux' is not preceded by
      // start-of-line/whitespace/;/|/&/( — it's preceded by '/'.
      expect(
        SshClient.resolveForTesting(command, tmuxPath),
        equals('/usr/bin/tmux list-sessions'),
      );
    });

    test('resolves tmux after semicolon', () {
      const command = 'echo start; tmux list-sessions';
      expect(
        SshClient.resolveForTesting(command, tmuxPath),
        equals('echo start; /opt/homebrew/bin/tmux list-sessions'),
      );
    });

    test('resolves tmux after pipe', () {
      const command = 'echo x | tmux load-buffer -';
      expect(
        SshClient.resolveForTesting(command, tmuxPath),
        equals('echo x | /opt/homebrew/bin/tmux load-buffer -'),
      );
    });

    test('resolves tmux after &&', () {
      const command = 'true && tmux list-sessions';
      expect(
        SshClient.resolveForTesting(command, tmuxPath),
        equals('true && /opt/homebrew/bin/tmux list-sessions'),
      );
    });
  });

  group('SshClient keep-alive latency', () {
    test('tracks the latest keep-alive latency sample', () {
      final client = SshClient();

      expect(client.lastKeepAliveLatencyMs, 0);
      expect(client.lastKeepAliveLatencyAt, isNull);

      client.debugRecordKeepAliveLatency(87);

      expect(client.lastKeepAliveLatencyMs, 87);
      expect(client.lastKeepAliveLatencyAt, isNotNull);
    });
  });
}
