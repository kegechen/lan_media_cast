import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lan_media_cast_sender/services/device_discovery.dart';

void main() {
  test('builds scoped and global broadcasts for each IPv4 adapter', () {
    expect(
      DeviceDiscovery.broadcastAddressesFor(
        InternetAddress('192.168.137.1'),
      ).map((InternetAddress address) => address.address),
      <String>['192.168.137.255', '192.168.255.255', '255.255.255.255'],
    );
    expect(
      DeviceDiscovery.broadcastAddressesFor(
        InternetAddress.anyIPv4,
      ).map((InternetAddress address) => address.address),
      <String>['255.255.255.255'],
    );
  });

  test('discovers a receiver through a socket bound to one adapter', () async {
    final RawDatagramSocket responder = await RawDatagramSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    addTearDown(responder.close);
    final StreamSubscription<RawSocketEvent> subscription = responder.listen((
      RawSocketEvent event,
    ) {
      if (event != RawSocketEvent.read) return;
      final Datagram? datagram = responder.receive();
      if (datagram == null) return;
      final Map<String, dynamic> query =
          jsonDecode(utf8.decode(datagram.data)) as Map<String, dynamic>;
      final List<int> response = utf8.encode(
        jsonEncode(<String, Object>{
          'v': 1,
          'type': 'discover.response',
          'requestId': query['requestId'] as String,
          'deviceId': 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
          'deviceName': 'Xiaomi 14',
          'wssPort': 39881,
          'busy': false,
          'pairingRequired': true,
          'protocolMin': 1,
          'protocolMax': 1,
          'capabilities': <String>['media', 'photo'],
        }),
      );
      responder.send(response, datagram.address, datagram.port);
    });
    addTearDown(subscription.cancel);
    final DeviceDiscovery discovery = DeviceDiscovery(
      senderId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
      senderName: 'Test Sender',
      timeout: const Duration(milliseconds: 200),
      localAddressProvider: () async => <InternetAddress>[
        InternetAddress.loopbackIPv4,
      ],
      broadcastAddress: InternetAddress.loopbackIPv4,
      discoveryPort: responder.port,
    );

    final List<DeviceTarget> devices = await discovery.scan();

    expect(devices, hasLength(1));
    expect(devices.single.deviceName, 'Xiaomi 14');
    expect(devices.single.address, InternetAddress.loopbackIPv4.address);
  });
}
