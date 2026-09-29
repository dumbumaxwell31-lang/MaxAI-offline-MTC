import 'package:flutter_test/flutter_test.dart';
import 'package:maxai/services/device_eligibility_service.dart';

void main() {
  DeviceEligibilityService service({
    required Future<double?> Function() totalRam,
    required Future<int?> Function() freeStorage,
  }) {
    return DeviceEligibilityService(
      totalRamReader: totalRam,
      freeStorageReader: freeStorage,
    );
  }

  test('does not impose a device-wide RAM or storage minimum on Lite',
      () async {
    var checkedStorage = false;
    final eligibility = service(
      totalRam: () async => 1.5,
      freeStorage: () async {
        checkedStorage = true;
        return 0;
      },
    );

    final result = await eligibility.refreshEligibility();

    expect(result.isEligible, isTrue);
    expect(result.totalRamGb, 1.5);
    expect(checkedStorage, isFalse);
  });

  test('requires 4 GB physical RAM for Pro and rejects below threshold',
      () async {
    final eligibility = service(
      totalRam: () async => 3.99,
      freeStorage: () async => null,
    );

    final result = await eligibility.refreshEligibility(requiredRamGb: 4);

    expect(result.status, DeviceEligibilityStatus.insufficientRam);
    expect(result.message, contains('4GB'));
  });

  test('allows Pro at exactly 4 GB physical RAM', () async {
    final eligibility = service(
      totalRam: () async => 4,
      freeStorage: () async => null,
    );

    final result = await eligibility.refreshEligibility(requiredRamGb: 4);

    expect(result.isEligible, isTrue);
    expect(result.totalRamGb, 4);
  });

  test('locks Pro if physical RAM cannot be verified', () async {
    final eligibility = service(
      totalRam: () async => null,
      freeStorage: () async => null,
    );

    final result = await eligibility.refreshEligibility(requiredRamGb: 4);

    expect(result.status, DeviceEligibilityStatus.unavailable);
    expect(result.canRetry, isTrue);
  });

  test('requires the full per-download storage amount', () async {
    const requiredStorage = 3 * 1024 * 1024 * 1024;
    final lowStorage = service(
      totalRam: () async => null,
      freeStorage: () async => requiredStorage - 1,
    );
    final enoughStorage = service(
      totalRam: () async => null,
      freeStorage: () async => requiredStorage,
    );

    expect(
      (await lowStorage.refreshEligibility(
        requiredStorageBytes: requiredStorage,
      ))
          .status,
      DeviceEligibilityStatus.insufficientStorage,
    );
    expect(
      (await enoughStorage.refreshEligibility(
        requiredStorageBytes: requiredStorage,
      ))
          .isEligible,
      isTrue,
    );
  });
}
