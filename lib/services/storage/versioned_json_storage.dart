import 'dart:convert';

const int sharedPreferencesSchemaVersion1 = 1;

class VersionedJsonLoadResult<T> {
  final T value;
  final int version;
  final bool usedLegacyFormat;

  const VersionedJsonLoadResult({
    required this.value,
    required this.version,
    required this.usedLegacyFormat,
  });
}

String encodeVersionedJsonEnvelope(
  Object? data, {
  int version = sharedPreferencesSchemaVersion1,
}) {
  return jsonEncode({'version': version, 'data': data});
}

VersionedJsonLoadResult<T> decodeVersionedJsonEnvelope<T>({
  required String raw,
  required String storageKey,
  required Map<int, T Function(Object? data)> versionReaders,
  T Function(Object? legacy)? legacyReader,
}) {
  final decoded = jsonDecode(raw);

  if (decoded is Map<String, dynamic> &&
      decoded['version'] is int &&
      decoded.containsKey('data')) {
    final version = decoded['version'] as int;
    final reader = versionReaders[version];
    if (reader == null) {
      throw UnsupportedError(
        'Unsupported SharedPreferences schema version $version for "$storageKey".',
      );
    }
    return VersionedJsonLoadResult(
      value: reader(decoded['data']),
      version: version,
      usedLegacyFormat: false,
    );
  }

  if (legacyReader == null) {
    throw FormatException(
      'Expected a versioned JSON envelope for SharedPreferences key "$storageKey".',
    );
  }

  return VersionedJsonLoadResult(
    value: legacyReader(decoded),
    version: sharedPreferencesSchemaVersion1,
    usedLegacyFormat: true,
  );
}
