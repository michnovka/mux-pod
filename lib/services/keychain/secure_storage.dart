import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Secure storage service
class SecureStorageService {
  final FlutterSecureStorage _storage;

  SecureStorageService()
      : _storage = const FlutterSecureStorage();

  // ===== Password management =====

  /// Save a password
  Future<void> savePassword(String connectionId, String password) async {
    await _storage.write(
      key: 'password_$connectionId',
      value: password,
    );
  }

  /// Retrieve a password
  Future<String?> getPassword(String connectionId) async {
    return await _storage.read(key: 'password_$connectionId');
  }

  /// Delete a password
  Future<void> deletePassword(String connectionId) async {
    await _storage.delete(key: 'password_$connectionId');
  }

  // ===== SSH key management =====

  /// Save a private key
  Future<void> savePrivateKey(String keyId, String privateKey) async {
    await _storage.write(
      key: 'privatekey_$keyId',
      value: privateKey,
    );
  }

  /// Retrieve a private key
  Future<String?> getPrivateKey(String keyId) async {
    return await _storage.read(key: 'privatekey_$keyId');
  }

  /// Delete a private key
  Future<void> deletePrivateKey(String keyId) async {
    await _storage.delete(key: 'privatekey_$keyId');
  }

  /// Save a passphrase
  Future<void> savePassphrase(String keyId, String passphrase) async {
    await _storage.write(
      key: 'passphrase_$keyId',
      value: passphrase,
    );
  }

  /// Retrieve a passphrase
  Future<String?> getPassphrase(String keyId) async {
    return await _storage.read(key: 'passphrase_$keyId');
  }

  /// Delete a passphrase
  Future<void> deletePassphrase(String keyId) async {
    await _storage.delete(key: 'passphrase_$keyId');
  }

  // ===== Utilities =====

  /// Delete all data
  Future<void> deleteAll() async {
    await _storage.deleteAll();
  }

  /// Retrieve a list of keys with the specified prefix
  Future<List<String>> getKeysWithPrefix(String prefix) async {
    final all = await _storage.readAll();
    return all.keys.where((key) => key.startsWith(prefix)).toList();
  }
}
