import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_controller.dart';
import 'app_version.dart';
import 'services/app_log.dart';
import 'services/cast_connection.dart';
import 'services/device_discovery.dart';
import 'services/user_facing_error.dart';
import 'services/yt_dlp_resolver.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppLog.instance.initialize();
  FlutterError.onError = (FlutterErrorDetails details) {
    FlutterError.presentError(details);
    unawaited(
      AppLog.instance.error(
        'flutter.unhandled_error',
        details.exception,
        stackTrace: details.stack,
      ),
    );
  };
  PlatformDispatcher.instance.onError = (Object error, StackTrace stackTrace) {
    unawaited(
      AppLog.instance.error(
        'platform.unhandled_error',
        error,
        stackTrace: stackTrace,
      ),
    );
    return false;
  };
  await AppLog.instance.info(
    'application.start',
    fields: <String, Object?>{
      'version': senderAppVersion,
      'platform': defaultTargetPlatform.name,
    },
  );
  runApp(const LanMediaCastApp());
}

class LanMediaCastApp extends StatelessWidget {
  const LanMediaCastApp({super.key});

  @override
  Widget build(BuildContext context) {
    final bool android = defaultTargetPlatform == TargetPlatform.android;
    final ColorScheme colors =
        ColorScheme.fromSeed(
          seedColor: const Color(0xff00796b),
          primary: const Color(0xff00796b),
          secondary: const Color(0xffb85c16),
          surface: const Color(0xfffbfcfc),
        ).copyWith(
          surfaceContainerLowest: Colors.white,
          surfaceContainerLow: const Color(0xfff5f7f7),
          surfaceContainer: const Color(0xffedf1f0),
          outline: const Color(0xffb8c3c1),
          outlineVariant: const Color(0xffd8dfde),
        );
    return MaterialApp(
      title: 'LAN Media Cast',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.light,
        colorScheme: colors,
        fontFamily: android ? null : 'Segoe UI',
        visualDensity: android ? VisualDensity.standard : VisualDensity.compact,
        scaffoldBackgroundColor: const Color(0xfff2f5f4),
        appBarTheme: AppBarTheme(
          elevation: 0,
          scrolledUnderElevation: 0,
          centerTitle: false,
          backgroundColor: colors.surfaceContainerLowest,
          foregroundColor: const Color(0xff17201f),
          surfaceTintColor: Colors.transparent,
          toolbarHeight: android ? 64 : 60,
          titleSpacing: android ? 18 : 20,
        ),
        cardTheme: const CardThemeData(
          elevation: 0,
          margin: EdgeInsets.zero,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(8)),
            side: BorderSide(color: Color(0xffd8dfde)),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: colors.surfaceContainerLowest,
          border: const OutlineInputBorder(
            borderRadius: BorderRadius.all(Radius.circular(8)),
            borderSide: BorderSide(color: Color(0xffb8c3c1)),
          ),
          enabledBorder: const OutlineInputBorder(
            borderRadius: BorderRadius.all(Radius.circular(8)),
            borderSide: BorderSide(color: Color(0xffc8d1cf)),
          ),
          isDense: true,
          contentPadding: EdgeInsets.symmetric(
            horizontal: 14,
            vertical: android ? 14 : 12,
          ),
        ),
        dividerTheme: const DividerThemeData(
          color: Color(0xffdfe5e4),
          thickness: 1,
          space: 1,
        ),
        listTileTheme: ListTileThemeData(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
          selectedTileColor: const Color(0xffdcefeb),
          selectedColor: const Color(0xff005f54),
          iconColor: const Color(0xff52605e),
          contentPadding: EdgeInsets.symmetric(horizontal: android ? 14 : 12),
          minTileHeight: android ? 56 : 48,
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
            minimumSize: Size(0, android ? 46 : 38),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
            minimumSize: Size(0, android ? 46 : 38),
          ),
        ),
        dialogTheme: const DialogThemeData(
          elevation: 16,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(8)),
          ),
        ),
      ),
      home: const _BootstrapScreen(),
    );
  }
}

class _BootstrapScreen extends StatefulWidget {
  const _BootstrapScreen();

  @override
  State<_BootstrapScreen> createState() => _BootstrapScreenState();
}

class _BootstrapScreenState extends State<_BootstrapScreen> {
  late final Future<AppController> _controller = _createController();
  AppController? _ownedController;
  bool _disposed = false;

  Future<AppController> _createController() async {
    final AppController controller = await AppController.create();
    if (_disposed) {
      controller.dispose();
    } else {
      _ownedController = controller;
    }
    return controller;
  }

  @override
  void dispose() {
    _disposed = true;
    _ownedController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<AppController>(
      future: _controller,
      builder: (BuildContext context, AsyncSnapshot<AppController> snapshot) {
        if (snapshot.hasError) {
          return Scaffold(
            body: Center(child: Text('初始化失败：${snapshot.error.runtimeType}')),
          );
        }
        final AppController? controller = snapshot.data;
        if (controller == null) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        return SenderScreen(controller: controller);
      },
    );
  }
}

class SenderScreen extends StatefulWidget {
  const SenderScreen({super.key, required this.controller});

  final AppController controller;

  @override
  State<SenderScreen> createState() => _SenderScreenState();
}

class _SenderScreenState extends State<SenderScreen> {
  final TextEditingController _manualAddress = TextEditingController();
  bool _pairingDialogOpen = false;
  bool _trustDialogOpen = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_refresh);
    unawaited(widget.controller.scan());
  }

  @override
  void dispose() {
    widget.controller.removeListener(_refresh);
    _manualAddress.dispose();
    super.dispose();
  }

  void _refresh() {
    if (!mounted) return;
    setState(() {});
    final CastConnection connection = widget.controller.connection;
    if (connection.pairingRequired && !_pairingDialogOpen) {
      _pairingDialogOpen = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => _showPairingDialog());
    }
    if (connection.certificateChanged && !_trustDialogOpen) {
      _trustDialogOpen = true;
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _showTrustChangeDialog(),
      );
    }
  }

  Future<void> _showTrustChangeDialog() async {
    try {
      if (!mounted) return;
      final CastConnection connection = widget.controller.connection;
      if (connection.isDisposed || !connection.certificateChanged) return;
      final String address =
          '${connection.target?.address ?? '?'}:${connection.target?.wssPort ?? '?'}';
      final String pinned = _shortFingerprint(connection.pinnedFingerprint);
      final String presented = _shortFingerprint(connection.presentedFingerprint);
      final bool? retrust = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (BuildContext dialogContext) => AlertDialog(
          title: const Text('接收端身份已变化'),
          content: SelectionArea(
            child: Text(
              // Deliberately identified by address and fingerprint rather than
              // by device name: the name comes from an unauthenticated
              // discovery response and can be spoofed.
              '$address 出示的证书与上次连接时不同。\n\n'
              '已保存指纹：$pinned\n'
              '本次出示：$presented\n\n'
              '接收端重装或升级后会出现这种情况，属于正常现象。但如果你并未升级过它，'
              '也可能是同网段的其他设备在冒充它。\n\n'
              '确认重新信任会清除已保存的凭据，并需要重新输入一次电视上显示的 6 位连接码。',
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('重新信任'),
            ),
          ],
        ),
      );
      if (!mounted || connection.isDisposed) return;
      if (retrust == true) {
        await connection.trustChangedReceiver();
      } else {
        await connection.disconnect();
      }
    } on Object catch (error, stackTrace) {
      unawaited(
        AppLog.instance.error(
          'connection.retrust_failed',
          error,
          stackTrace: stackTrace,
        ),
      );
    } finally {
      _trustDialogOpen = false;
      // Re-raise the prompt if re-trusting failed: the connection is still
      // blocked, and nothing else would notify us to ask again.
      final CastConnection connection = widget.controller.connection;
      if (mounted &&
          !connection.isDisposed &&
          connection.certificateChanged &&
          !_pairingDialogOpen) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
      }
    }
  }

  static String _shortFingerprint(String? fingerprint) {
    if (fingerprint == null || fingerprint.isEmpty) return '未知';
    return fingerprint.length <= 16
        ? fingerprint
        : '${fingerprint.substring(0, 16)}…';
  }

  Future<void> _openLogDirectory() async {
    try {
      await AppLog.instance.openDirectory();
    } on Object catch (error, stackTrace) {
      unawaited(
        AppLog.instance.error(
          'log_directory.open_failed',
          error,
          stackTrace: stackTrace,
        ),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('无法打开日志目录')));
    }
  }

  Future<void> _showPairingDialog() async {
    try {
      if (!mounted) return;
      final CastConnection connection = widget.controller.connection;
      if (connection.isDisposed) return;
      final bool? connected = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (BuildContext context) =>
            PairingDialog(connection: connection),
      );
      if (!mounted || connection.isDisposed) return;
      if (connected != true) await connection.disconnect();
    } finally {
      _pairingDialogOpen = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppController controller = widget.controller;
    return Scaffold(
      appBar: AppBar(
        title: const Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.cast_connected, size: 24, color: Color(0xff00796b)),
            SizedBox(width: 10),
            Text(
              'LAN Media Cast',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                letterSpacing: 0,
              ),
            ),
          ],
        ),
        actions: <Widget>[
          if (controller.busy)
            const Padding(
              padding: EdgeInsets.only(right: 12),
              child: SizedBox.square(
                dimension: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          if (defaultTargetPlatform == TargetPlatform.windows)
            IconButton(
              onPressed: controller.busy || !controller.connection.isReady
                  ? null
                  : () => unawaited(controller.fetchReceiverLogs()),
              icon: const Icon(Icons.download_for_offline_outlined),
              tooltip: '获取接收端日志',
            ),
          if (defaultTargetPlatform == TargetPlatform.windows)
            IconButton(
              onPressed: _openLogDirectory,
              icon: const Icon(Icons.folder_open_outlined),
              tooltip: '打开日志目录',
            ),
          _ConnectionChip(connection: controller.connection),
          const SizedBox(width: 16),
        ],
      ),
      body: Column(
        children: <Widget>[
          _StatusBanner(controller: controller),
          Expanded(
            child: LayoutBuilder(
              builder: (BuildContext context, BoxConstraints constraints) {
                final Widget devices = _DevicePanel(
                  controller: controller,
                  manualAddress: _manualAddress,
                );
                final Widget playlist = _PlaylistPanel(controller: controller);
                if (constraints.maxWidth >= 840) {
                  return Row(
                    children: <Widget>[
                      SizedBox(width: 328, child: devices),
                      const VerticalDivider(width: 1),
                      Expanded(child: playlist),
                    ],
                  );
                }
                return Column(
                  children: <Widget>[
                    SizedBox(
                      height: defaultTargetPlatform == TargetPlatform.android
                          ? 214
                          : 230,
                      child: devices,
                    ),
                    const Divider(height: 1),
                    Expanded(child: playlist),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class PairingDialog extends StatefulWidget {
  const PairingDialog({super.key, required this.connection});

  final CastConnection connection;

  @override
  State<PairingDialog> createState() => _PairingDialogState();
}

class _PairingDialogState extends State<PairingDialog> {
  final TextEditingController _codeController = TextEditingController();
  String? _challengeId;
  String? _validationError;
  bool _submitting = false;
  bool _listening = false;

  @override
  void initState() {
    super.initState();
    _challengeId = widget.connection.pairingChallengeId;
    if (!widget.connection.isDisposed) {
      widget.connection.addListener(_onConnectionChanged);
      _listening = true;
    }
  }

  @override
  void dispose() {
    if (_listening && !widget.connection.isDisposed) {
      widget.connection.removeListener(_onConnectionChanged);
    }
    _codeController.dispose();
    super.dispose();
  }

  void _onConnectionChanged() {
    if (!mounted) return;
    final String? challengeId = widget.connection.pairingChallengeId;
    if (challengeId == null || challengeId == _challengeId) return;
    setState(() {
      _challengeId = challengeId;
      _codeController.clear();
      _submitting = false;
      _validationError = '连接已刷新，请输入投影仪上新的连接码';
    });
  }

  Future<void> _submit() async {
    if (widget.connection.isDisposed) {
      if (mounted) Navigator.pop(context, false);
      return;
    }
    final String code = _codeController.text.trim();
    if (!RegExp(r'^\d{6}$').hasMatch(code)) {
      setState(() => _validationError = '请输入 6 位数字');
      return;
    }
    setState(() {
      _submitting = true;
      _validationError = null;
    });
    try {
      await widget.connection.confirmPairing(code);
      if (mounted) Navigator.pop(context, true);
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _validationError = userFacingError(error);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('输入连接码'),
      content: SizedBox(
        width: 300,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            const Text('连接码显示在投影仪画面上'),
            const SizedBox(height: 12),
            TextField(
              controller: _codeController,
              autofocus: true,
              keyboardType: TextInputType.number,
              textAlign: TextAlign.center,
              maxLength: 6,
              inputFormatters: <TextInputFormatter>[
                FilteringTextInputFormatter.digitsOnly,
              ],
              decoration: InputDecoration(
                hintText: '6 位数字',
                errorText: _validationError,
                counterText: '',
              ),
              onSubmitted: _submitting ? null : (_) => _submit(),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: _submitting ? null : () => Navigator.pop(context, false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _submitting ? null : _submit,
          child: _submitting
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('连接'),
        ),
      ],
    );
  }
}

class _ConnectionChip extends StatelessWidget {
  const _ConnectionChip({required this.connection});

  final CastConnection connection;

  @override
  Widget build(BuildContext context) {
    final (IconData, String, Color) presentation = switch (connection.phase) {
      ConnectionPhase.ready => (
        Icons.cast_connected,
        '已连接',
        const Color(0xff147d68),
      ),
      ConnectionPhase.pairing => (Icons.pin, '配对中', const Color(0xffbc6b21)),
      ConnectionPhase.connecting || ConnectionPhase.reconnecting => (
        Icons.sync,
        '连接中',
        const Color(0xffbc6b21),
      ),
      ConnectionPhase.disconnected => (
        Icons.cast,
        '未连接',
        const Color(0xff687272),
      ),
    };
    final bool compact = MediaQuery.sizeOf(context).width < 420;
    return Tooltip(
      message: presentation.$2,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(presentation.$1, size: 19, color: presentation.$3),
          if (!compact) ...<Widget>[
            const SizedBox(width: 7),
            Text(
              presentation.$2,
              style: const TextStyle(fontWeight: FontWeight.w500),
            ),
          ],
        ],
      ),
    );
  }
}

class _StatusBanner extends StatelessWidget {
  const _StatusBanner({required this.controller});

  final AppController controller;

  Future<void> _showDetails(BuildContext context, String message) async {
    await showDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: Text(controller.statusIsError ? '错误详情' : '状态详情'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 620, maxHeight: 360),
          child: SingleChildScrollView(
            child: SelectionArea(child: Text(message)),
          ),
        ),
        actions: <Widget>[
          TextButton.icon(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: message));
              if (!dialogContext.mounted) return;
              Navigator.pop(dialogContext);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('消息已复制'),
                  duration: Duration(seconds: 1),
                ),
              );
            },
            icon: const Icon(Icons.copy),
            label: const Text('复制'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final String? message = controller.statusMessage;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      height: message == null ? 0 : 42,
      width: double.infinity,
      color: controller.statusIsError
          ? const Color(0xeba43e3e)
          : const Color(0xeb8b5c24),
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: message == null
          ? null
          : Row(
              children: <Widget>[
                Expanded(
                  child: Tooltip(
                    message: message,
                    child: SelectionArea(
                      child: Text(
                        message,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white),
                      ),
                    ),
                  ),
                ),
                IconButton(
                  tooltip: '查看详情',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints.tightFor(
                    width: 32,
                    height: 32,
                  ),
                  onPressed: () => _showDetails(context, message),
                  icon: const Icon(
                    Icons.info_outline,
                    size: 18,
                    color: Colors.white,
                  ),
                ),
                IconButton(
                  tooltip: '复制消息',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints.tightFor(
                    width: 32,
                    height: 32,
                  ),
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: message));
                    if (!context.mounted) return;
                    final ScaffoldMessengerState messenger =
                        ScaffoldMessenger.of(context);
                    messenger
                      ..hideCurrentSnackBar()
                      ..showSnackBar(
                        const SnackBar(
                          content: Text('消息已复制'),
                          duration: Duration(seconds: 1),
                        ),
                      );
                  },
                  icon: const Icon(Icons.copy, size: 18, color: Colors.white),
                ),
                IconButton(
                  tooltip: '关闭提示',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints.tightFor(
                    width: 32,
                    height: 32,
                  ),
                  onPressed: controller.dismissStatus,
                  icon: const Icon(Icons.close, size: 18, color: Colors.white),
                ),
              ],
            ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.icon, required this.title});

  final IconData icon;
  final String title;

  @override
  Widget build(BuildContext context) {
    final Color foreground = Theme.of(context).colorScheme.onSurfaceVariant;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, size: 34, color: foreground.withValues(alpha: 0.65)),
          const SizedBox(height: 8),
          Text(title, style: TextStyle(color: foreground)),
        ],
      ),
    );
  }
}

class _DevicePanel extends StatelessWidget {
  const _DevicePanel({required this.controller, required this.manualAddress});

  final AppController controller;
  final TextEditingController manualAddress;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                const Icon(Icons.devices_other_outlined, size: 20),
                const SizedBox(width: 8),
                Text('接收设备', style: Theme.of(context).textTheme.titleMedium),
                const Spacer(),
                IconButton(
                  tooltip: '重新扫描',
                  onPressed: controller.scanning ? null : controller.scan,
                  icon: controller.scanning
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh),
                ),
              ],
            ),
            Expanded(
              child: controller.devices.isEmpty
                  ? const _EmptyState(
                      icon: Icons.cast_outlined,
                      title: '暂无可用设备',
                    )
                  : ListView.builder(
                      itemCount: controller.devices.length,
                      itemBuilder: (BuildContext context, int index) {
                        final DeviceTarget device = controller.devices[index];
                        final DeviceTarget? currentTarget =
                            controller.connection.target;
                        final bool isConnected =
                            controller.connection.isReady &&
                            currentTarget != null &&
                            targetsReferToSameReceiver(device, currentTarget);
                        return ListTile(
                          dense: true,
                          selected: isConnected,
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(
                            isConnected || device.busy
                                ? Icons.cast_connected
                                : Icons.cast,
                          ),
                          title: Text(
                            device.deviceName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            '${device.address}:${device.wssPort}'
                            '${isConnected ? ' · 已连接' : ''}',
                          ),
                          enabled:
                              !isConnected && !device.busy && !controller.busy,
                          onTap: isConnected
                              ? null
                              : () => controller.connect(device),
                        );
                      },
                    ),
            ),
            Row(
              children: <Widget>[
                Expanded(
                  child: TextField(
                    controller: manualAddress,
                    decoration: const InputDecoration(
                      hintText: '投影仪 IP 或 IP:端口',
                      prefixIcon: Icon(Icons.lan_outlined, size: 20),
                    ),
                    onSubmitted: controller.connectManual,
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  tooltip: '连接',
                  onPressed: controller.busy
                      ? null
                      : () => controller.connectManual(manualAddress.text),
                  icon: const Icon(Icons.arrow_forward),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _PlaylistPanel extends StatelessWidget {
  const _PlaylistPanel({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final RemotePlayerState? player = controller.connection.playerState;
    return ColoredBox(
      color: Theme.of(context).colorScheme.surfaceContainerLowest,
      child: Column(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 12, 12, 10),
            child: LayoutBuilder(
              builder: (BuildContext context, BoxConstraints constraints) {
                final bool compact = constraints.maxWidth < 560;
                final Widget title = Row(
                  children: <Widget>[
                    const Icon(Icons.queue_music_outlined, size: 22),
                    const SizedBox(width: 9),
                    Text(
                      '播放列表',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(width: 10),
                    Text(
                      '${controller.playlist.length} 项',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                );
                final Widget actions = _headerActions(context, compact);
                if (compact) {
                  return Row(
                    children: <Widget>[
                      Expanded(child: title),
                      actions,
                    ],
                  );
                }
                return Row(children: <Widget>[title, const Spacer(), actions]);
              },
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: controller.playlist.isEmpty
                ? const _EmptyState(
                    icon: Icons.video_library_outlined,
                    title: '暂无播放内容',
                  )
                : ReorderableListView.builder(
                    buildDefaultDragHandles: false,
                    itemCount: controller.playlist.length,
                    onReorder: controller.reorder,
                    itemBuilder: (BuildContext context, int index) {
                      final SenderPlaylistItem item =
                          controller.playlist[index];
                      final bool active = player?.itemId == item.id;
                      final bool insecure = isInsecureRemoteSource(item);
                      final String subtitle =
                          item.unavailableReason ??
                          (item.isLocal
                              ? _formatBytes(item.localAsset!.size)
                              : item.source['webpageUrl'] != null
                              ? insecure
                                    ? '网页视频 · 不安全（明文 HTTP）'
                                    : '网页视频'
                              : insecure
                              ? '网络媒体 · 不安全（明文 HTTP）'
                              : '网络媒体');
                      return ListTile(
                        key: ValueKey<String>(item.id),
                        selected: active,
                        leading: Icon(
                          active
                              ? Icons.play_circle_fill
                              : item.isLocal
                              ? Icons.movie_outlined
                              : item.source['webpageUrl'] != null
                              ? Icons.language
                              : Icons.link,
                        ),
                        title: Text(
                          item.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Row(
                          children: <Widget>[
                            if (insecure) ...<Widget>[
                              Icon(
                                Icons.warning_amber_rounded,
                                size: 16,
                                color: Theme.of(context).colorScheme.error,
                              ),
                              const SizedBox(width: 4),
                            ],
                            Expanded(
                              child: Text(
                                subtitle,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: item.isAvailable && !insecure
                                    ? null
                                    : TextStyle(
                                        color: Theme.of(
                                          context,
                                        ).colorScheme.error,
                                      ),
                              ),
                            ),
                          ],
                        ),
                        onTap:
                            controller.connection.canControl && item.isAvailable
                            ? () => controller.selectItem(item)
                            : null,
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            IconButton(
                              tooltip: '移除',
                              onPressed: controller.busy
                                  ? null
                                  : () => controller.removeItem(index),
                              icon: const Icon(Icons.close),
                            ),
                            ReorderableDragStartListener(
                              index: index,
                              child: const Padding(
                                padding: EdgeInsets.all(12),
                                child: Icon(Icons.drag_handle),
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
          const Divider(height: 1),
          _PlaybackControls(controller: controller),
        ],
      ),
    );
  }

  Widget _headerActions(BuildContext context, bool compact) {
    final VoidCallback? photoAction =
        controller.busy || !controller.connection.isReady
        ? null
        : controller.photoMode
        ? controller.returnToMedia
        : controller.pickPhotos;
    if (compact) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          IconButton(
            tooltip: '添加网络地址',
            onPressed: controller.busy ? null : () => _showUrlDialog(context),
            icon: const Icon(Icons.link),
          ),
          IconButton(
            tooltip: controller.photoMode ? '返回视频' : '选择照片',
            onPressed: photoAction,
            icon: Icon(
              controller.photoMode
                  ? Icons.movie_outlined
                  : Icons.photo_library_outlined,
            ),
          ),
          IconButton.filled(
            tooltip: '添加媒体',
            onPressed: controller.busy ? null : controller.pickMediaFiles,
            icon: const Icon(Icons.add),
          ),
        ],
      );
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        OutlinedButton.icon(
          onPressed: controller.busy ? null : () => _showUrlDialog(context),
          icon: const Icon(Icons.link),
          label: const Text('网络地址'),
        ),
        const SizedBox(width: 8),
        OutlinedButton.icon(
          onPressed: photoAction,
          icon: Icon(
            controller.photoMode
                ? Icons.movie_outlined
                : Icons.photo_library_outlined,
          ),
          label: Text(controller.photoMode ? '返回视频' : '照片'),
        ),
        const SizedBox(width: 8),
        FilledButton.icon(
          onPressed: controller.busy ? null : controller.pickMediaFiles,
          icon: const Icon(Icons.add),
          label: const Text('添加媒体'),
        ),
      ],
    );
  }

  Future<void> _showUrlDialog(BuildContext context) async {
    final TextEditingController input = TextEditingController();
    bool useBrowserSession = false;
    YtDlpBrowser selectedBrowser = YtDlpBrowser.edge;
    final _UrlDialogResult? result;
    try {
      result = await showDialog<_UrlDialogResult>(
        context: context,
        builder: (BuildContext context) => StatefulBuilder(
          builder: (BuildContext context, StateSetter setState) => AlertDialog(
            title: const Text('添加链接'),
            content: SizedBox(
              width: 520,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  TextField(
                    controller: input,
                    autofocus: true,
                    keyboardType: TextInputType.url,
                    decoration: InputDecoration(
                      hintText: '网页视频或媒体直链',
                      prefixIcon: const Icon(Icons.link),
                      suffixIcon: IconButton(
                        tooltip: '粘贴',
                        onPressed: () async {
                          final ClipboardData? data = await Clipboard.getData(
                            Clipboard.kTextPlain,
                          );
                          final String? text = data?.text;
                          if (text != null) {
                            final String normalized =
                                parseNetworkMediaInput(text)?.toString() ??
                                text.trim();
                            input
                              ..text = normalized
                              ..selection = TextSelection.collapsed(
                                offset: normalized.length,
                              );
                          }
                        },
                        icon: const Icon(Icons.content_paste_outlined),
                      ),
                    ),
                    onSubmitted: (String value) => Navigator.pop(
                      context,
                      _UrlDialogResult(
                        value,
                        useBrowserSession ? selectedBrowser : null,
                      ),
                    ),
                  ),
                  if (defaultTargetPlatform ==
                      TargetPlatform.windows) ...<Widget>[
                    const SizedBox(height: 10),
                    CheckboxListTile(
                      value: useBrowserSession,
                      contentPadding: EdgeInsets.zero,
                      controlAffinity: ListTileControlAffinity.leading,
                      title: const Text('使用浏览器登录状态'),
                      onChanged: (bool? value) =>
                          setState(() => useBrowserSession = value ?? false),
                    ),
                    if (useBrowserSession)
                      DropdownButtonFormField<YtDlpBrowser>(
                        initialValue: selectedBrowser,
                        decoration: const InputDecoration(
                          labelText: '浏览器',
                          prefixIcon: Icon(Icons.public),
                        ),
                        items: YtDlpBrowser.values
                            .map(
                              (YtDlpBrowser browser) =>
                                  DropdownMenuItem<YtDlpBrowser>(
                                    value: browser,
                                    child: Text(_browserName(browser)),
                                  ),
                            )
                            .toList(),
                        onChanged: (YtDlpBrowser? value) {
                          if (value != null) selectedBrowser = value;
                        },
                      ),
                  ],
                ],
              ),
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('取消'),
              ),
              FilledButton.icon(
                onPressed: () => Navigator.pop(
                  context,
                  _UrlDialogResult(
                    input.text,
                    useBrowserSession ? selectedBrowser : null,
                  ),
                ),
                icon: const Icon(Icons.add_link),
                label: const Text('添加'),
              ),
            ],
          ),
        ),
      );
    } finally {
      input.dispose();
    }
    if (result == null) return;
    if (isInsecureHttpInput(result.value)) {
      if (!context.mounted) return;
      final bool confirmed =
          await showDialog<bool>(
            context: context,
            builder: (BuildContext context) => AlertDialog(
              icon: Icon(
                Icons.warning_amber_rounded,
                color: Theme.of(context).colorScheme.error,
              ),
              title: const Text('使用明文 HTTP？'),
              content: const Text('此地址的媒体内容不会加密，仅建议在可信局域网中使用。'),
              actions: <Widget>[
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('仍然添加'),
                ),
              ],
            ),
          ) ??
          false;
      if (!confirmed) return;
    }
    await controller.addUrl(result.value, cookieBrowser: result.cookieBrowser);
  }

  String _formatBytes(int bytes) {
    const int gib = 1024 * 1024 * 1024;
    const int mib = 1024 * 1024;
    if (bytes >= gib) return '${(bytes / gib).toStringAsFixed(1)} GiB';
    return '${(bytes / mib).toStringAsFixed(1)} MiB';
  }
}

class _UrlDialogResult {
  const _UrlDialogResult(this.value, this.cookieBrowser);

  final String value;
  final YtDlpBrowser? cookieBrowser;
}

String _browserName(YtDlpBrowser browser) => switch (browser) {
  YtDlpBrowser.edge => 'Microsoft Edge',
  YtDlpBrowser.chrome => 'Google Chrome',
  YtDlpBrowser.firefox => 'Mozilla Firefox',
};

class _PlaybackControls extends StatelessWidget {
  const _PlaybackControls({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final RemotePlayerState? player = controller.connection.playerState;
    final bool enabled =
        controller.connection.canControl &&
        controller.playlist.any((SenderPlaylistItem item) => item.isAvailable);
    final int duration = player?.durationMs ?? 0;
    final int position = (player?.positionMs ?? 0).clamp(
      0,
      duration <= 0 ? 0 : duration,
    );
    return ColoredBox(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          16,
          defaultTargetPlatform == TargetPlatform.android ? 12 : 8,
          16,
          defaultTargetPlatform == TargetPlatform.android ? 16 : 12,
        ),
        child: Column(
          children: <Widget>[
            _SeekSlider(
              positionMs: position,
              durationMs: duration,
              enabled: enabled,
              onSeek: controller.seek,
            ),
            LayoutBuilder(
              builder: (BuildContext context, BoxConstraints constraints) {
                final bool compact = constraints.maxWidth < 620;
                final Widget transport = _transportControls(player, enabled);
                final Widget mode = _repeatModeControl(enabled, compact);
                if (compact) {
                  return Column(
                    children: <Widget>[
                      transport,
                      const SizedBox(height: 8),
                      SizedBox(width: double.infinity, child: mode),
                    ],
                  );
                }
                return Row(children: <Widget>[transport, const Spacer(), mode]);
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _transportControls(RemotePlayerState? player, bool enabled) => Row(
    mainAxisSize: MainAxisSize.min,
    children: <Widget>[
      IconButton(
        tooltip: '上一项',
        onPressed: enabled ? controller.previous : null,
        icon: const Icon(Icons.skip_previous),
      ),
      IconButton.filled(
        tooltip: player?.state == 'playing' ? '暂停' : '播放',
        onPressed: enabled
            ? (player?.state == 'playing' ? controller.pause : controller.play)
            : null,
        icon: Icon(player?.state == 'playing' ? Icons.pause : Icons.play_arrow),
      ),
      IconButton(
        tooltip: '停止',
        onPressed: enabled ? controller.stop : null,
        icon: const Icon(Icons.stop),
      ),
      IconButton(
        tooltip: '下一项',
        onPressed: enabled ? controller.next : null,
        icon: const Icon(Icons.skip_next),
      ),
    ],
  );

  Widget _repeatModeControl(bool enabled, bool compact) {
    final List<ButtonSegment<String>> segments = compact
        ? const <ButtonSegment<String>>[
            ButtonSegment<String>(
              value: 'playOnce',
              icon: Tooltip(
                message: '播完暂停',
                child: Icon(Icons.stop_circle_outlined),
              ),
            ),
            ButtonSegment<String>(
              value: 'repeatOne',
              icon: Tooltip(message: '单项循环', child: Icon(Icons.repeat_one)),
            ),
            ButtonSegment<String>(
              value: 'repeatAll',
              icon: Tooltip(message: '列表循环', child: Icon(Icons.repeat)),
            ),
          ]
        : const <ButtonSegment<String>>[
            ButtonSegment<String>(
              value: 'playOnce',
              icon: Icon(Icons.stop_circle_outlined),
              label: Text('播完暂停'),
            ),
            ButtonSegment<String>(
              value: 'repeatOne',
              icon: Icon(Icons.repeat_one),
              label: Text('单项循环'),
            ),
            ButtonSegment<String>(
              value: 'repeatAll',
              icon: Icon(Icons.repeat),
              label: Text('列表循环'),
            ),
          ];
    return SegmentedButton<String>(
      segments: segments,
      selected: <String>{controller.repeatMode},
      showSelectedIcon: false,
      expandedInsets: compact ? EdgeInsets.zero : null,
      onSelectionChanged: enabled
          ? (Set<String> values) => controller.setRepeatMode(values.first)
          : null,
    );
  }
}

class _SeekSlider extends StatefulWidget {
  const _SeekSlider({
    required this.positionMs,
    required this.durationMs,
    required this.enabled,
    required this.onSeek,
  });

  final int positionMs;
  final int durationMs;
  final bool enabled;
  final Future<void> Function(int positionMs) onSeek;

  @override
  State<_SeekSlider> createState() => _SeekSliderState();
}

class _SeekSliderState extends State<_SeekSlider> {
  double? _dragValue;

  @override
  Widget build(BuildContext context) {
    final bool canSeek = widget.enabled && widget.durationMs > 0;
    final double maximum = widget.durationMs <= 0
        ? 1
        : widget.durationMs.toDouble();
    final double value = (_dragValue ?? widget.positionMs.toDouble()).clamp(
      0,
      maximum,
    );
    return Row(
      children: <Widget>[
        Text(_formatPlaybackTime(value.round())),
        Expanded(
          child: Slider(
            value: value,
            max: maximum,
            onChanged: canSeek
                ? (double nextValue) => setState(() => _dragValue = nextValue)
                : null,
            onChangeEnd: canSeek
                ? (double nextValue) {
                    setState(() => _dragValue = null);
                    widget.onSeek(nextValue.round());
                  }
                : null,
          ),
        ),
        Text(_formatPlaybackTime(widget.durationMs)),
      ],
    );
  }
}

String _formatPlaybackTime(int milliseconds) {
  final Duration duration = Duration(milliseconds: milliseconds);
  final String minutes = duration.inMinutes
      .remainder(60)
      .toString()
      .padLeft(2, '0');
  final String seconds = duration.inSeconds
      .remainder(60)
      .toString()
      .padLeft(2, '0');
  if (duration.inHours > 0) return '${duration.inHours}:$minutes:$seconds';
  return '$minutes:$seconds';
}
