import 'package:get/get.dart';

import 'device_info_service.dart';
import 'download_service.dart';

typedef TotalRamReader = Future<double?> Function();
typedef FreeStorageReader = Future<int?> Function();

enum DeviceEligibilityStatus {
  checking,
  eligible,
  insufficientRam,
  insufficientStorage,
  unavailable,
}

class DeviceEligibilityResult {
  const DeviceEligibilityResult({
    required this.status,
    this.totalRamGb,
    this.freeStorageBytes,
  });

  final DeviceEligibilityStatus status;
  final double? totalRamGb;
  final int? freeStorageBytes;

  bool get isEligible => status == DeviceEligibilityStatus.eligible;

  bool get canRetry =>
      status == DeviceEligibilityStatus.insufficientStorage ||
      status == DeviceEligibilityStatus.unavailable;

  String get message {
    switch (status) {
      case DeviceEligibilityStatus.checking:
        return 'Checking whether this device can run local AI.';
      case DeviceEligibilityStatus.eligible:
        return 'This device is ready for local AI.';
      case DeviceEligibilityStatus.insufficientRam:
        return 'This device needs at least 2 GB of memory for local AI.';
      case DeviceEligibilityStatus.insufficientStorage:
        return 'Free at least 2 GB of storage to use local AI.';
      case DeviceEligibilityStatus.unavailable:
        return 'MaxAI could not check this device\'s resources.';
    }
  }

  String get detailMessage {
    switch (status) {
      case DeviceEligibilityStatus.insufficientRam:
        return totalRamGb == null
            ? ''
            : '${totalRamGb!.toStringAsFixed(1)} GB memory is available; 2 GB is required.';
      case DeviceEligibilityStatus.insufficientStorage:
        return freeStorageBytes == null
            ? ''
            : '${DownloadService.formatBytes(freeStorageBytes!)} free; at least 2 GB is required.';
      case DeviceEligibilityStatus.unavailable:
        return 'Try again after device resources become available.';
      case DeviceEligibilityStatus.checking:
      case DeviceEligibilityStatus.eligible:
        return '';
    }
  }
}

/// Enforces the device-wide minimum before local model selection or download.
class DeviceEligibilityService extends GetxService {
  DeviceEligibilityService({
    TotalRamReader? totalRamReader,
    FreeStorageReader? freeStorageReader,
  })  : _totalRamReader = totalRamReader,
        _freeStorageReader = freeStorageReader;

  static const minimumTotalRamGb = 2.0;
  static const minimumFreeStorageBytes = 2 * 1024 * 1024 * 1024;

  final TotalRamReader? _totalRamReader;
  final FreeStorageReader? _freeStorageReader;

  final status = DeviceEligibilityStatus.checking.obs;
  final totalRamGb = RxnDouble();
  final freeStorageBytes = RxnInt();
  final statusMessage = 'Checking whether this device can run local AI.'.obs;
  final detailMessage = ''.obs;

  bool get isEligible => status.value == DeviceEligibilityStatus.eligible;
  bool get canRetry => currentResult.canRetry;

  DeviceEligibilityResult get currentResult => DeviceEligibilityResult(
        status: status.value,
        totalRamGb: totalRamGb.value,
        freeStorageBytes: freeStorageBytes.value,
      );

  Future<DeviceEligibilityService> init() async {
    await refreshEligibility();
    return this;
  }

  Future<DeviceEligibilityResult> refreshEligibility() async {
    _apply(const DeviceEligibilityResult(
      status: DeviceEligibilityStatus.checking,
    ));

    double? totalRam;
    try {
      totalRam = await (_totalRamReader ?? _readTotalRam)();
    } catch (_) {
      totalRam = null;
    }

    if (totalRam == null || !totalRam.isFinite || totalRam < 0) {
      return _apply(const DeviceEligibilityResult(
        status: DeviceEligibilityStatus.unavailable,
      ));
    }
    if (totalRam < minimumTotalRamGb) {
      return _apply(DeviceEligibilityResult(
        status: DeviceEligibilityStatus.insufficientRam,
        totalRamGb: totalRam,
      ));
    }

    int? freeStorage;
    try {
      freeStorage = await (_freeStorageReader ?? _readFreeStorage)();
    } catch (_) {
      freeStorage = null;
    }

    if (freeStorage == null || freeStorage < 0) {
      return _apply(DeviceEligibilityResult(
        status: DeviceEligibilityStatus.unavailable,
        totalRamGb: totalRam,
      ));
    }
    if (freeStorage < minimumFreeStorageBytes) {
      return _apply(DeviceEligibilityResult(
        status: DeviceEligibilityStatus.insufficientStorage,
        totalRamGb: totalRam,
        freeStorageBytes: freeStorage,
      ));
    }

    return _apply(DeviceEligibilityResult(
      status: DeviceEligibilityStatus.eligible,
      totalRamGb: totalRam,
      freeStorageBytes: freeStorage,
    ));
  }

  Future<double?> _readTotalRam() async {
    final deviceInfo = Get.find<DeviceInfoService>();
    await deviceInfo.refreshMemoryInfo();
    if (!deviceInfo.hasTotalRamMeasurement.value) return null;
    return deviceInfo.totalRamGB.value;
  }

  Future<int?> _readFreeStorage() =>
      Get.find<DownloadService>().getAvailableStorageBytes();

  DeviceEligibilityResult _apply(DeviceEligibilityResult result) {
    status.value = result.status;
    totalRamGb.value = result.totalRamGb;
    freeStorageBytes.value = result.freeStorageBytes;
    statusMessage.value = result.message;
    detailMessage.value = result.detailMessage;
    return result;
  }
}
