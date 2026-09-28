import 'package:flutter_test/flutter_test.dart';
import 'package:maxai/services/device_eligibility_service.dart';

void main() {
  const minimumStorage = DeviceEligibilityService.minimumFreeStorageBytes;

  DeviceEligibilityService service({
    required Future<double?> Function() totalRam,
    required Future<int?> Function() freeStorage,
  }) {
    return DeviceEligibilityService(
      totalRamReader: totalRam,
      freeStorageReader: freeStorage,
    );
  }

  test('rejects a device with less than 2 GB total RAM', () async {
    var checkedStorage = false;
    final eligibility = service(
      totalRam: () async => 1.99,
      freeStorage: () async {
        checkedStorage = true;
        return minimumStorage;
      },
    );

    final result = await eligibility.refreshEligibility();

    expect(result.status, DeviceEligibilityStatus.insufficientRam);
    expect(checkedStorage, isFalse);
  });

  test('accepts exactly 2 GB total RAM with sufficient storage', () async {
    final eligibility = service(
      totalRam: () async => 2.0,
      freeStorage: () async => minimumStorage,
    );

    final result = await eligibility.refreshEligibility();

    expect(result.isEligible, isTrue);
  });

  test('accepts more than 2 GB total RAM with sufficient storage', () async {
    final eligibility = service(
      totalRam: () async => 8.0,
      freeStorage: () async => minimumStorage + 1,
    );

    final result = await eligibility.refreshEligibility();

    expect(result.isEligible, isTrue);
  });

  test('rejects less than 2 GB of free persistent storage', () async {
    final eligibility = service(
      totalRam: () async => 4.0,
      freeStorage: () async => minimumStorage - 1,
    );

    final result = await eligibility.refreshEligibility();

    expect(result.status, DeviceEligibilityStatus.insufficientStorage);
  });

  test('accepts exactly 2 GB of free persistent storage', () async {
    final eligibility = service(
      totalRam: () async => 4.0,
      freeStorage: () async => minimumStorage,
    );

    final result = await eligibility.refreshEligibility();

    expect(result.status, DeviceEligibilityStatus.eligible);
  });

  test('handles unknown total RAM safely', () async {
    final eligibility = service(
      totalRam: () async => null,
      freeStorage: () async => minimumStorage,
    );

    final result = await eligibility.refreshEligibility();

    expect(result.status, DeviceEligibilityStatus.unavailable);
    expect(result.canRetry, isTrue);
  });

  test('handles unknown persistent storage safely', () async {
    final eligibility = service(
      totalRam: () async => 4.0,
      freeStorage: () async => null,
    );

    final result = await eligibility.refreshEligibility();

    expect(result.status, DeviceEligibilityStatus.unavailable);
    expect(result.canRetry, isTrue);
  });
}
