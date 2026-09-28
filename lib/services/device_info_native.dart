import 'dart:io';


/// Detected SoC family.
enum SocFamily {
  snapdragon,
  mediatek,
  exynos,
  googleTensor,
  unisoc,
  rockchip,
  hisilicon,
  unknown,
}

extension SocFamilyExt on SocFamily {
  String get displayName {
    switch (this) {
      case SocFamily.snapdragon:
        return 'Qualcomm Snapdragon';
      case SocFamily.mediatek:
        return 'MediaTek Dimensity';
      case SocFamily.exynos:
        return 'Samsung Exynos';
      case SocFamily.googleTensor:
        return 'Google Tensor';
      case SocFamily.unisoc:
        return 'Unisoc';
      case SocFamily.rockchip:
        return 'Rockchip';
      case SocFamily.hisilicon:
        return 'Huawei Kirin';
      case SocFamily.unknown:
        return 'Unknown';
    }
  }

  String get recommendedQuant {
    switch (this) {
      case SocFamily.snapdragon:
        return 'Q4_K_M (recommended) · Q4_0_4_8 on X Elite';
      case SocFamily.mediatek:
        return 'Q4_K_M (recommended)';
      case SocFamily.exynos:
        return 'Q4_K_M (recommended)';
      case SocFamily.googleTensor:
        return 'Q4_0 or Q5_K_M · AVOID Q4_K_M';
      case SocFamily.unisoc:
        return 'Q4_K_M (recommended)';
      case SocFamily.rockchip:
        return 'Q4_K_M (recommended)';
      case SocFamily.hisilicon:
        return 'Q4_K_M (recommended)';
      case SocFamily.unknown:
        return 'Q4_K_M (universal default)';
    }
  }

  String? get quantWarning {
    switch (this) {
      case SocFamily.googleTensor:
        return 'Google Tensor has a known bug with Q4_K_M quantization that produces empty or garbled responses. Use Q4_0 or Q5_K_M models instead.';
      default:
        return null;
    }
  }
}

SocFamily _detectSocFamily(String cpuinfo, String hardware) {
  final lower = cpuinfo.toLowerCase();
  final hwLower = hardware.toLowerCase();

  // Google Tensor (Pixel 6/7/8/9)
  if (RegExp(r'gs\d{3}').hasMatch(hwLower) || lower.contains('google tensor')) {
    return SocFamily.googleTensor;
  }

  // Qualcomm Snapdragon
  if (hwLower.contains('qcom') ||
      hwLower.contains('qualcomm') ||
      hwLower.contains('snapdragon') ||
      RegExp(r'\bsm\d{4,}').hasMatch(hwLower) ||
      lower.contains('snapdragon')) {
    return SocFamily.snapdragon;
  }

  // MediaTek Dimensity / Helio
  if (hwLower.contains('mt6') ||
      hwLower.contains('mt8') ||
      lower.contains('mediatek') ||
      lower.contains('dimensity') ||
      lower.contains('helio')) {
    return SocFamily.mediatek;
  }

  // Samsung Exynos
  if (hwLower.contains('exynos') || lower.contains('exynos')) {
    return SocFamily.exynos;
  }

  // Unisoc
  if (hwLower.contains('unisoc') ||
      hwLower.contains('spreadtrum') ||
      RegExp(r'\bsc\d{4}').hasMatch(hwLower)) {
    return SocFamily.unisoc;
  }

  // Rockchip
  if (hwLower.contains('rockchip') || RegExp(r'\brk\d').hasMatch(hwLower)) {
    return SocFamily.rockchip;
  }

  // Huawei Hisilicon / Kirin
  if (hwLower.contains('hisilicon') ||
      lower.contains('kirin') ||
      lower.contains('hisi')) {
    return SocFamily.hisilicon;
  }

  return SocFamily.unknown;
}

/// Android device information implementation.
Future<Map<String, dynamic>> getDeviceInfo() async {
  double? totalRam;
  double? availableRam;
  var hasAvailableRamMeasurement = false;
  SocFamily socFamily = SocFamily.unknown;
  String hardware = '';

  try {
    if (Platform.isAndroid) {
      final meminfo = await File('/proc/meminfo').readAsString();
      final totalMatch = RegExp(r'MemTotal:\s+(\d+)').firstMatch(meminfo);
      final availMatch = RegExp(r'MemAvailable:\s+(\d+)').firstMatch(meminfo);
      if (totalMatch != null) {
        totalRam = int.parse(totalMatch.group(1)!) / 1024 / 1024;
      }
      if (availMatch != null) {
        availableRam = int.parse(availMatch.group(1)!) / 1024 / 1024;
        hasAvailableRamMeasurement = availableRam >= 0;
      }

      // Detect SoC family from /proc/cpuinfo
      try {
        final cpuinfo = await File('/proc/cpuinfo').readAsString();
        hardware = RegExp(r'Hardware\s*:\s*(.+)', caseSensitive: false)
                .firstMatch(cpuinfo)
                ?.group(1)
                ?.trim() ??
            '';
        socFamily = _detectSocFamily(cpuinfo, hardware);
      } catch (_) {}
    }
  } catch (e) {
    print('[DeviceInfo] Failed to read device info: $e');
  }

  return {
    'totalRamGB': totalRam,
    'availableRamGB': availableRam,
    'hasAvailableRamMeasurement': hasAvailableRamMeasurement,
    'isTensorSoC': socFamily == SocFamily.googleTensor ? 1.0 : 0.0,
    'socFamily': socFamily.index,
    'socHardware': hardware,
  };
}
