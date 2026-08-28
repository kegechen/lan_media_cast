import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:asn1lib/asn1lib.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:pointycastle/export.dart';

class InstallCertificate {
  const InstallCertificate({
    required this.certificatePem,
    required this.privateKeyPem,
    required this.certificateDer,
  });

  final String certificatePem;
  final String privateKeyPem;
  final Uint8List certificateDer;

  String get sha256Base64Url => base64Url
      .encode(sha256.convert(certificateDer).bytes)
      .replaceAll('=', '');
}

class InstallCertificateStore {
  InstallCertificateStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  Future<InstallCertificate> loadOrCreate() async {
    final String? certificatePem = await _storage.read(key: _certificateKey);
    final String? privateKeyPem = await _storage.read(key: _privateKeyKey);
    if (certificatePem != null && privateKeyPem != null) {
      return InstallCertificate(
        certificatePem: certificatePem,
        privateKeyPem: privateKeyPem,
        certificateDer: _decodePem(certificatePem),
      );
    }

    final InstallCertificate created = generate();
    await _storage.write(key: _certificateKey, value: created.certificatePem);
    await _storage.write(key: _privateKeyKey, value: created.privateKeyPem);
    return created;
  }

  InstallCertificate generate() {
    final FortunaRandom secureRandom = FortunaRandom();
    final Random random = Random.secure();
    final Uint8List seed = Uint8List.fromList(
      List<int>.generate(32, (_) => random.nextInt(256)),
    );
    secureRandom.seed(KeyParameter(seed));

    final RSAKeyGenerator generator = RSAKeyGenerator()
      ..init(
        ParametersWithRandom<RSAKeyGeneratorParameters>(
          RSAKeyGeneratorParameters(BigInt.from(65537), 2048, 64),
          secureRandom,
        ),
      );
    final AsymmetricKeyPair<PublicKey, PrivateKey> pair = generator
        .generateKeyPair();
    final RSAPublicKey publicKey = pair.publicKey as RSAPublicKey;
    final RSAPrivateKey privateKey = pair.privateKey as RSAPrivateKey;

    final ASN1Sequence algorithm = _sha256WithRsaAlgorithm();
    final ASN1Sequence subject = _commonName('LAN Media Cast Sender');
    final ASN1Sequence publicKeySequence = ASN1Sequence()
      ..add(ASN1Integer(publicKey.modulus!))
      ..add(ASN1Integer(publicKey.exponent!));
    final ASN1Sequence publicKeyInfo = ASN1Sequence()
      ..add(_rsaEncryptionAlgorithm())
      ..add(ASN1BitString(publicKeySequence.encodedBytes));

    final DateTime now = DateTime.now().toUtc().subtract(
      const Duration(days: 1),
    );
    final ASN1Sequence validity = ASN1Sequence()
      ..add(ASN1UtcTime(now))
      ..add(ASN1UtcTime(now.add(const Duration(days: 3650))));
    final Uint8List serialBytes = Uint8List.fromList(
      List<int>.generate(16, (_) => random.nextInt(256)),
    );
    serialBytes[0] &= 0x7f;
    final ASN1Sequence version = ASN1Sequence(tag: 0xa0)
      ..add(ASN1Integer.fromInt(2));
    final ASN1Sequence tbsCertificate = ASN1Sequence()
      ..add(version)
      ..add(ASN1Integer(_bytesToBigInt(serialBytes)))
      ..add(algorithm)
      ..add(subject)
      ..add(validity)
      ..add(subject)
      ..add(publicKeyInfo);

    final RSASigner signer = RSASigner(SHA256Digest(), '0609608648016503040201')
      ..init(true, PrivateKeyParameter<RSAPrivateKey>(privateKey));
    final RSASignature signature = signer.generateSignature(
      tbsCertificate.encodedBytes,
    );
    final ASN1Sequence certificate = ASN1Sequence()
      ..add(tbsCertificate)
      ..add(_sha256WithRsaAlgorithm())
      ..add(ASN1BitString(signature.bytes));
    final ASN1Sequence privateKeySequence = ASN1Sequence()
      ..add(ASN1Integer.fromInt(0))
      ..add(ASN1Integer(privateKey.modulus!))
      ..add(ASN1Integer(publicKey.exponent!))
      ..add(ASN1Integer(privateKey.privateExponent!))
      ..add(ASN1Integer(privateKey.p!))
      ..add(ASN1Integer(privateKey.q!))
      ..add(
        ASN1Integer(privateKey.privateExponent! % (privateKey.p! - BigInt.one)),
      )
      ..add(
        ASN1Integer(privateKey.privateExponent! % (privateKey.q! - BigInt.one)),
      )
      ..add(ASN1Integer(privateKey.q!.modInverse(privateKey.p!)));

    final Uint8List certificateDer = certificate.encodedBytes;
    return InstallCertificate(
      certificatePem: _encodePem('CERTIFICATE', certificateDer),
      privateKeyPem: _encodePem(
        'RSA PRIVATE KEY',
        privateKeySequence.encodedBytes,
      ),
      certificateDer: certificateDer,
    );
  }

  ASN1Sequence _commonName(String commonName) {
    final ASN1Sequence attribute = ASN1Sequence()
      ..add(ASN1ObjectIdentifier.fromComponentString('2.5.4.3'))
      ..add(ASN1UTF8String(commonName));
    final ASN1Set set = ASN1Set()..add(attribute);
    return ASN1Sequence()..add(set);
  }

  ASN1Sequence _sha256WithRsaAlgorithm() => ASN1Sequence()
    ..add(ASN1ObjectIdentifier.fromComponentString('1.2.840.113549.1.1.11'))
    ..add(ASN1Null());

  ASN1Sequence _rsaEncryptionAlgorithm() => ASN1Sequence()
    ..add(ASN1ObjectIdentifier.fromComponentString('1.2.840.113549.1.1.1'))
    ..add(ASN1Null());

  BigInt _bytesToBigInt(Uint8List bytes) {
    BigInt value = BigInt.zero;
    for (final int byte in bytes) {
      value = (value << 8) | BigInt.from(byte);
    }
    return value;
  }

  String _encodePem(String label, Uint8List der) {
    final String body = base64.encode(der);
    final Iterable<String> lines = Iterable<String>.generate(
      (body.length / 64).ceil(),
      (int index) =>
          body.substring(index * 64, min((index + 1) * 64, body.length)),
    );
    return '-----BEGIN $label-----\n${lines.join('\n')}\n-----END $label-----\n';
  }

  Uint8List _decodePem(String pem) {
    final String body = pem
        .split('\n')
        .where(
          (String line) => !line.startsWith('-----') && line.trim().isNotEmpty,
        )
        .join();
    return Uint8List.fromList(base64.decode(body));
  }

  static const String _certificateKey = 'media_https_certificate_v1';
  static const String _privateKeyKey = 'media_https_private_key_v1';
}
