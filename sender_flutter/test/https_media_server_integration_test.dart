import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lan_media_cast_sender/services/app_log.dart';
import 'package:lan_media_cast_sender/services/install_certificate.dart';
import 'package:lan_media_cast_sender/services/local_media_server.dart';

void main() {
  late Directory temporaryDirectory;
  late LocalMediaServer server;
  late LocalMediaAsset asset;
  late HttpClient client;
  late File mediaFile;

  setUpAll(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'lan-media-cast-test-',
    );
    mediaFile = File(
      '${temporaryDirectory.path}${Platform.pathSeparator}sample.mp4',
    );
    await AppLog.instance.initialize(
      directory: Directory(
        '${temporaryDirectory.path}${Platform.pathSeparator}logs',
      ),
    );
    await mediaFile.writeAsBytes(List<int>.generate(256, (int index) => index));
    final InstallCertificate certificate = InstallCertificateStore().generate();
    server = LocalMediaServer(certificate: certificate);
    asset = await server.registerFile(mediaFile.path);
    await server.start();
    client = HttpClient();
    client.badCertificateCallback = (_, _, _) => true;
    client.connectionTimeout = const Duration(seconds: 3);
  });

  tearDownAll(() async {
    client.close(force: true);
    await server.stop();
    await AppLog.instance.flush();
    await temporaryDirectory.delete(recursive: true);
  });

  Uri mediaUri() =>
      Uri.parse('https://127.0.0.1:${server.port}/v1/media/${asset.assetId}');

  test('serves authenticated HEAD with a strong ETag', () async {
    final HttpClientRequest request = await client.headUrl(mediaUri());
    request.headers.set(
      HttpHeaders.authorizationHeader,
      'Bearer ${server.bearerToken}',
    );
    final HttpClientResponse response = await request.close();
    expect(response.statusCode, HttpStatus.ok);
    expect(response.contentLength, 256);
    expect(
      response.headers.value(HttpHeaders.etagHeader),
      '"${asset.contentId}"',
    );
    await response.drain<void>();
  });

  test('keeps the previous token valid during endpoint rotation', () async {
    final String previousToken = server.bearerToken;
    final int previousGeneration = server.generation;

    server.renewSession();

    expect(server.generation, previousGeneration + 1);
    expect(server.bearerToken, isNot(previousToken));
    final HttpClientRequest request = await client.headUrl(mediaUri());
    request.headers.set(
      HttpHeaders.authorizationHeader,
      'Bearer $previousToken',
    );
    final HttpClientResponse response = await request.close();
    expect(response.statusCode, HttpStatus.ok);
    await response.drain<void>();
  });

  test('requires authorization and If-Match before GET', () async {
    final HttpClientResponse unauthorized = await (await client.getUrl(
      mediaUri(),
    )).close();
    expect(unauthorized.statusCode, HttpStatus.unauthorized);
    await unauthorized.drain<void>();

    final HttpClientRequest missingPrecondition = await client.getUrl(
      mediaUri(),
    );
    missingPrecondition.headers.set(
      HttpHeaders.authorizationHeader,
      'Bearer ${server.bearerToken}',
    );
    final HttpClientResponse response = await missingPrecondition.close();
    expect(response.statusCode, 428);
    await response.drain<void>();
  });

  test('streams an exact single byte range', () async {
    final HttpClientRequest request = await client.getUrl(mediaUri());
    request.headers
      ..set(HttpHeaders.authorizationHeader, 'Bearer ${server.bearerToken}')
      ..set('If-Match', '"${asset.contentId}"')
      ..set(HttpHeaders.rangeHeader, 'bytes=10-19');
    final HttpClientResponse response = await request.close();
    final List<int> bytes = await response.fold<List<int>>(
      <int>[],
      (List<int> output, List<int> chunk) => output..addAll(chunk),
    );
    expect(response.statusCode, HttpStatus.partialContent);
    expect(
      response.headers.value(HttpHeaders.contentRangeHeader),
      'bytes 10-19/256',
    );
    expect(bytes, List<int>.generate(10, (int index) => index + 10));

    await AppLog.instance.flush();
    final String logContents = await File(
      '${AppLog.instance.directoryPath}${Platform.pathSeparator}sender.log',
    ).readAsString();
    expect(logContents, contains('media_request.completed'));
    expect(logContents, contains('"statusCode":206'));
    expect(logContents, contains('"range":"bytes=10-19"'));
    expect(logContents, contains('"bytesSent":10'));
  });

  test('rejects a source file changed after registration', () async {
    await mediaFile.writeAsBytes(<int>[256], mode: FileMode.append);

    final HttpClientRequest request = await client.headUrl(mediaUri());
    request.headers.set(
      HttpHeaders.authorizationHeader,
      'Bearer ${server.bearerToken}',
    );
    final HttpClientResponse response = await request.close();
    expect(response.statusCode, HttpStatus.preconditionFailed);
    await response.drain<void>();
  });
}
