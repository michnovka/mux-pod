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
}
