const String terminalImageUploadSubdirectory = '.muxpod/uploads';
const int terminalImageAttachmentMaxBytes = 20 * 1024 * 1024;

class TerminalImageUploadTarget {
  final String remoteDirectory;
  final String remotePath;
  final String fileName;

  const TerminalImageUploadTarget({
    required this.remoteDirectory,
    required this.remotePath,
    required this.fileName,
  });

  factory TerminalImageUploadTarget.forHomeDirectory(
    String remoteHomeDirectory, {
    String? originalFilename,
    DateTime? now,
  }) {
    final fileName = buildTerminalImageUploadFilename(
      originalFilename: originalFilename,
      now: now,
    );
    final remoteDirectory = joinRemotePosixPath(
      remoteHomeDirectory,
      terminalImageUploadSubdirectory,
    );
    return TerminalImageUploadTarget(
      remoteDirectory: remoteDirectory,
      remotePath: joinRemotePosixPath(remoteDirectory, fileName),
      fileName: fileName,
    );
  }
}

String buildTerminalImageUploadFilename({
  String? originalFilename,
  DateTime? now,
}) {
  final timestamp = _formatTimestamp(now ?? DateTime.now().toUtc());
  final extension = normalizeTerminalImageExtension(originalFilename);
  final baseName = sanitizeTerminalImageBaseName(originalFilename);
  return 'muxpod-$timestamp-$baseName$extension';
}

String sanitizeTerminalImageBaseName(String? originalFilename) {
  final trimmed = originalFilename?.trim() ?? '';
  final withoutExtension = (() {
    if (trimmed.isEmpty) {
      return 'image';
    }
    final lastDot = trimmed.lastIndexOf('.');
    if (lastDot <= 0) {
      return trimmed;
    }
    return trimmed.substring(0, lastDot);
  })();

  final normalized = withoutExtension
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'-{2,}'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');

  if (normalized.isEmpty) {
    return 'image';
  }

  const maxLength = 48;
  if (normalized.length <= maxLength) {
    return normalized;
  }
  return normalized.substring(0, maxLength).replaceAll(RegExp(r'-+$'), '');
}

String normalizeTerminalImageExtension(String? originalFilename) {
  final trimmed = originalFilename?.trim() ?? '';
  final lastDot = trimmed.lastIndexOf('.');
  if (lastDot == -1 || lastDot == trimmed.length - 1) {
    return '.png';
  }

  switch (trimmed.substring(lastDot + 1).toLowerCase()) {
    case 'png':
      return '.png';
    case 'jpg':
      return '.jpg';
    case 'jpeg':
      return '.jpeg';
    case 'gif':
      return '.gif';
    case 'webp':
      return '.webp';
    case 'bmp':
      return '.bmp';
    default:
      return '.png';
  }
}

String joinRemotePosixPath(String parent, String child) {
  final normalizedParent = parent.trim();
  final normalizedChild = child.trim().replaceFirst(RegExp(r'^/+'), '');

  if (normalizedParent.isEmpty || normalizedParent == '/') {
    return '/$normalizedChild';
  }

  final parentWithoutSlash = normalizedParent.endsWith('/')
      ? normalizedParent.substring(0, normalizedParent.length - 1)
      : normalizedParent;
  return '$parentWithoutSlash/$normalizedChild';
}

String _formatTimestamp(DateTime time) {
  final year = time.year.toString().padLeft(4, '0');
  final month = time.month.toString().padLeft(2, '0');
  final day = time.day.toString().padLeft(2, '0');
  final hour = time.hour.toString().padLeft(2, '0');
  final minute = time.minute.toString().padLeft(2, '0');
  final second = time.second.toString().padLeft(2, '0');
  final millisecond = time.millisecond.toString().padLeft(3, '0');
  return '$year$month$day-$hour$minute$second-$millisecond';
}
