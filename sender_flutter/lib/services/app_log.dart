import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;

class AppLog {
  AppLog({this.maxFileBytes = 2 * 1024 * 1024, this.retainedFileCount = 3});

  static final AppLog instance = AppLog();

  final int maxFileBytes;
  final int retainedFileCount;
  Directory? _directory;
  Future<void> _pendingWrite = Future<void>.value();

  String? get directoryPath => _directory?.path;

  Future<void> initialize({Directory? directory}) async {
    if (_directory != null) return;
    final Directory resolved = directory ?? _defaultDirectory();
    await resolved.create(recursive: true);
    _directory = resolved;
  }

  Future<void> info(
    String event, {
    Map<String, Object?> fields = const <String, Object?>{},
  }) => _enqueue('INFO', event, fields: fields);

  Future<void> warning(
    String event, {
    Map<String, Object?> fields = const <String, Object?>{},
  }) => _enqueue('WARN', event, fields: fields);

  Future<void> error(
    String event,
    Object error, {
    StackTrace? stackTrace,
    Map<String, Object?> fields = const <String, Object?>{},
  }) => _enqueue(
    'ERROR',
    event,
    fields: <String, Object?>{
      ...fields,
      'errorType': error.runtimeType.toString(),
      'error': error.toString(),
      if (stackTrace != null) 'stackTrace': stackTrace.toString(),
    },
  );

  Future<void> flush() => _pendingWrite;

  Future<void> openDirectory() async {
    final Directory? directory = _directory;
    if (directory == null) throw StateError('日志尚未初始化');
    if (!Platform.isWindows) throw UnsupportedError('当前平台不支持打开日志目录');
    await Process.start('explorer.exe', <String>[
      directory.path,
    ], mode: ProcessStartMode.detached).timeout(const Duration(seconds: 5));
  }

  Future<void> _enqueue(
    String level,
    String event, {
    required Map<String, Object?> fields,
  }) {
    final Map<String, Object?> entry = <String, Object?>{
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'level': level,
      'event': event,
      if (fields.isNotEmpty) 'fields': _sanitizeValue(fields),
    };
    final String line = '${jsonEncode(entry)}\n';
    final Future<void> next = _pendingWrite.then((_) => _write(line));
    _pendingWrite = next.catchError((Object _) {});
    return next;
  }

  Future<void> _write(String line) async {
    try {
      final Directory? directory = _directory;
      if (directory == null) return;
      final File active = File(path.join(directory.path, 'sender.log'));
      final int nextBytes = utf8.encode(line).length;
      if (await active.exists() &&
          await active.length() + nextBytes > maxFileBytes) {
        await _rotate(directory);
      }
      await active.writeAsString(line, mode: FileMode.append, flush: false);
    } on Object catch (error) {
      stderr.writeln('LAN Media Cast log write failed: ${error.runtimeType}');
    }
  }

  Future<void> _rotate(Directory directory) async {
    for (int index = retainedFileCount - 1; index >= 1; index--) {
      final File destination = File(
        path.join(directory.path, 'sender.$index.log'),
      );
      if (await destination.exists()) await destination.delete();
      final String sourceName = index == 1
          ? 'sender.log'
          : 'sender.${index - 1}.log';
      final File source = File(path.join(directory.path, sourceName));
      if (await source.exists()) await source.rename(destination.path);
    }
  }

  Directory _defaultDirectory() {
    if (Platform.isWindows) {
      final String? localAppData = Platform.environment['LOCALAPPDATA'];
      if (localAppData != null && localAppData.isNotEmpty) {
        return Directory(path.join(localAppData, 'LAN Media Cast', 'logs'));
      }
    }
    return Directory(
      path.join(Directory.systemTemp.path, 'LAN Media Cast', 'logs'),
    );
  }

  Object? _sanitizeValue(Object? value, {String? key}) {
    if (key != null && _isSensitiveKey(key)) return '[REDACTED]';
    if (value is String) return _sanitizeText(value);
    if (value is Map) {
      return <String, Object?>{
        for (final MapEntry<Object?, Object?> entry in value.entries)
          entry.key.toString(): _sanitizeValue(
            entry.value,
            key: entry.key.toString(),
          ),
      };
    }
    if (value is Iterable) {
      return value.map((Object? item) => _sanitizeValue(item)).toList();
    }
    return value;
  }

  bool _isSensitiveKey(String key) {
    final String normalized = key.toLowerCase().replaceAll(
      RegExp(r'[^a-z]'),
      '',
    );
    return normalized.contains('authorization') ||
        normalized.contains('bearertoken') ||
        normalized.contains('trustedtoken') ||
        normalized.contains('cookie') ||
        normalized.contains('privatekey') ||
        normalized.contains('certificatepem');
  }

  String _sanitizeText(String input) {
    String output = input.replaceAll(
      RegExp(r'Bearer\s+[^\s,;]+', caseSensitive: false),
      'Bearer [REDACTED]',
    );
    output = output.replaceAll(
      RegExp(r'Cookie\s*[:=]\s*[^\r\n]+', caseSensitive: false),
      'Cookie: [REDACTED]',
    );
    output = output.replaceAllMapped(
      RegExp(r'(https?|rtsp)://([^/\s?#]+)[^\s]*', caseSensitive: false),
      (Match match) => '${match.group(1)}://${match.group(2)}/[REDACTED]',
    );
    if (output.contains('-----BEGIN PRIVATE KEY-----')) {
      return '[PRIVATE_KEY_REDACTED]';
    }
    return output;
  }
}
