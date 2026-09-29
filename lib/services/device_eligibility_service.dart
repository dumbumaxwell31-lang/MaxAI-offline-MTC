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
    this.requiredRamGb = 0,
    this.requiredStorageBytes = 0,
  });

  final DeviceEligibilityStatus status;
  final double? totalRamGb;
  final int? freeStorageBytes;
  final double requiredRamGb;
  final int requiredStorageBytes;

  bool get isEligible => status == DeviceEligibilityStatus.eligible;

  bool get canRetry =>
      status == DeviceEligibilityStatus.insufficientStorage ||
      status == DeviceEligibilityStatus.unavailable;

  String get message {
    switch (status) {
      case DeviceEligibilityStatus.checking:
        return 'Checking device resources.';
      case DeviceEligibilityStatus.eligible:
        return 'This model is compatible with the available device resources.';
      case DeviceEligibilityStatus.insufficientRam:
        return 'Requires at least 4GB RAM. Incompatible with this device.';
      case DeviceEligibilityStatus.insufficientStorage:
        return 'Not enough free storage to download this model safely.';
      case DeviceEligibilityStatus.unavailable:
        return 'MaxAI could not verify the required device resources.';
    }
  }

  String get detailMessage {
    switch (status) {
      case DeviceEligibilityStatus.insufficientRam:
        return totalRamGb == null
            ? 'At least ${requiredRamGb.toStringAsFixed(0)} GB physical RAM is required.'
            : '${totalRamGb!.toStringAsFixed(1)} GB physical RAM detected; '
                '${requiredRamGb.toStringAsFixed(0)} GB is required.';
      case DeviceEligibilityStatus.insufficientStorage:
        if (freeStorageBytes == null) return '';
        return '${DownloadService.formatBytes(freeStorageBytes!)} free; '
            '${DownloadService.formatBytes(requiredStorageBytes)} required.';
      case DeviceEligibilityStatus.unavailable:
        return 'Check storage and device information, then retry.';
      case DeviceEligibilityStatus.checking:
      case DeviceEligibilityStatus.eligible:
        return '';
    }
  }
}

/// Checks per-model hardware requirements and per-download storage needs.
class DeviceEligibilityService extends GetxService {
  DeviceEligibilityService({
    TotalRamReader? totalRamReader,
    FreeStorageReader? freeStorageReader,
  })  : _totalRamReader = totalRamReader,
        _freeStorageReader = freeStorageReader;

  static const minimumTotalRamGb = 4.0;

  final TotalRamReader? _totalRamReader;
  final FreeStorageReader? _freeStorageReader;

  final status = DeviceEligibilityStatus.checking.obs;
  final totalRamGb = RxnDouble();
  final freeStorageBytes = RxnInt();
  final statusMessage = 'Checking device resources.'.obs;
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

  Future<DeviceEligibilityResult> refreshEligibility({
    double requiredRamGb = 0,
    int requiredStorageBytes = 0,
  }) async {
    _apply(const DeviceEligibilityResult(
      status: DeviceEligibilityStatus.checking,
    ));

    double? totalRam;
    try {
      totalRam = await (_totalRamReader ?? _readTotalRam)();
    } catch (_) {}
    if (totalRam != null && (!totalRam.isFinite || totalRam < 0)) {
      totalRam = null;
    }

    if (requiredRamGb > 0) {
      if (totalRam == null) {
        return _apply(DeviceEligibilityResult(
          status: DeviceEligibilityStatus.unavailable,
          requiredRamGb: requiredRamGb,
        ));
      }
      if (totalRam < requiredRamGb) {
        return _apply(DeviceEligibilityResult(
          status: DeviceEligibilityStatus.insufficientRam,
          totalRamGb: totalRam,
          requiredRamGb: requiredRamGb,
        ));
      }
    }

    int? freeStorage;
    if (requiredStorageBytes > 0) {
      try {
        freeStorage = await (_freeStorageReader ?? _readFreeStorage)();
      } catch (_) {}
      if (freeStorage == null || freeStorage < 0) {
        return _apply(DeviceEligibilityResult(
          status: DeviceEligibilityStatus.unavailable,
          totalRamGb: totalRam,
          requiredRamGb: requiredRamGb,
          requiredStorageBytes: requiredStorageBytes,
        ));
      }
      if (freeStorage < requiredStorageBytes) {
        return _apply(DeviceEligibilityResult(
          status: DeviceEligibilityStatus.insufficientStorage,
          totalRamGb: totalRam,
          freeStorageBytes: freeStorage,
          requiredRamGb: requiredRamGb,
          requiredStorageBytes: requiredStorageBytes,
        ));
      }
    }

    return _apply(DeviceEligibilityResult(
      status: DeviceEligibilityStatus.eligible,
      totalRamGb: totalRam,
      freeStorageBytes: freeStorage,
      requiredRamGb: requiredRamGb,
      requiredStorageBytes: requiredStorageBytes,
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
