import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_muxpod/services/terminal/terminal_image_attachment.dart';

void main() {
  group('Terminal image attachment path generation', () {
    test('sanitizes image filenames and preserves known extensions', () {
      final filename = buildTerminalImageUploadFilename(
        originalFilename: 'Screenshot 2026-03-14 12.30.45.PNG',
        now: DateTime.utc(2026, 3, 14, 12, 30, 45, 123),
      );

      expect(
        filename,
        'muxpod-20260314-123045-123-screenshot-2026-03-14-12-30-45.png',
      );
    });

    test('falls back to png for unknown or missing extensions', () {
      expect(
        buildTerminalImageUploadFilename(
          originalFilename: 'diagram.heic',
          now: DateTime.utc(2026, 3, 14, 12, 30, 45, 123),
        ),
        'muxpod-20260314-123045-123-diagram.png',
      );

      expect(
        buildTerminalImageUploadFilename(
          originalFilename: 'camera-shot',
          now: DateTime.utc(2026, 3, 14, 12, 30, 45, 123),
        ),
        'muxpod-20260314-123045-123-camera-shot.png',
      );
    });

    test('builds remote upload targets under the app upload directory', () {
      final target = TerminalImageUploadTarget.forHomeDirectory(
        '/home/alice',
        originalFilename: 'Bug Report.JPG',
        now: DateTime.utc(2026, 3, 14, 12, 30, 45, 123),
      );

      expect(target.remoteDirectory, '/home/alice/.muxpod/uploads');
      expect(
        target.remotePath,
        '/home/alice/.muxpod/uploads/muxpod-20260314-123045-123-bug-report.jpg',
      );
    });
  });
}
