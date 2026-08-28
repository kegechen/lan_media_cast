import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:uuid/uuid.dart';

import '../protocol/protocol.dart';

typedef LocalAddressProvider = Future<List<InternetAddress>> Function();

class DeviceTarget {
  const DeviceTarget({
    required this.deviceId,
    required this.deviceName,
    required this.address,
    required this.wssPort,
    required this.busy,
    required this.pairingRequired,
    this.capabilities = const <String>[],
  });

  final String deviceId;
  final String deviceName;
  final String address;
  final int wssPort;
  final bool busy;
  final bool pairingRequired;
  final List<String> capabilities;
}

class DeviceDiscovery {
  DeviceDiscovery({
    required this.senderId,
    required this.senderName,
    this.timeout = const Duration(seconds: 2),
    LocalAddressProvider? localAddressProvider,
    InternetAddress? broadcastAddress,
    int discoveryPort = 39880,
  }) : _localAddressProvider = localAddressProvider ?? _defaultLocalAddresses,
       _broadcastAddressOverride = broadcastAddress,
       _discoveryPort = discoveryPort;

  final String senderId;
  final String senderName;
  final Duration timeout;
  final LocalAddressProvider _localAddressProvider;
  final InternetAddress? _broadcastAddressOverride;
  final int _discoveryPort;

  Future<List<DeviceTarget>> scan() async {
    final List<InternetAddress> resolvedAddresses =
        await _localAddressProvider().timeout(const Duration(seconds: 3));
    final Map<String, InternetAddress> uniqueAddresses =
        <String, InternetAddress>{
          for (final InternetAddress address in resolvedAddresses)
            address.address: address,
        };
    if (uniqueAddresses.isEmpty) {
      uniqueAddresses[InternetAddress.anyIPv4.address] =
          InternetAddress.anyIPv4;
    }
    final List<RawDatagramSocket> sockets = <RawDatagramSocket>[];
    for (final InternetAddress address in uniqueAddresses.values) {
      try {
        final RawDatagramSocket socket = await RawDatagramSocket.bind(
          address,
          0,
        ).timeout(const Duration(seconds: 3));
        socket.broadcastEnabled = true;
        sockets.add(socket);
      } on Object {
        // A stale virtual adapter must not prevent discovery on active adapters.
      }
    }
    if (sockets.isEmpty) {
      throw const SocketException('无法在活动 IPv4 网卡上启动设备发现');
    }
    final String requestId = const Uuid().v4();
    final List<int> query = utf8.encode(
      jsonEncode(
        DiscoveryQuery(
          requestId: requestId,
          senderId: senderId,
          senderName: senderName,
        ).toJson(),
      ),
    );
    final Map<String, DeviceTarget> devices = <String, DeviceTarget>{};
    final List<StreamSubscription<RawSocketEvent>> subscriptions =
        <StreamSubscription<RawSocketEvent>>[];
    for (final RawDatagramSocket socket in sockets) {
      subscriptions.add(
        socket.listen(
          (RawSocketEvent event) {
            if (event != RawSocketEvent.read) return;
            Datagram? datagram;
            while ((datagram = socket.receive()) != null) {
              try {
                final DiscoveryResponse response = DiscoveryResponse.decode(
                  datagram!.data,
                );
                if (response.requestId != requestId ||
                    response.protocolMin > protocolVersion ||
                    response.protocolMax < protocolVersion) {
                  continue;
                }
                devices[response.deviceId] = DeviceTarget(
                  deviceId: response.deviceId,
                  deviceName: response.deviceName,
                  address: datagram.address.address,
                  wssPort: response.wssPort,
                  busy: response.busy,
                  pairingRequired: response.pairingRequired,
                  capabilities: response.capabilities,
                );
              } on Object {
                // Ignore unauthenticated or unrelated UDP traffic.
              }
            }
          },
          onError: (_) {},
          cancelOnError: false,
        ),
      );
    }
    try {
      int sentBytes = 0;
      for (final RawDatagramSocket socket in sockets) {
        final List<InternetAddress> broadcastAddresses =
            _broadcastAddressOverride == null
            ? broadcastAddressesFor(socket.address)
            : <InternetAddress>[_broadcastAddressOverride];
        for (final InternetAddress broadcastAddress in broadcastAddresses) {
          try {
            sentBytes += socket.send(query, broadcastAddress, _discoveryPort);
          } on Object {
            // Continue across adapters; at least one successful send is required.
          }
        }
      }
      if (sentBytes == 0) throw const SocketException('设备发现广播发送失败');
      await Future<void>.delayed(timeout);
    } finally {
      for (final StreamSubscription<RawSocketEvent> subscription
          in subscriptions) {
        await subscription.cancel();
      }
      for (final RawDatagramSocket socket in sockets) {
        socket.close();
      }
    }
    return devices.values.toList()..sort(
      (DeviceTarget left, DeviceTarget right) =>
          left.deviceName.compareTo(right.deviceName),
    );
  }

  static Future<List<InternetAddress>> _defaultLocalAddresses() async {
    final List<NetworkInterface> interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
      includeLinkLocal: false,
    );
    return <InternetAddress>[
      for (final NetworkInterface interface in interfaces)
        for (final InternetAddress address in interface.addresses) address,
    ];
  }

  static List<InternetAddress> broadcastAddressesFor(
    InternetAddress localAddress,
  ) {
    final List<String> octets = localAddress.address.split('.');
    if (localAddress.type != InternetAddressType.IPv4 ||
        octets.length != 4 ||
        octets.any((String octet) => int.tryParse(octet) == null) ||
        localAddress.address == InternetAddress.anyIPv4.address) {
      return <InternetAddress>[InternetAddress('255.255.255.255')];
    }
    return <InternetAddress>[
      InternetAddress('${octets[0]}.${octets[1]}.${octets[2]}.255'),
      InternetAddress('${octets[0]}.${octets[1]}.255.255'),
      InternetAddress('255.255.255.255'),
    ];
  }

  DeviceTarget manual(String input) {
    final String trimmed = input.trim();
    final Uri uri = trimmed.contains('://')
        ? Uri.parse(trimmed)
        : Uri.parse('wss://$trimmed');
    final String host = uri.host;
    if (host.isEmpty ||
        InternetAddress.tryParse(host)?.type != InternetAddressType.IPv4) {
      throw const FormatException('请输入有效的 IPv4 地址');
    }
    final int port = uri.hasPort ? uri.port : 39881;
    if (port < 1 || port > 65535) throw const FormatException('端口无效');
    return DeviceTarget(
      deviceId: 'manual-$host-$port',
      deviceName: host,
      address: host,
      wssPort: port,
      busy: false,
      pairingRequired: true,
    );
  }
}
