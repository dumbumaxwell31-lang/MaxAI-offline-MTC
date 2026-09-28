import 'package:get/get.dart';
import '../models/ai_model.dart';
import 'app_log_service.dart';
import 'device_eligibility_service.dart';
import 'device_info_service.dart';
import 'download_service.dart';

typedef AvailableRamReader = Future<double?> Function();
typedef TotalRamReader = Future<double?> Function();
typedef AvailableModelStorageReader = Future<int?> Function();

enum RamDetectionStatus { detected, unavailable }

/// Immutable metadata for one supported automatic local-model tier.
class SelectedLocalModel {
  const SelectedLocalModel({
    required this.name,
    required this.identifier,
    required this.filename,
    required this.quantization,
    required this.downloadUrl,
    required this.sourceRepository,
    required this.sourcePublisher,
    required this.licenseSummary,
    required this.expectedFileSizeBytes,
    required this.expectedFileSizeLabel,
    required this.template,
    required this.description,
    required this.sha256,
    required this.minimumAvailableRamGb,
    required this.maxContextSize,
    required this.maxOutputTokens,
  });

  final String name;
  final String identifier;
  final String filename;
  final String quantization;
  final String downloadUrl;
  final String sourceRepository;
  final String sourcePublisher;
  final String licenseSummary;
  final int expectedFileSizeBytes;
  final String expectedFileSizeLabel;
  final String template;
  final String description;
  final String sha256;
  final double minimumAvailableRamGb;
  final int maxContextSize;
  final int maxOutputTokens;

  AiModel toAiModel() => AiModel(
        name: name,
        filename: filename,
        url: downloadUrl,
        size: expectedFileSizeLabel,
        description:
            '$description $quantization quantization, expected file size $expectedFileSizeLabel.',
        template: template,
        runtime: AiModel.runtimeLlama,
      );
}

/// Pure two-tier policy. It deliberately returns one model, never a list of
/// choices for the user interface.
class AutomaticModelPolicy {
  AutomaticModelPolicy._();

  static const ramThresholdGb = 6.0;
  static const minimumLiteAvailableRamGb = 0.0;
  static const minimumProAvailableRamGb = 4.5;
  static const temporaryStorageOverheadBytes = 64 * 1024 * 1024;

  static const maxAiLite = SelectedLocalModel(
    name: 'Maxlite AI Model',
    identifier: 'qwen3-0.6b-q4_k_m',
    filename: 'Qwen_Qwen3-0.6B-Q4_K_M.gguf',
    quantization: 'Q4_K_M',
    downloadUrl:
        'https://huggingface.co/bartowski/Qwen_Qwen3-0.6B-GGUF/resolve/7bcae0bc7b0606f1e948f8cdb31b98a2c10635db/Qwen_Qwen3-0.6B-Q4_K_M.gguf',
    sourceRepository: 'bartowski/Qwen_Qwen3-0.6B-GGUF',
    sourcePublisher: 'bartowski',
    licenseSummary: 'Apache-2.0 (Qwen3-0.6B base model)',
    expectedFileSizeBytes: 484220320,
    expectedFileSizeLabel: '484 MB',
    template: 'chatml',
    description: 'Maxlite AI Model for devices with limited memory.',
    sha256: '9acfc1e001311f34b4252001b626f2e466d592a42065f66571bff3790d4e1b14',
    minimumAvailableRamGb: minimumLiteAvailableRamGb,
    maxContextSize: 8192,
    maxOutputTokens: 4096,
  );

  static const maxAiPro = SelectedLocalModel(
    name: 'MaxPro AI Model',
    identifier: 'qwen3-4b-q4_k_m',
    filename: 'Qwen3-4B-Q4_K_M.gguf',
    quantization: 'Q4_K_M',
    downloadUrl:
        'https://huggingface.co/Qwen/Qwen3-4B-GGUF/resolve/a9a60d009fa7ff9606305047c2bf77ac25dbec49/Qwen3-4B-Q4_K_M.gguf',
    sourceRepository: 'Qwen/Qwen3-4B-GGUF',
    sourcePublisher: 'Qwen',
    licenseSummary: 'Apache-2.0',
    expectedFileSizeBytes: 2497280256,
    expectedFileSizeLabel: '2.50 GB',
    template: 'chatml',
    description: 'MaxPro AI Model for devices with higher resource headroom.',
    sha256: '7485fe6f11af29433bc51cab58009521f205840f5b4ae3a32fa7f92e8534fdf5',
    minimumAvailableRamGb: minimumProAvailableRamGb,
    maxContextSize: 8192,
    maxOutputTokens: 4096,
  );

  static int requiredDownloadStorageBytes(SelectedLocalModel model) =>
      model.expectedFileSizeBytes * 2 + temporaryStorageOverheadBytes;

  static String displayNameForFilename(String filename) {
    if (filename == maxAiLite.filename || filename == maxAiLite.identifier) {
      return maxAiLite.name;
    }
    if (filename == maxAiPro.filename || filename == maxAiPro.identifier) {
      return maxAiPro.name;
    }
    final basename = filename.split(RegExp(r'[/\\]')).last;
    return basename.replaceFirst(RegExp(r'\.gguf$', caseSensitive: false), '');
  }

  static SelectedLocalModel? selectForHardware({
    required double? totalRamGb,
    required double? availableRamGb,
    required int? freeStorageBytes,
  }) {
    if (totalRamGb == null || !totalRamGb.isFinite || totalRamGb < 2.0) {
      return null;
    }
    if (freeStorageBytes == null ||
        freeStorageBytes < requiredDownloadStorageBytes(maxAiLite)) {
      return null;
    }

    final hasAvailableRam = availableRamGb != null &&
        availableRamGb.isFinite &&
        availableRamGb >= 0;
    final canRunPro = totalRamGb >= ramThresholdGb &&
        hasAvailableRam &&
        availableRamGb >= minimumProAvailableRamGb &&
        freeStorageBytes >= requiredDownloadStorageBytes(maxAiPro);
    if (canRunPro) return maxAiPro;
    return maxAiLite;
  }
}

/// Reads device resources and exposes only the automatically selected model.
class ModelSelectionService extends GetxService {
  ModelSelectionService({
    AvailableRamReader? availableRamReader,
    TotalRamReader? totalRamReader,
    AvailableModelStorageReader? availableStorageReader,
  })  : _availableRamReader = availableRamReader,
        _totalRamReader = totalRamReader,
        _availableStorageReader = availableStorageReader;

  final AvailableRamReader? _availableRamReader;
  final TotalRamReader? _totalRamReader;
  final AvailableModelStorageReader? _availableStorageReader;

  final selectedModel = Rxn<SelectedLocalModel>();
  final totalRamGb = RxnDouble();
  final availableRamGb = RxnDouble();
  final freeStorageBytes = RxnInt();
  final ramDetectionStatus = RamDetectionStatus.unavailable.obs;
  final selectionMessage = 'Checking device resources.'.obs;

  bool get hasAvailableRamMeasurement =>
      ramDetectionStatus.value == RamDetectionStatus.detected;

  Future<ModelSelectionService> init() async {
    await refreshSelection();
    return this;
  }

  Future<void> refreshSelection() async {
    DeviceEligibilityResult? eligibilityResult;
    if (Get.isRegistered<DeviceEligibilityService>()) {
      final eligibility = Get.find<DeviceEligibilityService>();
      final result = await eligibility.refreshEligibility();
      eligibilityResult = result;
      if (!result.isEligible) {
        selectedModel.value = null;
        totalRamGb.value = result.totalRamGb;
        availableRamGb.value = null;
        freeStorageBytes.value = result.freeStorageBytes;
        ramDetectionStatus.value = RamDetectionStatus.unavailable;
        selectionMessage.value = result.message;
        return;
      }
    }

    double? measuredTotalRamGb = eligibilityResult?.totalRamGb;
    double? measuredRamGb;
    int? measuredStorageBytes = eligibilityResult?.freeStorageBytes;
    try {
      measuredRamGb = await (_availableRamReader ?? _readAvailableRam)();
    } catch (_) {
      measuredRamGb = null;
    }
    try {
      measuredTotalRamGb ??= await (_totalRamReader ?? _readTotalRam)();
    } catch (_) {
      measuredTotalRamGb = null;
    }
    try {
      measuredStorageBytes ??=
          await (_availableStorageReader ?? _readAvailableStorage)();
    } catch (_) {
      measuredStorageBytes = null;
    }

    final hasMeasurement =
        measuredRamGb != null && measuredRamGb.isFinite && measuredRamGb >= 0;
    totalRamGb.value = measuredTotalRamGb;
    availableRamGb.value = hasMeasurement ? measuredRamGb : null;
    freeStorageBytes.value = measuredStorageBytes;
    ramDetectionStatus.value = hasMeasurement
        ? RamDetectionStatus.detected
        : RamDetectionStatus.unavailable;
    final selected = AutomaticModelPolicy.selectForHardware(
      totalRamGb: totalRamGb.value,
      availableRamGb: availableRamGb.value,
      freeStorageBytes: freeStorageBytes.value,
    );
    selectedModel.value = selected;
    selectionMessage.value = selected == null
        ? 'MaxAI could not verify the minimum device memory or free storage required for local AI.'
        : selected == AutomaticModelPolicy.maxAiPro
            ? '${AutomaticModelPolicy.maxAiPro.name} selected automatically for this device.'
            : !hasMeasurement
                ? '${AutomaticModelPolicy.maxAiLite.name} selected automatically. Available RAM could not be measured, so a conservative inference configuration will be tried.'
                : measuredRamGb < 1.0
                    ? '${AutomaticModelPolicy.maxAiLite.name} selected automatically. Current memory pressure will use a smaller inference configuration.'
                    : '${AutomaticModelPolicy.maxAiLite.name} selected automatically for this device.';

    _logSelection();
  }

  Future<double?> _readAvailableRam() async {
    final deviceInfo = Get.find<DeviceInfoService>();
    if (!deviceInfo.hasAvailableRamMeasurement.value) {
      return null;
    }
    return deviceInfo.availableRamGB.value;
  }

  Future<double?> _readTotalRam() async {
    final deviceInfo = Get.find<DeviceInfoService>();
    if (!deviceInfo.hasTotalRamMeasurement.value) return null;
    return deviceInfo.totalRamGB.value;
  }

  Future<int?> _readAvailableStorage() =>
      Get.find<DownloadService>().getAvailableStorageBytes();

  void _logSelection() {
    if (!Get.isRegistered<AppLogService>()) return;
    final selected = selectedModel.value;
    if (selected == null) return;
    final ram = availableRamGb.value;
    final source = ram == null
        ? 'available RAM unavailable; conservative fallback'
        : '${ram.toStringAsFixed(2)} GB available RAM';
    Get.find<AppLogService>().info(
      '[ModelSelection] ${selected.identifier} selected from $source',
    );
  }
}
