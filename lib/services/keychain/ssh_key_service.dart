import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart' as crypto;
import 'package:dartssh2/dartssh2.dart';
import 'package:pointycastle/export.dart' as pc;

/// Data class for SSH key pairs
class SshKeyPair {
  final String type; // 'ed25519' | 'rsa-2048' | 'rsa-3072' | 'rsa-4096'
  final Uint8List privateKeyBytes;
  final Uint8List publicKeyBytes;
  final String fingerprint;
  final String privatePem;
  final String publicKeyString; // authorized_keys format

  const SshKeyPair({
    required this.type,
    required this.privateKeyBytes,
    required this.publicKeyBytes,
    required this.fingerprint,
    required this.privatePem,
    required this.publicKeyString,
  });
}

/// SSH key service
class SshKeyService {
  SshKeyService({
    Future<SshKeyPair> Function({required int bits, String? comment})?
    rsaGenerator,
  }) : _rsaGenerator = rsaGenerator ?? _generateRsaOnIsolate;

  final Future<SshKeyPair> Function({required int bits, String? comment})
  _rsaGenerator;

  /// Generate an Ed25519 key pair
  Future<SshKeyPair> generateEd25519({String? comment}) async {
    final algorithm = crypto.Ed25519();
    final keyPair = await algorithm.newKeyPair();

    final privateKeyBytes =
        Uint8List.fromList(await keyPair.extractPrivateKeyBytes());
    final publicKey = await keyPair.extractPublicKey();
    final publicKeyBytes = Uint8List.fromList(publicKey.bytes);

    final fingerprint = calculateFingerprint('ssh-ed25519', publicKeyBytes);
    final privatePem =
        _buildEd25519Pem(privateKeyBytes, publicKeyBytes, comment ?? '');
    final publicKeyString =
        toAuthorizedKeys('ssh-ed25519', publicKeyBytes, comment ?? '');

    return SshKeyPair(
      type: 'ed25519',
      privateKeyBytes: privateKeyBytes,
      publicKeyBytes: publicKeyBytes,
      fingerprint: fingerprint,
      privatePem: privatePem,
      publicKeyString: publicKeyString,
    );
  }

  /// Generate an RSA key pair
  Future<SshKeyPair> generateRsa({
    required int bits,
    String? comment,
  }) async {
    return _rsaGenerator(bits: bits, comment: comment);
  }

  SshKeyPair _generateRsaSync({
    required int bits,
    String? comment,
  }) {
    assert(bits == 2048 || bits == 3072 || bits == 4096);

    final secureRandom = pc.FortunaRandom();
    final rng = Random.secure();
    final seed = Uint8List(32);
    for (var i = 0; i < 32; i++) {
      seed[i] = rng.nextInt(256);
    }
    secureRandom.seed(pc.KeyParameter(seed));

    final keyGen = pc.RSAKeyGenerator()
      ..init(pc.ParametersWithRandom(
        pc.RSAKeyGeneratorParameters(BigInt.parse('65537'), bits, 64),
        secureRandom,
      ));

    final pair = keyGen.generateKeyPair();
    final publicKey = pair.publicKey as pc.RSAPublicKey;
    final privateKey = pair.privateKey as pc.RSAPrivateKey;

    final publicKeyBlob = _buildRsaPublicKeyBlob(publicKey);
    final fingerprint = calculateFingerprint('ssh-rsa', publicKeyBlob);
    final privatePem = _buildRsaPem(privateKey, publicKey, comment ?? '');
    final publicKeyString =
        toAuthorizedKeys('ssh-rsa', publicKeyBlob, comment ?? '');

    return SshKeyPair(
      type: 'rsa-$bits',
      privateKeyBytes: _rsaPrivateKeyToBytes(privateKey),
      publicKeyBytes: publicKeyBlob,
      fingerprint: fingerprint,
      privatePem: privatePem,
      publicKeyString: publicKeyString,
    );
  }

  /// Parse a key from a PEM string
  Future<SshKeyPair> parseFromPem(
    String pemContent, {
    String? passphrase,
  }) async {
    final keyPairs = SSHKeyPair.fromPem(pemContent, passphrase);
    if (keyPairs.isEmpty) {
      throw const FormatException('Invalid PEM format or wrong passphrase');
    }

    final keyPair = keyPairs.first;
    final type = keyPair.type;

    // Get public key blob (dartssh2's encode returns the complete SSH public key blob)
    final publicKeyBlob = keyPair.toPublicKey().encode();
    // Calculate fingerprint directly from the blob (no re-wrapping)
    final fingerprint = calculateFingerprintFromBlob(publicKeyBlob);

    String keyType;
    if (type == 'ssh-ed25519') {
      keyType = 'ed25519';
    } else if (type == 'ssh-rsa') {
      // Infer RSA bit size from the public key
      keyType = 'rsa-4096'; // default
    } else {
      keyType = type;
    }

    return SshKeyPair(
      type: keyType,
      privateKeyBytes: Uint8List(0), // Private key bytes are not needed when parsing
      publicKeyBytes: publicKeyBlob,
      fingerprint: fingerprint,
      privatePem: pemContent,
      publicKeyString: '$type ${base64Encode(publicKeyBlob)}',
    );
  }

  /// Check if the key is encrypted with a passphrase
  bool isEncrypted(String pemContent) {
    return SSHKeyPair.isEncryptedPem(pemContent);
  }

  /// Calculate the public key fingerprint (SHA256)
  String calculateFingerprint(String keyType, Uint8List publicKeyBytes) {
    // Build SSH public key blob
    final blob = _buildPublicKeyBlob(keyType, publicKeyBytes);
    return calculateFingerprintFromBlob(blob);
  }

  /// Calculate fingerprint directly from SSH public key blob
  String calculateFingerprintFromBlob(Uint8List blob) {
    final hash = sha256.convert(blob);
    final encoded = base64Encode(hash.bytes);
    // Remove padding '=' characters
    return 'SHA256:${encoded.replaceAll('=', '')}';
  }

  /// Convert public key to authorized_keys format
  String toAuthorizedKeys(String keyType, Uint8List publicKeyBytes, String comment) {
    final blob = _buildPublicKeyBlob(keyType, publicKeyBytes);
    final encoded = base64Encode(blob);
    return comment.isEmpty ? '$keyType $encoded' : '$keyType $encoded $comment';
  }

  // ===== Private Helper Methods =====

  Uint8List _buildPublicKeyBlob(String keyType, Uint8List publicKeyBytes) {
    if (keyType == 'ssh-ed25519') {
      // For Ed25519, the public key is 32 bytes
      final typeBytes = utf8.encode(keyType);
      final buffer = BytesBuilder();
      buffer.add(_encodeUint32(typeBytes.length));
      buffer.add(typeBytes);
      buffer.add(_encodeUint32(publicKeyBytes.length));
      buffer.add(publicKeyBytes);
      return buffer.toBytes();
    } else if (keyType == 'ssh-rsa') {
      // For RSA, publicKeyBytes is already in blob format
      return publicKeyBytes;
    }
    return publicKeyBytes;
  }

  Uint8List _buildRsaPublicKeyBlob(pc.RSAPublicKey publicKey) {
    final buffer = BytesBuilder();
    final typeBytes = utf8.encode('ssh-rsa');
    buffer.add(_encodeUint32(typeBytes.length));
    buffer.add(typeBytes);

    // e (public exponent)
    final eBytes = _encodeMpInt(publicKey.publicExponent!);
    buffer.add(eBytes);

    // n (modulus)
    final nBytes = _encodeMpInt(publicKey.modulus!);
    buffer.add(nBytes);

    return buffer.toBytes();
  }

  Uint8List _encodeMpInt(BigInt value) {
    var bytes = _bigIntToBytes(value);
    // Add 0x00 if the leading bit is 1
    if (bytes.isNotEmpty && (bytes[0] & 0x80) != 0) {
      bytes = Uint8List.fromList([0, ...bytes]);
    }
    final buffer = BytesBuilder();
    buffer.add(_encodeUint32(bytes.length));
    buffer.add(bytes);
    return buffer.toBytes();
  }

  Uint8List _bigIntToBytes(BigInt value) {
    var hex = value.toRadixString(16);
    if (hex.length % 2 != 0) {
      hex = '0$hex';
    }
    final bytes = <int>[];
    for (var i = 0; i < hex.length; i += 2) {
      bytes.add(int.parse(hex.substring(i, i + 2), radix: 16));
    }
    return Uint8List.fromList(bytes);
  }

  Uint8List _encodeUint32(int value) {
    return Uint8List.fromList([
      (value >> 24) & 0xff,
      (value >> 16) & 0xff,
      (value >> 8) & 0xff,
      value & 0xff,
    ]);
  }

  Uint8List _rsaPrivateKeyToBytes(pc.RSAPrivateKey privateKey) {
    // For simplicity, return the byte representation of the modulus
    return _bigIntToBytes(privateKey.modulus!);
  }

  String _buildEd25519Pem(
      Uint8List privateKey, Uint8List publicKey, String comment) {
    // Build an OpenSSH-format Ed25519 private key PEM
    // For simplicity, return in a format readable by dartssh2
    final buffer = BytesBuilder();

    // AUTH_MAGIC
    buffer.add(utf8.encode('openssh-key-v1'));
    buffer.addByte(0);

    // ciphername: none
    buffer.add(_encodeString('none'));
    // kdfname: none
    buffer.add(_encodeString('none'));
    // kdfoptions: empty
    buffer.add(_encodeUint32(0));
    // number of keys: 1
    buffer.add(_encodeUint32(1));

    // public key blob
    final pubBlob = _buildPublicKeyBlob('ssh-ed25519', publicKey);
    buffer.add(_encodeUint32(pubBlob.length));
    buffer.add(pubBlob);

    // private key section
    final privateSection = BytesBuilder();
    // checkint (random, same twice)
    final checkInt = DateTime.now().millisecondsSinceEpoch & 0xffffffff;
    privateSection.add(_encodeUint32(checkInt));
    privateSection.add(_encodeUint32(checkInt));
    // keytype
    privateSection.add(_encodeString('ssh-ed25519'));
    // public key
    privateSection.add(_encodeUint32(publicKey.length));
    privateSection.add(publicKey);
    // private key (64 bytes: 32 private + 32 public)
    final fullPrivate = Uint8List.fromList([...privateKey, ...publicKey]);
    privateSection.add(_encodeUint32(fullPrivate.length));
    privateSection.add(fullPrivate);
    // comment
    privateSection.add(_encodeString(comment));
    // padding
    var padding = 1;
    while (privateSection.length % 8 != 0) {
      privateSection.addByte(padding++);
    }

    final privBytes = privateSection.toBytes();
    buffer.add(_encodeUint32(privBytes.length));
    buffer.add(privBytes);

    final encoded = base64Encode(buffer.toBytes());
    final lines = <String>[];
    for (var i = 0; i < encoded.length; i += 70) {
      lines.add(encoded.substring(i, i + 70 > encoded.length ? encoded.length : i + 70));
    }

    return '-----BEGIN OPENSSH PRIVATE KEY-----\n${lines.join('\n')}\n-----END OPENSSH PRIVATE KEY-----\n';
  }

  String _buildRsaPem(
      pc.RSAPrivateKey privateKey, pc.RSAPublicKey publicKey, String comment) {
    // Output RSA private key in PKCS#1 format (manual ASN.1 DER encoding)
    final derBytes = _encodeRsaPrivateKeyDer(privateKey, publicKey);

    final encoded = base64Encode(derBytes);
    final lines = <String>[];
    for (var i = 0; i < encoded.length; i += 64) {
      lines.add(encoded.substring(i, i + 64 > encoded.length ? encoded.length : i + 64));
    }

    return '-----BEGIN RSA PRIVATE KEY-----\n${lines.join('\n')}\n-----END RSA PRIVATE KEY-----\n';
  }

  Uint8List _encodeRsaPrivateKeyDer(
      pc.RSAPrivateKey privateKey, pc.RSAPublicKey publicKey) {
    // PKCS#1 RSAPrivateKey structure:
    // RSAPrivateKey ::= SEQUENCE {
    //   version           Version,
    //   modulus           INTEGER,  -- n
    //   publicExponent    INTEGER,  -- e
    //   privateExponent   INTEGER,  -- d
    //   prime1            INTEGER,  -- p
    //   prime2            INTEGER,  -- q
    //   exponent1         INTEGER,  -- d mod (p-1)
    //   exponent2         INTEGER,  -- d mod (q-1)
    //   coefficient       INTEGER,  -- (inverse of q) mod p
    // }
    final integers = [
      BigInt.zero, // version
      privateKey.modulus!,
      publicKey.publicExponent!,
      privateKey.privateExponent!,
      privateKey.p!,
      privateKey.q!,
      privateKey.privateExponent! % (privateKey.p! - BigInt.one),
      privateKey.privateExponent! % (privateKey.q! - BigInt.one),
      privateKey.q!.modInverse(privateKey.p!),
    ];

    final encodedIntegers = integers.map(_encodeAsn1Integer).toList();
    final contentLength = encodedIntegers.fold<int>(0, (sum, e) => sum + e.length);

    final buffer = BytesBuilder();
    // SEQUENCE tag
    buffer.addByte(0x30);
    // Length
    buffer.add(_encodeAsn1Length(contentLength));
    // Contents
    for (final encoded in encodedIntegers) {
      buffer.add(encoded);
    }

    return buffer.toBytes();
  }

  Uint8List _encodeAsn1Integer(BigInt value) {
    final buffer = BytesBuilder();
    // INTEGER tag
    buffer.addByte(0x02);

    var bytes = _bigIntToBytes(value);
    // Add 0x00 for sign bit if the leading bit is 1
    if (bytes.isNotEmpty && (bytes[0] & 0x80) != 0) {
      bytes = Uint8List.fromList([0, ...bytes]);
    }
    // For zero, use a single byte of 0
    if (bytes.isEmpty) {
      bytes = Uint8List.fromList([0]);
    }

    buffer.add(_encodeAsn1Length(bytes.length));
    buffer.add(bytes);

    return buffer.toBytes();
  }

  Uint8List _encodeAsn1Length(int length) {
    if (length < 128) {
      return Uint8List.fromList([length]);
    } else if (length < 256) {
      return Uint8List.fromList([0x81, length]);
    } else if (length < 65536) {
      return Uint8List.fromList([0x82, (length >> 8) & 0xff, length & 0xff]);
    } else {
      return Uint8List.fromList([
        0x83,
        (length >> 16) & 0xff,
        (length >> 8) & 0xff,
        length & 0xff,
      ]);
    }
  }

  Uint8List _encodeString(String value) {
    final bytes = utf8.encode(value);
    final buffer = BytesBuilder();
    buffer.add(_encodeUint32(bytes.length));
    buffer.add(bytes);
    return buffer.toBytes();
  }
}

Future<SshKeyPair> _generateRsaOnIsolate({
  required int bits,
  String? comment,
}) {
  return Isolate.run(
    () => SshKeyService()._generateRsaSync(bits: bits, comment: comment),
  );
}
