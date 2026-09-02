import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as image;
import 'package:path/path.dart' as path;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'protocol/photo_chunk.dart';
import 'protocol/protocol.dart';
import 'protocol/remote_http_headers.dart';
import 'protocol/remote_media_source.dart';
import 'services/app_log.dart';
import 'services/cast_connection.dart';
import 'services/device_discovery.dart';
import 'services/douyin_browser_resolver.dart';
import 'services/install_certificate.dart';
import 'services/local_media_server.dart';
import 'services/user_facing_error.dart';
import 'services/yt_dlp_resolver.dart';

class PreparedPhoto {
  const PreparedPhoto({
    required this.bytes,
    required this.width,
    required this.height,
    required this.mime,
  });

  final Uint8List bytes;
  final int width;
  final int height;
  final String mime;
}

const int maxPhotoSourceBytes = 64 * 1024 * 1024;

typedef PhotoSourceReader = Future<Uint8List> Function(String path);

Future<Uint8List> _readPhotoSourceFile(String path) => File(path).readAsBytes();

@visibleForTesting
Future<Uint8List> readPhotoSourceBytes(
  PlatformFile selected, {
  PhotoSourceReader readFile = _readPhotoSourceFile,
}) async {
  final String? path = selected.path;
  if (path == null ||
      selected.size <= 0 ||
      selected.size > maxPhotoSourceBytes) {
    throw StateError('${selected.name} 文件为空或超过 64 MiB');
  }
  final Uint8List bytes = await readFile(path);
  if (bytes.isEmpty || bytes.length > maxPhotoSourceBytes) {
    throw StateError('${selected.name} 文件为空或超过 64 MiB');
  }
  return bytes;
}

@visibleForTesting
Future<PreparedPhoto> preparePhotoForUpload(
  Uint8List source,
  String extension,
) async {
  final Map<String, Object> result = await compute(
    _preparePhotoInIsolate,
    <String, Object>{'bytes': source, 'extension': extension.toLowerCase()},
  );
  return PreparedPhoto(
    bytes: result['bytes']! as Uint8List,
    width: result['width']! as int,
    height: result['height']! as int,
    mime: result['mime']! as String,
  );
}

Map<String, Object> _preparePhotoInIsolate(Map<String, Object> request) {
  final Uint8List source = request['bytes']! as Uint8List;
  final image.Image? decoded = image.decodeImage(source);
  if (decoded == null) throw const FormatException('无法解码图片');
  image.Image prepared = image.bakeOrientation(decoded);
  const int maxDimension = 2560;
  if (prepared.width > maxDimension || prepared.height > maxDimension) {
    final bool landscape = prepared.width >= prepared.height;
    prepared = image.copyResize(
      prepared,
      width: landscape ? maxDimension : null,
      height: landscape ? null : maxDimension,
      interpolation: image.Interpolation.average,
    );
  }
  final String extension = request['extension']! as String;
  final bool preserveTransparency =
      (extension == 'png' || extension == 'webp') && prepared.numChannels == 4;
  final Uint8List encoded = Uint8List.fromList(
    preserveTransparency
        ? image.encodePng(prepared, level: 6)
        : image.encodeJpg(prepared, quality: 88),
  );
  return <String, Object>{
    'bytes': encoded,
    'width': prepared.width,
    'height': prepared.height,
    'mime': preserveTransparency ? 'image/png' : 'image/jpeg',
  };
}

class SenderPlaylistItem {
  const SenderPlaylistItem({
    required this.id,
    required this.name,
    required this.source,
    this.localAsset,
    this.localPath,
    this.unavailableReason,
  });

  final String id;
  final String name;
  final Map<String, Object> source;
  final LocalMediaAsset? localAsset;
  final String? localPath;
  final String? unavailableReason;

  bool get isAvailable => unavailableReason == null;
  bool get isLocal => source['kind'] == 'local';
}

final RegExp _networkMediaUrlPattern = RegExp(
  r'''(?:https?|rtsp)://[^\s<>"']+''',
  caseSensitive: false,
);

const String _trailingUrlPunctuation = '.,;:!?，。；：！？、)]}）】》」』';

Uri? parseNetworkMediaInput(String value) {
  final String input = value.trim();
  final Uri? directUri = _validNetworkMediaUri(input);
  if (directUri != null) return directUri;

  for (final RegExpMatch match in _networkMediaUrlPattern.allMatches(input)) {
    String candidate = match.group(0)!;
    while (candidate.isNotEmpty &&
        _trailingUrlPunctuation.contains(candidate[candidate.length - 1])) {
      candidate = candidate.substring(0, candidate.length - 1);
    }
    final Uri? uri = _validNetworkMediaUri(candidate);
    if (uri != null) return uri;
  }
  return null;
}

Uri? _validNetworkMediaUri(String value) {
  final Uri? uri = Uri.tryParse(value);
  if (uri == null ||
      !<String>{'http', 'https', 'rtsp'}.contains(uri.scheme.toLowerCase()) ||
      uri.host.isEmpty) {
    return null;
  }
  return uri;
}

bool isInsecureHttpInput(String value) =>
    parseNetworkMediaInput(value)?.scheme.toLowerCase() == 'http';

bool isInsecureRemoteSource(SenderPlaylistItem item) {
  if (item.isLocal) return false;
  final Object? audioTrack = item.source['audioTrack'];
  return <Object?>[
    item.source['url'],
    item.source['webpageUrl'],
    if (audioTrack is Map) audioTrack['url'],
  ].whereType<String>().any(isInsecureHttpInput);
}

class _PhotoUploadItem {
  _PhotoUploadItem({required this.selected, required this.photoId});

  final PlatformFile selected;
  final String photoId;
  String? transferId;
  int nextChunkIndex = 0;
  bool complete = false;
}

class _PhotoBatchUpload {
  _PhotoBatchUpload({
    required this.receiverId,
    required this.batchId,
    required this.revision,
    required this.items,
  });

  final String receiverId;
  final String batchId;
  int revision;
  final List<_PhotoUploadItem> items;
}

@visibleForTesting
Future<void> uploadPhotoBatchItems<T>({
  required Iterable<T> items,
  required bool Function(T item) isComplete,
  required Future<void> Function(T item) uploadItem,
  required bool Function() canContinue,
  required String Function(Object error) describeError,
  required Future<void> Function(List<T> failedItems) removeFailedItems,
}) async {
  final List<T> failedItems = <T>[];
  final List<String> failures = <String>[];
  for (final T item in List<T>.of(items)) {
    if (isComplete(item)) continue;
    try {
      await uploadItem(item);
    } on Object catch (error) {
      if (!canContinue()) rethrow;
      failedItems.add(item);
      failures.add(describeError(error));
    }
  }
  if (failedItems.isEmpty) return;
  try {
    await removeFailedItems(failedItems);
  } on Object catch (updateError) {
    throw StateError(
      '${failures.join('；')}；同步失败项失败：${updateError.runtimeType}',
    );
  }
  throw StateError(failures.join('；'));
}

@visibleForTesting
Future<int> commitPhotoBatchRemoval<T>({
  required int currentRevision,
  required List<T> failedItems,
  required String Function(T item) itemId,
  required Future<void> Function(int revision, List<String> removedIds)
  sendUpdate,
  required Future<void> Function(int revision, List<T> failedItems) commitLocal,
}) async {
  final int nextRevision = currentRevision + 1;
  final List<String> removedIds = failedItems.map(itemId).toList();
  await sendUpdate(nextRevision, removedIds);
  await commitLocal(nextRevision, failedItems);
  return nextRevision;
}

@visibleForTesting
bool isPhotoWindowResult(
  ProtocolEnvelope event, {
  required String transferId,
  required int windowEnd,
  required bool finalWindow,
}) {
  if (event.payload['transferId'] != transferId) return false;
  if (event.type == 'photo.item.failed') return true;
  if (event.type == 'protocol.error' &&
      event.payload['reason'] == 'internal_error') {
    return true;
  }
  if (finalWindow) return event.type == 'photo.item.complete';
  return event.type == 'photo.chunk.ack' &&
      (event.payload['nextChunkIndex'] as int? ?? 0) >= windowEnd;
}

@visibleForTesting
Future<void> runMediaAction({
  required bool Function() isPhotoMode,
  required Future<void> Function() leavePhotoMode,
  required Future<void> Function() action,
}) async {
  if (isPhotoMode()) {
    await leavePhotoMode();
    if (isPhotoMode()) return;
  }
  await action();
}

/// The receiver dropped the frozen snapshot backing an in-progress log fetch.
class _ReceiverLogSnapshotExpired implements Exception {
  const _ReceiverLogSnapshotExpired();

  // Surfaced to the user if even the restart expires, so it must read as a
  // message rather than as "Instance of '_ReceiverLogSnapshotExpired'".
  @override
  String toString() => '接收端日志在取回过程中被重置，请重试';
}

bool targetsReferToSameReceiver(DeviceTarget left, DeviceTarget right) =>
    left.deviceId == right.deviceId ||
    (left.address == right.address && left.wssPort == right.wssPort);

@visibleForTesting
List<DeviceTarget> mergeDeviceTargets(
  Iterable<DeviceTarget> discovered,
  DeviceTarget? currentTarget,
) {
  final List<DeviceTarget> merged = List<DeviceTarget>.of(discovered);
  if (currentTarget != null) {
    final int existingIndex = merged.indexWhere(
      (DeviceTarget device) =>
          targetsReferToSameReceiver(device, currentTarget),
    );
    if (existingIndex < 0) {
      merged.add(currentTarget);
    } else {
      final DeviceTarget existing = merged[existingIndex];
      final bool existingIsManual = existing.deviceId.startsWith('manual-');
      final bool currentIsManual = currentTarget.deviceId.startsWith('manual-');
      if (existingIsManual || !currentIsManual) {
        merged[existingIndex] = currentTarget;
      }
    }
  }
  merged.sort(
    (DeviceTarget left, DeviceTarget right) =>
        left.deviceName.compareTo(right.deviceName),
  );
  return merged;
}

class AppController extends ChangeNotifier {
  AppController._({
    required this.senderId,
    required this.discovery,
    required this.connection,
    required this.mediaServer,
    required this.webVideoResolver,
    required SharedPreferences preferences,
  }) {
    _preferences = preferences;
    connection
      ..addListener(_onConnectionChanged)
      ..onReady = _onConnectionReady;
  }

  final String senderId;
  final DeviceDiscovery discovery;
  final CastConnection connection;
  final LocalMediaServer mediaServer;
  final WebVideoResolver webVideoResolver;
  late final SharedPreferences _preferences;
  final List<DeviceTarget> devices = <DeviceTarget>[];
  final List<SenderPlaylistItem> playlist = <SenderPlaylistItem>[];

  bool scanning = false;
  bool busy = false;
  String repeatMode = 'playOnce';
  String? statusMessage;
  bool statusIsError = false;
  bool photoMode = false;
  int _playlistRevision = 0;
  String? _announcedSession;
  _PhotoBatchUpload? _photoBatch;
  int _photoUploadEpoch = 0;
  bool _disposed = false;

  static Future<AppController> create({
    WebVideoResolver? webVideoResolver,
  }) async {
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    String? senderId = preferences.getString('sender_id');
    if (senderId == null) {
      senderId = const Uuid().v4();
      await preferences.setString('sender_id', senderId);
    }
    final String senderName = Platform.localHostname.isEmpty
        ? 'LAN Media Cast'
        : Platform.localHostname;
    final InstallCertificate certificate = await InstallCertificateStore()
        .loadOrCreate();
    final CastConnection connection = CastConnection(
      senderId: senderId,
      senderName: senderName,
    );
    final AppController controller = AppController._(
      senderId: senderId,
      discovery: DeviceDiscovery(senderId: senderId, senderName: senderName),
      connection: connection,
      mediaServer: LocalMediaServer(certificate: certificate),
      webVideoResolver: webVideoResolver ?? YtDlpResolver(),
      preferences: preferences,
    );
    await controller._restorePlaylist();
    await controller._restorePhotoBatch();
    unawaited(
      AppLog.instance.info(
        'controller.initialized',
        fields: <String, Object?>{
          'senderId': senderId,
          'senderName': senderName,
          'playlistItems': controller.playlist.length,
        },
      ),
    );
    return controller;
  }

  @visibleForTesting
  static Future<AppController> createForTesting({
    required String senderId,
    required DeviceDiscovery discovery,
    required CastConnection connection,
    required LocalMediaServer mediaServer,
    required WebVideoResolver webVideoResolver,
    required SharedPreferences preferences,
  }) async {
    final AppController controller = AppController._(
      senderId: senderId,
      discovery: discovery,
      connection: connection,
      mediaServer: mediaServer,
      webVideoResolver: webVideoResolver,
      preferences: preferences,
    );
    await controller._restorePlaylist();
    await controller._restorePhotoBatch();
    return controller;
  }

  Future<void> scan() async {
    if (_disposed || scanning) return;
    scanning = true;
    _clearStatus(notify: false);
    _notifyListeners();
    try {
      final List<DeviceTarget> discovered = await discovery.scan();
      if (_disposed) return;
      devices
        ..clear()
        ..addAll(mergeDeviceTargets(discovered, connection.target));
      unawaited(
        AppLog.instance.info(
          'discovery.completed',
          fields: <String, Object?>{'deviceCount': devices.length},
        ),
      );
      if (devices.isEmpty) {
        _setStatus('未发现设备，可检查防火墙后重试或输入投影仪 IP', error: true);
      }
    } on Object catch (error, stackTrace) {
      unawaited(
        AppLog.instance.error(
          'discovery.failed',
          error,
          stackTrace: stackTrace,
        ),
      );
      if (!_disposed) _setStatus('扫描失败：${error.runtimeType}', error: true);
    } finally {
      scanning = false;
      _notifyListeners();
    }
  }

  Future<void> connect(DeviceTarget device) =>
      _runBusy(() => connection.connect(device));

  Future<void> connectManual(String address) async {
    try {
      await connect(discovery.manual(address));
    } on FormatException catch (error) {
      _setStatus(error.message, error: true);
    }
  }

  Future<void> pickMediaFiles() async {
    final FilePickerResult? result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      type: FileType.custom,
      allowedExtensions: <String>[
        'mp4',
        'm4v',
        'mkv',
        'webm',
        'mov',
        'mp3',
        'm4a',
      ],
    );
    if (result == null) return;
    await _runBusy(() async {
      final bool autoplay = playlist.every(
        (SenderPlaylistItem item) => !item.isAvailable,
      );
      for (final PlatformFile selected in result.files) {
        final String? filePath = selected.path;
        if (filePath == null) continue;
        final LocalMediaAsset asset = await mediaServer.registerFile(filePath);
        playlist.add(
          SenderPlaylistItem(
            id: const Uuid().v4(),
            name: asset.name,
            source: asset.protocolSource(senderId),
            localAsset: asset,
            localPath: asset.filePath,
          ),
        );
      }
      _playlistRevision += 1;
      await _savePlaylist();
      await _syncPlaylist(autoplay: autoplay);
    });
  }

  Future<void> fetchReceiverLogs() async {
    await _runBusy(() async {
      if (!connection.isReady) throw StateError('接收端未连接');
      _setStatus('正在获取接收端日志…', error: false);
      final String filePath = await _downloadReceiverLogs();
      await AppLog.instance.info(
        'receiver_logs.saved',
        fields: <String, Object?>{'path': filePath},
      );
      _setStatus('接收端日志已保存：${path.basename(filePath)}', error: false);
    });
  }

  Future<String> _downloadReceiverLogs() async {
    final String? directoryPath = AppLog.instance.directoryPath;
    if (directoryPath == null) throw StateError('日志目录尚未初始化');
    String contents;
    try {
      contents = await _readReceiverLogSnapshot();
    } on _ReceiverLogSnapshotExpired {
      // The receiver released the frozen image mid-fetch. Protocol v1 §4.1 says
      // to restart at offset 0 rather than splice across two images.
      contents = await _readReceiverLogSnapshot();
    }

    final Directory directory = Directory(directoryPath);
    await directory.create(recursive: true);
    final DateTime now = DateTime.now();
    final String stamp =
        '${now.year.toString().padLeft(4, '0')}'
        '${now.month.toString().padLeft(2, '0')}'
        '${now.day.toString().padLeft(2, '0')}'
        '-${now.hour.toString().padLeft(2, '0')}'
        '${now.minute.toString().padLeft(2, '0')}'
        '${now.second.toString().padLeft(2, '0')}';
    // The stamp only resolves to the second, so two fetches within the same
    // second would otherwise truncate each other.
    File output = File(path.join(directoryPath, 'receiver-$stamp.log'));
    for (int copy = 1; await output.exists(); copy += 1) {
      output = File(path.join(directoryPath, 'receiver-$stamp-$copy.log'));
    }
    await output.writeAsString(contents, flush: true);
    await _pruneReceiverLogs(directory);
    return output.path;
  }

  /// Drains one frozen receiver-side snapshot, starting at offset 0.
  ///
  /// Throws [_ReceiverLogSnapshotExpired] if the receiver reports that the
  /// snapshot backing this retrieval is gone, so the caller can restart cleanly
  /// instead of stitching together two different images of the buffer.
  Future<String> _readReceiverLogSnapshot() async {
    final StringBuffer contents = StringBuffer();
    int offset = 0;
    int? totalBytes;
    bool reachedEnd = false;
    const int maxChunks = 32;
    for (int index = 0; index < maxChunks; index += 1) {
      final Map<String, dynamic> response;
      try {
        response = await connection.sendCommand(
          'diagnostics.logs.get',
          <String, dynamic>{
            'offset': offset,
            'maxBytes': maxReceiverLogChunkBytes,
          },
        );
      } on ReceiverCommandRejected catch (rejection) {
        if (offset > 0 && rejection.code == 'invalid_state') {
          throw const _ReceiverLogSnapshotExpired();
        }
        rethrow;
      }
      final ReceiverLogChunk chunk = ReceiverLogChunk.fromPayload(response);
      if (chunk.offset != offset) {
        throw const FormatException('接收端日志响应偏移量不连续');
      }
      // A receiver that re-read a live buffer per chunk would report a moving
      // total; holding it fixed is what makes the offsets comparable at all.
      totalBytes ??= chunk.totalBytes;
      if (chunk.totalBytes != totalBytes) {
        throw const FormatException('接收端日志在取回过程中发生变化');
      }
      final int chunkBytes = utf8.encode(chunk.data).length;
      if (chunkBytes > maxReceiverLogChunkBytes ||
          chunk.nextOffset != offset + chunkBytes) {
        throw const FormatException('接收端日志响应长度无效');
      }
      contents.write(chunk.data);
      if (chunk.eof) {
        reachedEnd = true;
        break;
      }
      if (chunk.nextOffset <= offset) {
        throw const FormatException('接收端日志响应未向前推进');
      }
      offset = chunk.nextOffset;
    }
    if (!reachedEnd) throw StateError('接收端日志超过单次获取大小限制');
    return contents.toString();
  }

  /// Keeps receiver log retention bounded like the sender's own rolling log:
  /// [AppLog] only rotates `sender.log`, so nothing else would ever reclaim
  /// these files and each fetch adds up to 256 KiB.
  Future<void> _pruneReceiverLogs(Directory directory) async {
    try {
      final List<File> logs = <File>[];
      await for (final FileSystemEntity entity in directory.list()) {
        final String name = path.basename(entity.path);
        if (entity is File &&
            name.startsWith('receiver-') &&
            name.endsWith('.log')) {
          logs.add(entity);
        }
      }
      if (logs.length <= _retainedReceiverLogs) return;
      // Sort by mtime rather than by name: same-second fetches get a `-1`
      // suffix, and '-' sorts before '.', so name order would put
      // `receiver-<stamp>-1.log` *before* the older `receiver-<stamp>.log`.
      final List<(File, DateTime)> dated = <(File, DateTime)>[
        for (final File log in logs) (log, (await log.stat()).modified),
      ]..sort(
        ((File, DateTime) left, (File, DateTime) right) =>
            left.$2.compareTo(right.$2),
      );
      for (final (File stale, _) in dated.take(
        dated.length - _retainedReceiverLogs,
      )) {
        await stale.delete();
      }
    } on Object catch (error, stackTrace) {
      // Pruning is housekeeping; a failure must not fail the fetch itself.
      unawaited(
        AppLog.instance.error(
          'receiver_logs.prune_failed',
          error,
          stackTrace: stackTrace,
        ),
      );
    }
  }

  Future<void> pickPhotos() async {
    final FilePickerResult? result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      type: FileType.custom,
      allowedExtensions: <String>['jpg', 'jpeg', 'png', 'webp'],
    );
    if (result == null) return;
    final List<PlatformFile> selected = result.files
        .where((PlatformFile file) => file.path != null)
        .take(9)
        .toList();
    if (selected.isEmpty) return;
    await _runBusy(() async {
      if (!connection.isReady) throw StateError('请先连接投影仪');
      final int epoch = ++_photoUploadEpoch;
      await connection.sendCommand('mode.set', <String, Object>{
        'mode': 'photo',
      });
      if (epoch != _photoUploadEpoch) return;
      photoMode = true;
      _notifyListeners();
      final _PhotoBatchUpload batch = _PhotoBatchUpload(
        receiverId: connection.target!.deviceId,
        batchId: const Uuid().v4(),
        revision: 1,
        items: selected
            .map(
              (PlatformFile file) =>
                  _PhotoUploadItem(selected: file, photoId: const Uuid().v4()),
            )
            .toList(),
      );
      _photoBatch = batch;
      await _savePhotoBatch();
      if (epoch != _photoUploadEpoch) return;
      await connection.sendCommand('photo.batch.start', <String, Object>{
        'batchId': batch.batchId,
        'revision': batch.revision,
        'count': batch.items.length,
        'photoIds': batch.items
            .map((_PhotoUploadItem item) => item.photoId)
            .toList(),
      });
      if (epoch != _photoUploadEpoch) return;
      await _uploadPhotos(
        batch.items,
        batch: batch,
        sendMeta: true,
        epoch: epoch,
      );
      if (epoch == _photoUploadEpoch) _setStatus('照片已发送', error: false);
    });
  }

  Future<void> returnToMedia() async {
    if (!connection.isReady) {
      _setStatus('连接恢复后才能执行该操作', error: true);
      return;
    }
    try {
      await connection.sendCommand('mode.set', <String, Object>{
        'mode': 'media',
      });
      photoMode = false;
      _photoBatch = null;
      await _preferences.remove(_photoBatchKey);
      _clearStatus();
    } on Object catch (error) {
      _setStatus(userFacingError(error), error: true);
    }
  }

  Future<void> _uploadPhoto(
    _PhotoUploadItem item, {
    required _PhotoBatchUpload batch,
    required bool sendMeta,
    required int epoch,
  }) async {
    if (epoch != _photoUploadEpoch || item.complete) return;
    final PlatformFile selected = item.selected;
    final Uint8List sourceBytes = await readPhotoSourceBytes(selected);
    final String extension = selected.extension?.toLowerCase() ?? 'jpg';
    final PreparedPhoto prepared = await preparePhotoForUpload(
      sourceBytes,
      extension,
    );
    if (epoch != _photoUploadEpoch) return;
    final Uint8List bytes = prepared.bytes;
    if (bytes.isEmpty || bytes.length > maxPhotoSourceBytes) {
      throw StateError('${selected.name} 处理后为空或超过 64 MiB');
    }
    const int chunkSize = 64 * 1024;
    final int chunkCount = (bytes.length / chunkSize).ceil();
    final String transferId = sendMeta || item.transferId == null
        ? const Uuid().v4()
        : item.transferId!;
    item.transferId = transferId;
    await _savePhotoBatch();
    final String digest = base64Url
        .encode(sha256.convert(bytes).bytes)
        .replaceAll('=', '');
    if (sendMeta) {
      await connection.sendCommand('photo.item.meta', <String, Object>{
        'batchId': batch.batchId,
        'revision': batch.revision,
        'photoId': item.photoId,
        'transferId': transferId,
        'name': selected.name,
        'mime': prepared.mime,
        'width': prepared.width,
        'height': prepared.height,
        'size': bytes.length,
        'sha256': digest,
        'chunkCount': chunkCount,
      });
      item.nextChunkIndex = 0;
    }
    int nextChunk = item.nextChunkIndex;
    while (nextChunk < chunkCount) {
      if (epoch != _photoUploadEpoch) return;
      final int windowEnd = min(chunkCount, nextChunk + 32);
      final bool finalWindow = windowEnd == chunkCount;
      final Future<ProtocolEnvelope> progress = connection.waitForEvent(
        (ProtocolEnvelope event) => isPhotoWindowResult(
          event,
          transferId: transferId,
          windowEnd: windowEnd,
          finalWindow: finalWindow,
        ),
        timeout: finalWindow
            ? const Duration(seconds: 60)
            : const Duration(seconds: 5),
      );
      while (nextChunk < windowEnd) {
        final int start = nextChunk * chunkSize;
        final int end = min(bytes.length, start + chunkSize);
        connection.sendBinary(
          PhotoChunkFrame(
            transferId: transferId,
            chunkIndex: nextChunk,
            last: nextChunk == chunkCount - 1,
            payload: Uint8List.sublistView(bytes, start, end),
          ).encode(),
        );
        nextChunk += 1;
      }
      final ProtocolEnvelope result = await progress;
      if (result.type == 'photo.item.failed' ||
          result.type == 'protocol.error') {
        final String errorCode =
            result.payload['errorCode'] as String? ??
            result.payload['code'] as String? ??
            'write_failed';
        item
          ..transferId = null
          ..nextChunkIndex = 0;
        await _savePhotoBatch();
        throw StateError(_photoTransferError(errorCode, selected.name));
      }
      if (epoch != _photoUploadEpoch) return;
      item.nextChunkIndex = windowEnd;
      await _savePhotoBatch();
    }
    item.complete = true;
    await _savePhotoBatch();
  }

  Future<void> _uploadPhotos(
    Iterable<_PhotoUploadItem> items, {
    required _PhotoBatchUpload batch,
    required bool sendMeta,
    required int epoch,
  }) async {
    await uploadPhotoBatchItems<_PhotoUploadItem>(
      items: items,
      isComplete: (_PhotoUploadItem item) => item.complete,
      uploadItem: (_PhotoUploadItem item) => _uploadPhoto(
        item,
        batch: batch,
        sendMeta: sendMeta || item.transferId == null,
        epoch: epoch,
      ),
      canContinue: () =>
          !_disposed && connection.isReady && epoch == _photoUploadEpoch,
      describeError: userFacingError,
      removeFailedItems: (List<_PhotoUploadItem> failedItems) async {
        await commitPhotoBatchRemoval<_PhotoUploadItem>(
          currentRevision: batch.revision,
          failedItems: failedItems,
          itemId: (_PhotoUploadItem item) => item.photoId,
          sendUpdate: (int revision, List<String> removedIds) =>
              connection.sendCommand('photo.batch.update', <String, Object>{
                'batchId': batch.batchId,
                'revision': revision,
                'removedPhotoIds': removedIds,
              }),
          commitLocal:
              (int revision, List<_PhotoUploadItem> committedFailures) async {
                batch.revision = revision;
                final Set<String> failedIds = committedFailures
                    .map((_PhotoUploadItem item) => item.photoId)
                    .toSet();
                batch.items.removeWhere(
                  (_PhotoUploadItem item) => failedIds.contains(item.photoId),
                );
                await _savePhotoBatch();
              },
        );
      },
    );
  }

  String _photoTransferError(String code, String name) => switch (code) {
    'storage_low' => '$name 发送失败：接收端存储空间不足',
    'transfer_corrupt' => '$name 发送失败：文件校验不一致',
    'invalid_message' => '$name 发送失败：照片分块协议无效',
    _ => '$name 发送失败：接收端写入失败（$code）',
  };

  Future<void> addUrl(String value, {YtDlpBrowser? cookieBrowser}) async {
    final Uri? uri = parseNetworkMediaInput(value);
    if (uri == null) {
      _setStatus('请输入有效的 HTTP、HTTPS 或 RTSP 地址', error: true);
      return;
    }
    if (utf8.encode(uri.toString()).length > 4096) {
      _setStatus('网络地址不能超过 4096 字节', error: true);
      return;
    }
    await _runBusy(() async {
      if (webVideoResolver.requiresExtraction(uri)) {
        _setStatus(
          Platform.isWindows && isDouyinPageUri(uri)
              ? '正在打开 Edge 解析抖音视频；如出现安全验证，请在 Edge 中完成'
              : '正在解析网页视频…',
          error: false,
        );
      }
      final ResolvedWebVideo resolved = await webVideoResolver.resolve(
        uri,
        cookieBrowser: cookieBrowser,
      );
      final bool autoplay = playlist.every(
        (SenderPlaylistItem item) => !item.isAvailable,
      );
      playlist.add(
        SenderPlaylistItem(
          id: const Uuid().v4(),
          name: resolved.name,
          source: _remoteSource(resolved),
        ),
      );
      _playlistRevision += 1;
      await _savePlaylist();
      _clearStatus();
      await _syncPlaylist(autoplay: autoplay);
    });
  }

  Future<void> removeItem(int index) async {
    if (index < 0 || index >= playlist.length) return;
    playlist.removeAt(index);
    mediaServer.retainAssets(
      playlist
          .map((SenderPlaylistItem item) => item.localAsset?.assetId)
          .whereType<String>()
          .toSet(),
    );
    _playlistRevision += 1;
    await _savePlaylist();
    _notifyListeners();
    await _syncPlaylist();
  }

  Future<void> reorder(int oldIndex, int newIndex) async {
    if (newIndex > oldIndex) newIndex -= 1;
    final SenderPlaylistItem item = playlist.removeAt(oldIndex);
    playlist.insert(newIndex, item);
    _playlistRevision += 1;
    await _savePlaylist();
    _notifyListeners();
    await _syncPlaylist();
  }

  Future<void> selectItem(SenderPlaylistItem item) async {
    unawaited(
      AppLog.instance.info(
        'playlist.item_selected',
        fields: <String, Object?>{
          'itemId': item.id,
          'name': item.name,
          'kind': item.isLocal ? 'local' : 'url',
          if (item.localPath != null) 'path': item.localPath,
        },
      ),
    );
    if (_resolvedWebSourceExpired(item)) {
      await _runBusy(() async {
        final Uri webpageUri = Uri.parse(item.source['webpageUrl']! as String);
        _setStatus('正在刷新网页视频地址…', error: false);
        final ResolvedWebVideo refreshed = await webVideoResolver.resolve(
          webpageUri,
          cookieBrowser: YtDlpBrowser.fromName(
            item.source['cookieBrowser'] as String?,
          ),
        );
        item.source
          ..clear()
          ..addAll(_remoteSource(refreshed));
        _playlistRevision += 1;
        await _savePlaylist();
        _clearStatus();
        await _syncPlaylist();
        await _sendMediaCommand('player.select', <String, Object>{
          'itemId': item.id,
          'autoplay': true,
        });
      });
      return;
    }
    await _sendMediaCommand('player.select', <String, Object>{
      'itemId': item.id,
      'autoplay': true,
    });
  }

  Future<void> play() => _sendMediaCommand('player.play');
  Future<void> pause() => _send('player.pause');
  Future<void> stop() => _send('player.stop');
  Future<void> next() => _sendMediaCommand('player.next');
  Future<void> previous() => _sendMediaCommand('player.previous');
  Future<void> seek(int positionMs) =>
      _send('player.seek', <String, Object>{'positionMs': positionMs});

  Future<void> setRepeatMode(String mode) async {
    if (!<String>{'repeatOne', 'repeatAll', 'playOnce'}.contains(mode)) return;
    repeatMode = mode;
    await _savePlaylist();
    _notifyListeners();
    await _send('player.repeat', <String, Object>{'mode': mode});
  }

  Future<void> _onConnectionReady() async {
    if (_disposed) return;
    final String? activeSession = connection.sessionId;
    if (activeSession == null || _announcedSession == activeSession) return;
    busy = true;
    _notifyListeners();
    try {
      if (mediaServer.isRunning) {
        mediaServer.renewSession();
      } else {
        await mediaServer.start();
      }
      if (_disposed) return;
      await connection.sendCommand('media.endpoint.announce', <String, Object>{
        'scheme': 'https',
        'port': mediaServer.port,
        'generation': mediaServer.generation,
        'certificateSha256': mediaServer.certificateSha256,
        'bearerToken': mediaServer.bearerToken,
      });
      unawaited(
        AppLog.instance.info(
          'media_endpoint.announced',
          fields: <String, Object?>{
            'port': mediaServer.port,
            'generation': mediaServer.generation,
            'receiverAddress': connection.target?.address,
          },
        ),
      );
      _announcedSession = activeSession;
      final int remoteRevision = connection.remotePlaylistRevision ?? 0;
      if (playlist.isNotEmpty) {
        _playlistRevision = nextPlaylistRevision(
          _playlistRevision,
          remoteRevision,
        );
        await _savePlaylist();
        await _syncPlaylist();
      } else {
        _playlistRevision = max(_playlistRevision, remoteRevision);
      }
      if (photoMode &&
          _photoBatch != null &&
          _photoBatch!.receiverId == connection.target?.deviceId) {
        await _resumePhotoBatch(_photoBatch!);
      }
    } on Object catch (error, stackTrace) {
      unawaited(
        AppLog.instance.error(
          'connection.ready_setup_failed',
          error,
          stackTrace: stackTrace,
        ),
      );
      _setStatus(userFacingError(error), error: true);
    } finally {
      busy = false;
      _notifyListeners();
    }
  }

  Future<void> _resumePhotoBatch(_PhotoBatchUpload batch) async {
    if (_disposed) return;
    final int epoch = ++_photoUploadEpoch;
    await connection.sendCommand('mode.set', <String, Object>{'mode': 'photo'});
    if (epoch != _photoUploadEpoch) return;
    final Map<String, dynamic> state = await connection
        .sendCommand('photo.batch.resume.query', <String, Object>{
          'batchId': batch.batchId,
          'revision': batch.revision,
          'transferIds': batch.items
              .map((_PhotoUploadItem item) => item.transferId)
              .whereType<String>()
              .toList(),
        });
    if (epoch != _photoUploadEpoch) return;
    final String batchStatus = state['batchStatus'] as String? ?? 'notFound';
    if (batchStatus == 'complete') {
      for (final _PhotoUploadItem item in batch.items) {
        item.complete = true;
      }
      await _savePhotoBatch();
      return;
    }
    if (batchStatus == 'notFound') {
      await connection.sendCommand('photo.batch.start', <String, Object>{
        'batchId': batch.batchId,
        'revision': batch.revision,
        'count': batch.items.length,
        'photoIds': batch.items
            .map((_PhotoUploadItem item) => item.photoId)
            .toList(),
      });
      if (epoch != _photoUploadEpoch) return;
      for (final _PhotoUploadItem item in batch.items) {
        item
          ..transferId = null
          ..nextChunkIndex = 0
          ..complete = false;
      }
    } else {
      final int? remoteRevision = state['revision'] as int?;
      if (remoteRevision == null || remoteRevision < 0) {
        throw StateError('照片恢复 revision 无效');
      }
      batch.revision = remoteRevision;
      final Object? rawItems = state['items'];
      if (rawItems is! List) throw StateError('照片恢复状态无效');
      final Map<String, Map<String, dynamic>> remoteItems =
          <String, Map<String, dynamic>>{
            for (final Object? raw in rawItems)
              if (raw is Map<String, dynamic>) raw['photoId'] as String: raw,
          };
      for (final _PhotoUploadItem item in batch.items) {
        final Map<String, dynamic>? remote = remoteItems[item.photoId];
        final String status = remote?['status'] as String? ?? 'awaitingMeta';
        item.complete = status == 'complete' || status == 'removed';
        item.transferId = remote?['transferId'] as String?;
        item.nextChunkIndex = remote?['nextChunkIndex'] as int? ?? 0;
        if (status == 'expired' || status == 'awaitingMeta') {
          item.transferId = null;
          item.nextChunkIndex = 0;
        }
      }
    }
    await _savePhotoBatch();
    if (epoch != _photoUploadEpoch) return;
    await _uploadPhotos(
      batch.items,
      batch: batch,
      sendMeta: false,
      epoch: epoch,
    );
    if (epoch == _photoUploadEpoch) _setStatus('照片传输已恢复', error: false);
  }

  Future<void> _savePhotoBatch() async {
    final _PhotoBatchUpload? batch = _photoBatch;
    if (batch == null) {
      await _preferences.remove(_photoBatchKey);
      return;
    }
    final String encoded = jsonEncode(<String, Object>{
      'receiverId': batch.receiverId,
      'batchId': batch.batchId,
      'revision': batch.revision,
      'items': batch.items
          .map(
            (_PhotoUploadItem item) => <String, Object?>{
              'path': item.selected.path,
              'name': item.selected.name,
              'size': item.selected.size,
              'photoId': item.photoId,
              'transferId': item.transferId,
              'nextChunkIndex': item.nextChunkIndex,
              'complete': item.complete,
            },
          )
          .toList(),
    });
    await _preferences.setString(_photoBatchKey, encoded);
  }

  Future<void> _savePlaylist() async {
    final String encoded = jsonEncode(<String, Object>{
      'revision': _playlistRevision,
      'repeatMode': repeatMode,
      'items': playlist
          .map(
            (SenderPlaylistItem item) => <String, Object?>{
              'id': item.id,
              'name': item.name,
              'kind': item.isLocal ? 'local' : 'url',
              if (item.isLocal)
                'path': item.localAsset?.filePath ?? item.localPath,
              if (!item.isLocal) 'url': item.source['url'],
              if (!item.isLocal) 'formatHint': item.source['formatHint'],
              if (!item.isLocal) 'cacheKey': item.source['cacheKey'],
              if (!item.isLocal) 'audioTrack': item.source['audioTrack'],
              if (!item.isLocal) 'webpageUrl': item.source['webpageUrl'],
              if (!item.isLocal) 'resolvedAt': item.source['resolvedAt'],
              if (!item.isLocal) 'cookieBrowser': item.source['cookieBrowser'],
              if (!item.isLocal) 'httpHeaders': item.source['httpHeaders'],
            },
          )
          .toList(),
    });
    await _preferences.setString(_playlistKey, encoded);
  }

  Future<void> _restorePlaylist() async {
    final String? encoded = _preferences.getString(_playlistKey);
    if (encoded == null) return;
    try {
      final Map<String, dynamic> value =
          jsonDecode(encoded) as Map<String, dynamic>;
      final String restoredRepeat =
          value['repeatMode'] as String? ?? 'playOnce';
      if (<String>{
        'repeatOne',
        'repeatAll',
        'playOnce',
      }.contains(restoredRepeat)) {
        repeatMode = restoredRepeat;
      }
      _playlistRevision = (value['revision'] as int? ?? 0).clamp(0, 1 << 52);
      final List<dynamic> rawItems = value['items'] as List<dynamic>;
      if (rawItems.length > maxPlaylistItems) {
        throw StateError('Persisted playlist is too large');
      }
      for (final dynamic raw in rawItems) {
        final Map<String, dynamic> item = raw as Map<String, dynamic>;
        final String id = item['id'] as String;
        final String name = item['name'] as String;
        if (item['kind'] == 'local') {
          final String path = item['path'] as String;
          try {
            final LocalMediaAsset asset = await mediaServer.registerFile(path);
            playlist.add(
              SenderPlaylistItem(
                id: id,
                name: name,
                source: asset.protocolSource(senderId),
                localAsset: asset,
                localPath: path,
              ),
            );
          } on Object catch (error, stackTrace) {
            unawaited(
              AppLog.instance.error(
                'playlist.local_file_restore_failed',
                error,
                stackTrace: stackTrace,
                fields: <String, Object?>{'path': path, 'name': name},
              ),
            );
            playlist.add(
              SenderPlaylistItem(
                id: id,
                name: name,
                source: <String, Object>{'kind': 'local', 'name': name},
                localPath: path,
                unavailableReason: '文件不可用',
              ),
            );
          }
          continue;
        }
        final Uri uri = Uri.parse(item['url'] as String);
        if (!<String>{'http', 'https', 'rtsp'}.contains(uri.scheme) ||
            uri.host.isEmpty) {
          throw StateError('Persisted URL is invalid');
        }
        final String? formatHint = item['formatHint'] as String?;
        final String? cacheKey = _validatedCacheKey(item['cacheKey']);
        final Map<String, Object>? audioTrack = _validatedAudioTrack(
          item['audioTrack'],
        );
        if (audioTrack != null && formatHint != null) {
          throw StateError('Persisted split media format is invalid');
        }
        final Map<String, String> httpHeaders = validateRemoteHttpHeaders(
          item['httpHeaders'],
        );
        final String? rawWebpageUrl = item['webpageUrl'] as String?;
        final int? resolvedAt = item['resolvedAt'] as int?;
        final String? rawCookieBrowser = item['cookieBrowser'] as String?;
        final YtDlpBrowser? cookieBrowser = YtDlpBrowser.fromName(
          rawCookieBrowser,
        );
        if (rawCookieBrowser != null && cookieBrowser == null) {
          throw StateError('Persisted browser selection is invalid');
        }
        Uri? webpageUri;
        if (rawWebpageUrl != null) {
          webpageUri = Uri.parse(rawWebpageUrl);
          if (!<String>{'http', 'https'}.contains(webpageUri.scheme) ||
              webpageUri.host.isEmpty ||
              utf8.encode(rawWebpageUrl).length > 4096 ||
              resolvedAt == null ||
              resolvedAt <= 0) {
            throw StateError('Persisted webpage URL is invalid');
          }
        } else if (resolvedAt != null) {
          throw StateError('Persisted resolvedAt is invalid');
        }
        playlist.add(
          SenderPlaylistItem(
            id: id,
            name: name,
            source: <String, Object>{
              'kind': 'url',
              'url': uri.toString(),
              'name': name,
              'formatHint': ?formatHint,
              'cacheKey': ?cacheKey,
              'audioTrack': ?audioTrack,
              if (webpageUri != null) 'webpageUrl': webpageUri.toString(),
              'resolvedAt': ?resolvedAt,
              if (cookieBrowser != null) 'cookieBrowser': cookieBrowser.name,
              if (httpHeaders.isNotEmpty) 'httpHeaders': httpHeaders,
            },
          ),
        );
      }
      unawaited(
        AppLog.instance.info(
          'playlist.restored',
          fields: <String, Object?>{
            'revision': _playlistRevision,
            'itemCount': playlist.length,
            'availableCount': playlist
                .where((SenderPlaylistItem item) => item.isAvailable)
                .length,
          },
        ),
      );
    } on Object catch (error, stackTrace) {
      unawaited(
        AppLog.instance.error(
          'playlist.restore_failed',
          error,
          stackTrace: stackTrace,
        ),
      );
      playlist.clear();
      _playlistRevision = 0;
      repeatMode = 'playOnce';
      await _preferences.remove(_playlistKey);
    }
  }

  Future<void> _restorePhotoBatch() async {
    final String? encoded = _preferences.getString(_photoBatchKey);
    if (encoded == null) return;
    try {
      final Map<String, dynamic> value =
          jsonDecode(encoded) as Map<String, dynamic>;
      final List<dynamic> rawItems = value['items'] as List<dynamic>;
      final List<_PhotoUploadItem> items = <_PhotoUploadItem>[];
      for (final dynamic raw in rawItems) {
        final Map<String, dynamic> itemValue = raw as Map<String, dynamic>;
        final String path = itemValue['path'] as String;
        final File file = File(path);
        if (!file.existsSync()) {
          throw StateError('Photo source is no longer available');
        }
        final _PhotoUploadItem item =
            _PhotoUploadItem(
                selected: PlatformFile(
                  path: path,
                  name: itemValue['name'] as String,
                  size: itemValue['size'] as int,
                ),
                photoId: itemValue['photoId'] as String,
              )
              ..transferId = itemValue['transferId'] as String?
              ..nextChunkIndex = itemValue['nextChunkIndex'] as int? ?? 0
              ..complete = itemValue['complete'] as bool? ?? false;
        items.add(item);
      }
      if (items.isEmpty || items.length > 9) {
        throw StateError('Invalid photo batch');
      }
      _photoBatch = _PhotoBatchUpload(
        receiverId: value['receiverId'] as String,
        batchId: value['batchId'] as String,
        revision: value['revision'] as int,
        items: items,
      );
      photoMode = true;
    } on Object {
      _photoBatch = null;
      photoMode = false;
      await _preferences.remove(_photoBatchKey);
    }
  }

  Future<void> _syncPlaylist({bool autoplay = false}) async {
    _notifyListeners();
    if (!connection.isReady || _announcedSession != connection.sessionId) {
      return;
    }
    final List<SenderPlaylistItem> availableItems = playlist
        .where((SenderPlaylistItem item) => item.isAvailable)
        .toList();
    final String? remoteItemId = connection.playerState?.itemId;
    final String? activeItem =
        availableItems.any((SenderPlaylistItem item) => item.id == remoteItemId)
        ? remoteItemId
        : availableItems.firstOrNull?.id;
    unawaited(
      AppLog.instance.info(
        'playlist.sync_started',
        fields: <String, Object?>{
          'revision': _playlistRevision,
          'itemCount': availableItems.length,
          'activeItemId': activeItem,
          'autoplay': autoplay,
        },
      ),
    );
    await _send('playlist.replace', <String, Object?>{
      'revision': _playlistRevision,
      'repeatMode': repeatMode,
      'activeItemId': activeItem,
      'items': availableItems
          .map(
            (SenderPlaylistItem item) => <String, Object>{
              'id': item.id,
              'source': protocolSourceForItem(item),
            },
          )
          .toList(),
    });
    if (autoplay && availableItems.isNotEmpty) {
      await selectItem(availableItems.first);
    }
  }

  Future<void> _sendMediaCommand(
    String type, [
    Map<String, dynamic> payload = const <String, dynamic>{},
  ]) => runMediaAction(
    isPhotoMode: () => photoMode,
    leavePhotoMode: returnToMedia,
    action: () => _send(type, payload),
  );

  Future<void> _send(
    String type, [
    Map<String, dynamic> payload = const <String, dynamic>{},
  ]) async {
    if (!connection.isReady) {
      _setStatus('连接恢复后才能执行该操作', error: true);
      return;
    }
    try {
      await connection.sendCommand(type, payload);
      _clearStatus();
    } on Object catch (error, stackTrace) {
      unawaited(
        AppLog.instance.error(
          'control.command_failed_in_controller',
          error,
          stackTrace: stackTrace,
          fields: <String, Object?>{'type': type},
        ),
      );
      _setStatus(userFacingError(error), error: true);
    }
  }

  Future<void> _runBusy(Future<void> Function() action) async {
    if (_disposed || busy) return;
    busy = true;
    _notifyListeners();
    try {
      await action();
    } on Object catch (error, stackTrace) {
      unawaited(
        AppLog.instance.error(
          'controller.action_failed',
          error,
          stackTrace: stackTrace,
        ),
      );
      _setStatus(userFacingError(error), error: true);
    } finally {
      busy = false;
      _notifyListeners();
    }
  }

  void _onConnectionChanged() {
    if (_disposed) return;
    if (connection.errorMessage != null) {
      statusMessage = connection.errorMessage;
      statusIsError = true;
    } else if (connection.phase == ConnectionPhase.reconnecting) {
      if (!statusIsError) {
        statusMessage = '连接已断开，正在重连；投影仪会继续播放已有缓存';
        statusIsError = false;
      }
    } else if (connection.phase == ConnectionPhase.ready) {
      if (!statusIsError) {
        _clearStatus(notify: false);
      }
      final List<DeviceTarget> merged = mergeDeviceTargets(
        devices,
        connection.target,
      );
      devices
        ..clear()
        ..addAll(merged);
    }
    _notifyListeners();
  }

  void _setStatus(String message, {required bool error}) {
    if (_disposed) return;
    statusMessage = message;
    statusIsError = error;
    _notifyListeners();
  }

  void dismissStatus() {
    _clearStatus();
  }

  void _clearStatus({bool notify = true}) {
    if (_disposed) return;
    statusMessage = null;
    statusIsError = false;
    if (notify) _notifyListeners();
  }

  void _notifyListeners() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _photoUploadEpoch += 1;
    webVideoResolver.cancel();
    connection
      ..removeListener(_onConnectionChanged)
      ..onReady = null
      ..dispose();
    unawaited(mediaServer.stop());
    super.dispose();
  }

  static const int _retainedReceiverLogs = 3;
  static const String _photoBatchKey = 'active_photo_batch_v1';
  static const String _playlistKey = 'playlist_v1';
  static const Duration _resolvedWebSourceMaxAge = Duration(minutes: 10);
}

Map<String, Object> _remoteSource(ResolvedWebVideo resolved) {
  final Uri? webpageUrl = resolved.webpageUrl;
  final String? primaryCacheKey = webpageUrl == null
      ? null
      : webTrackCacheKey(webpageUrl, 'primary', resolved.primaryTrack);
  final Map<String, Object> source = <String, Object>{
    'kind': 'url',
    'name': resolved.name,
    ..._remoteTrackSource(resolved.primaryTrack, cacheKey: primaryCacheKey),
    if (resolved.webpageUrl != null)
      'webpageUrl': resolved.webpageUrl.toString(),
    if (resolved.resolvedAt != null) 'resolvedAt': resolved.resolvedAt!,
    'cookieBrowser': ?resolved.cookieBrowser?.name,
  };
  final ResolvedWebVideoTrack? audioTrack = resolved.audioTrack;
  if (audioTrack != null) {
    source['audioTrack'] = _remoteTrackSource(
      audioTrack,
      cacheKey: webpageUrl == null
          ? null
          : webTrackCacheKey(webpageUrl, 'audio', audioTrack),
    );
  }
  return source;
}

Map<String, Object> _remoteTrackSource(
  ResolvedWebVideoTrack track, {
  String? cacheKey,
}) => <String, Object>{
  'url': track.url.toString(),
  'formatHint': ?track.formatHint,
  'cacheKey': ?cacheKey,
  if (track.httpHeaders.isNotEmpty) 'httpHeaders': track.httpHeaders,
};

@visibleForTesting
String webTrackCacheKey(
  Uri webpageUrl,
  String role,
  ResolvedWebVideoTrack track,
) {
  final Uri mediaIdentity = track.url.replace(query: '', fragment: '');
  final String identity = <Object?>[
    webpageUrl,
    role,
    track.formatId ?? '',
    track.contentLength ?? '',
    mediaIdentity,
  ].join('|');
  final Digest digest = sha256.convert(utf8.encode(identity));
  final String encoded = base64Url.encode(digest.bytes).replaceAll('=', '');
  return 'web:$encoded:$role';
}

String? _validatedCacheKey(Object? rawValue) {
  if (rawValue == null) return null;
  if (rawValue is! String ||
      rawValue.isEmpty ||
      utf8.encode(rawValue).length > 256) {
    throw StateError('Persisted cache key is invalid');
  }
  return rawValue;
}

Map<String, Object>? _validatedAudioTrack(Object? rawValue) {
  if (rawValue == null) return null;
  if (rawValue is! Map<String, dynamic>) {
    throw StateError('Persisted audio track is invalid');
  }
  final Uri uri = Uri.parse(rawValue['url'] as String);
  if (!<String>{'http', 'https'}.contains(uri.scheme) || uri.host.isEmpty) {
    throw StateError('Persisted audio track URL is invalid');
  }
  final String? formatHint = rawValue['formatHint'] as String?;
  if (formatHint != null) {
    throw StateError('Persisted audio track format is invalid');
  }
  final String? cacheKey = _validatedCacheKey(rawValue['cacheKey']);
  final Map<String, String> headers = validateRemoteHttpHeaders(
    rawValue['httpHeaders'],
  );
  return <String, Object>{
    'url': uri.toString(),
    'formatHint': ?formatHint,
    'cacheKey': ?cacheKey,
    if (headers.isNotEmpty) 'httpHeaders': headers,
  };
}

@visibleForTesting
Map<String, Object> protocolSourceForItem(SenderPlaylistItem item) {
  if (item.isLocal) return item.source;
  final Map<String, Object> source = Map<String, Object>.of(item.source)
    ..remove('webpageUrl')
    ..remove('resolvedAt')
    ..remove('cookieBrowser');
  return validateRemoteMediaSource(source);
}

bool _resolvedWebSourceExpired(SenderPlaylistItem item) {
  if (item.isLocal || item.source['webpageUrl'] is! String) return false;
  final Object? rawResolvedAt = item.source['resolvedAt'];
  if (rawResolvedAt is! int || rawResolvedAt <= 0) return true;
  final int now = DateTime.now().millisecondsSinceEpoch;
  final int age = now - rawResolvedAt;
  return age < 0 ||
      age >= AppController._resolvedWebSourceMaxAge.inMilliseconds;
}

@visibleForTesting
int nextPlaylistRevision(int localRevision, int remoteRevision) =>
    max(localRevision, remoteRevision) + 1;
