import 'package:flutter_test/flutter_test.dart';
import 'package:lan_media_cast_sender/app_controller.dart';
import 'package:lan_media_cast_sender/services/device_discovery.dart';

void main() {
  test('manual target remains in list when discovery returns nothing', () {
    const DeviceTarget manual = DeviceTarget(
      deviceId: 'manual-192.168.137.126-39881',
      deviceName: '192.168.137.126',
      address: '192.168.137.126',
      wssPort: 39881,
      busy: false,
      pairingRequired: true,
    );

    expect(mergeDeviceTargets(const <DeviceTarget>[], manual), <DeviceTarget>[
      manual,
    ]);
  });

  test('discovered identity replaces manual target for the same endpoint', () {
    const DeviceTarget manual = DeviceTarget(
      deviceId: 'manual-192.168.137.126-39881',
      deviceName: '192.168.137.126',
      address: '192.168.137.126',
      wssPort: 39881,
      busy: false,
      pairingRequired: true,
    );
    const DeviceTarget discovered = DeviceTarget(
      deviceId: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
      deviceName: 'Xiaomi 14',
      address: '192.168.137.126',
      wssPort: 39881,
      busy: true,
      pairingRequired: true,
    );

    expect(
      mergeDeviceTargets(const <DeviceTarget>[discovered], manual),
      <DeviceTarget>[discovered],
    );
    expect(targetsReferToSameReceiver(discovered, manual), isTrue);
  });

  test('ready identity replaces a manual list entry', () {
    const DeviceTarget manual = DeviceTarget(
      deviceId: 'manual-192.168.137.126-39881',
      deviceName: '192.168.137.126',
      address: '192.168.137.126',
      wssPort: 39881,
      busy: false,
      pairingRequired: true,
    );
    const DeviceTarget ready = DeviceTarget(
      deviceId: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
      deviceName: 'Xiaomi 14',
      address: '192.168.137.126',
      wssPort: 39881,
      busy: false,
      pairingRequired: false,
    );

    expect(
      mergeDeviceTargets(const <DeviceTarget>[manual], ready),
      <DeviceTarget>[ready],
    );
  });
}
