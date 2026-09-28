import 'dart:io' show Platform;

import 'package:device_info_plus/device_info_plus.dart';
import 'package:get/get.dart';

import 'device_info_native.dart' as platform_info;
import 'inference_resource_policy.dart';

/// Device capability detection — reads RAM to set safe inference limits.
class DeviceInfoService extends GetxService {
  final totalRamGB = 0.0.obs;
  final availableRamGB = 0.0.obs;
  final hasTotalRamMeasurement = false.obs;
  final hasAvailableRamMeasurement = false.obs;
  final deviceTier = ''.obs; // 'low', 'mid', 'high', 'ultra'
  final isTensorSoC = false.obs;
  final socFamily = platform_info.SocFamily.unknown.obs;
  final socHardware = ''.obs;
  final androidVersion = ''.obs;
  final androidApiLevel = 0.obs;
  final cpuArchitecture = ''.obs;
  final cpuCoreCount = 0.obs;
  final deviceName = ''.obs;

  InferenceResourceLimits get recommendedInferenceLimits =>
      InferenceResourcePolicy.forAvailableRam(
        availableRamGb:
            hasAvailableRamMeasurement.value ? availableRamGB.value : null,
        modelContextLimit: 8192,
        modelOutputLimit: 4096,
      );

  int get recommendedContextSize => recommendedInferenceLimits.contextSize;
  int get recommendedMaxTokens => recommendedInferenceLimits.maxOutputTokens;
  int get maxSafeContextSize => recommendedContextSize;
  int get maxSafeTokens => recommendedMaxTokens;
  String? get inferenceLimitNotice => recommendedInferenceLimits.explanation;

  Future<DeviceInfoService> init() async {
    await refreshMemoryInfo();
    await refreshPlatformInfo();

    // Classify device tier
    final ram = totalRamGB.value;
    if (ram <= 4) {
      deviceTier.value = 'low';
    } else if (ram <= 6) {
      deviceTier.value = 'mid';
    } else if (ram <= 8) {
      deviceTier.value = 'high';
    } else {
      deviceTier.value = 'ultra';
    }

    print('[DeviceInfo] RAM: ${totalRamGB.value.toStringAsFixed(1)}GB total, '
        '${availableRamGB.value.toStringAsFixed(1)}GB available, '
        'tier: ${deviceTier.value}, tensor: ${isTensorSoC.value}');
    return this;
  }

  Future<void> refreshPlatformInfo() async {
    cpuCoreCount.value = Platform.numberOfProcessors;
    if (!Platform.isAndroid) return;

    try {
      final info = await DeviceInfoPlugin().androidInfo;
      androidVersion.value = info.version.release;
      androidApiLevel.value = info.version.sdkInt;
      cpuArchitecture.value =
          info.supportedAbis.isEmpty ? '' : info.supportedAbis.first;
      deviceName.value = '${info.manufacturer} ${info.model}'.trim();
    } catch (_) {
      androidVersion.value = '';
      androidApiLevel.value = 0;
      cpuArchitecture.value = '';
      deviceName.value = '';
    }
  }

  Future<void> refreshMemoryInfo() async {
    try {
      final info = await platform_info.getDeviceInfo();
      final totalRam = info['totalRamGB'] as num?;
      final availableRam = info['availableRamGB'] as num?;
      totalRamGB.value = totalRam?.toDouble() ?? 0;
      availableRamGB.value = availableRam?.toDouble() ?? 0;
      hasTotalRamMeasurement.value = totalRam != null && totalRamGB.value >= 0;
      hasAvailableRamMeasurement.value =
          (info['hasAvailableRamMeasurement'] as bool? ?? false) &&
              availableRam != null &&
              availableRamGB.value >= 0;
      isTensorSoC.value = (info['isTensorSoC'] as num? ?? 0.0) > 0.5;
      final rawIndex = (info['socFamily'] as num? ?? 7).toInt();
      final clamped = rawIndex < 0 ? 0 : (rawIndex > 7 ? 7 : rawIndex);
      socFamily.value = platform_info.SocFamily.values[clamped];
      socHardware.value = (info['socHardware'] as String?) ?? '';
    } catch (_) {
      totalRamGB.value = 0;
      availableRamGB.value = 0;
      hasTotalRamMeasurement.value = false;
      hasAvailableRamMeasurement.value = false;
      isTensorSoC.value = false;
      socFamily.value = platform_info.SocFamily.unknown;
      socHardware.value = '';
    }
  }

  String get tierDescription {
    switch (deviceTier.value) {
      case 'low':
        return '⚠️ Low RAM (${totalRamGB.value.toStringAsFixed(1)}GB) — Use small models only';
      case 'mid':
        return '📱 Mid-range (${totalRamGB.value.toStringAsFixed(1)}GB) — Good for 1-3B models';
      case 'high':
        return '💪 High-end (${totalRamGB.value.toStringAsFixed(1)}GB) — Can run 3-7B models';
      case 'ultra':
        return '🚀 Ultra (${totalRamGB.value.toStringAsFixed(1)}GB) — Full performance mode';
      default:
        return '📱 ${totalRamGB.value.toStringAsFixed(1)}GB RAM detected';
    }
  }
}
