import 'package:get/get.dart';

import '../core/constants.dart';
import '../models/ai_model.dart';
import 'app_log_service.dart';
import 'device_info_service.dart';
import 'download_service.dart';
import 'hive_service.dart';

typedef AvailableRamReader = Future<double?> Function();
typedef TotalRamReader = Future<double?> Function();
typedef AvailableModelStorageReader = Future<int?> Function();

enum RamDetectionStatus { detected, unavailable }

/// Metadata for one supported GGUF option in the local model hub.
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
    this.minimumTotalRamGb = 0,
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
  final double minimumTotalRamGb;
  final int maxContextSize;
  final int maxOutputTokens;

  bool get requiresProHardware => minimumTotalRamGb > 0;

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

class AutomaticModelPolicy {
  AutomaticModelPolicy._();

  static const proMinimumTotalRamGb = 4.0;

  /// Android reports less RAM than the advertised size (a 6 GB phone reports
  /// about 5.2 GB, an 8 GB phone about 7.2-7.7 GB). Below this reported value
  /// the phone is advertised as less than 8 GB, and MaxPro models run very
  /// slowly because the model does not fit in free memory.
  static const proComfortableTotalRamGb = 7.0;

  static const proSlowWarning = 'This model will be very slow on your phone.';
  static const temporaryStorageOverheadBytes = 64 * 1024 * 1024;

  static const maxliteModel1 = SelectedLocalModel(
    name: 'Maxlite Model 1',
    identifier: 'maxlite-smollm2-1.7b-q4_k_m',
    filename: 'SmolLM2-1.7B-Instruct-Q4_K_M.gguf',
    quantization: 'Q4_K_M',
    downloadUrl:
        'https://huggingface.co/bartowski/SmolLM2-1.7B-Instruct-GGUF/resolve/3084dd417b5e2567e786340037cd3b512068fad0/SmolLM2-1.7B-Instruct-Q4_K_M.gguf',
    sourceRepository: 'bartowski/SmolLM2-1.7B-Instruct-GGUF',
    sourcePublisher: 'HuggingFaceTB / bartowski',
    licenseSummary: 'Apache-2.0',
    expectedFileSizeBytes: 1055609824,
    expectedFileSizeLabel: '1.06 GB',
    template: 'chatml',
    description: 'Lightweight instruction model for everyday local chat.',
    sha256: '77665ea4815999596525c636fbeb56ba8b080b46ae85efef4f0d986a139834d7',
    minimumAvailableRamGb: 0,
    maxContextSize: 8192,
    maxOutputTokens: 4096,
  );

  static const maxliteModel2 = SelectedLocalModel(
    name: 'Maxlite Model 2',
    identifier: 'maxlite-gemma3-1b-q4_k_m',
    filename: 'google_gemma-3-1b-it-Q4_K_M.gguf',
    quantization: 'Q4_K_M',
    downloadUrl:
        'https://huggingface.co/bartowski/google_gemma-3-1b-it-GGUF/resolve/116f76234503685a98f572982177b11d44ec8ff1/google_gemma-3-1b-it-Q4_K_M.gguf',
    sourceRepository: 'bartowski/google_gemma-3-1b-it-GGUF',
    sourcePublisher: 'Google / bartowski',
    licenseSummary: 'Google Gemma Terms',
    expectedFileSizeBytes: 806058496,
    expectedFileSizeLabel: '806 MB',
    template: 'gemma',
    description: 'Compact instruction model tuned for low-memory devices.',
    sha256: '12bf0fff8815d5f73a3c9b586bd8fee8e7b248c935de70dec367679873d0f29d',
    minimumAvailableRamGb: 0,
    maxContextSize: 8192,
    maxOutputTokens: 4096,
  );

  static const maxproModel1 = SelectedLocalModel(
    name: 'MaxPro Model 1',
    identifier: 'maxpro-phi4-mini-3.8b-q4_k_m',
    filename: 'microsoft_Phi-4-mini-instruct-Q4_K_M.gguf',
    quantization: 'Q4_K_M',
    downloadUrl:
        'https://huggingface.co/bartowski/microsoft_Phi-4-mini-instruct-GGUF/resolve/faffc28d86d0c0781b4ec92d30e400a6d350a53b/microsoft_Phi-4-mini-instruct-Q4_K_M.gguf',
    sourceRepository: 'bartowski/microsoft_Phi-4-mini-instruct-GGUF',
    sourcePublisher: 'Microsoft / bartowski',
    licenseSummary: 'MIT',
    expectedFileSizeBytes: 2491874688,
    expectedFileSizeLabel: '2.49 GB',
    template: 'chatml',
    description: 'Larger instruction model suited to complex local tasks.',
    sha256: '01999f17c39cc3074afae5e9c539bc82d45f2dd7faa3917c66cbef76fce8c0c2',
    minimumAvailableRamGb: 0,
    minimumTotalRamGb: proMinimumTotalRamGb,
    maxContextSize: 8192,
    maxOutputTokens: 4096,
  );

  static const maxproModel2 = SelectedLocalModel(
    name: 'MaxPro Model 2',
    identifier: 'maxpro-qwen3-4b-q4_k_m',
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
    description: 'Instruction model for technical and multilingual tasks.',
    sha256: '7485fe6f11af29433bc51cab58009521f205840f5b4ae3a32fa7f92e8534fdf5',
    minimumAvailableRamGb: 0,
    minimumTotalRamGb: proMinimumTotalRamGb,
    maxContextSize: 8192,
    maxOutputTokens: 4096,
  );

  static const List<SelectedLocalModel> supportedModels = [
    maxliteModel1,
    maxliteModel2,
    maxproModel1,
    maxproModel2,
  ];

  static int requiredDownloadStorageBytes(SelectedLocalModel model) =>
      model.expectedFileSizeBytes * 2 + temporaryStorageOverheadBytes;

  static SelectedLocalModel? modelForIdentifier(String identifier) {
    for (final model in supportedModels) {
      if (model.identifier == identifier) return model;
    }
    return null;
  }

  static SelectedLocalModel? modelForFilename(String filename) {
    for (final model in supportedModels) {
      if (model.filename == filename) return model;
    }
    return null;
  }

  static String displayNameForFilename(String filename) {
    final selected = modelForFilename(filename);
    if (selected != null) return selected.name;
    if (filename == 'Qwen_Qwen3-0.6B-Q4_K_M.gguf') {
      return 'Maxlite AI Model';
    }
    if (filename == 'Qwen3-4B-Q4_K_M.gguf') return 'MaxPro AI Model';
    final basename = filename.split(RegExp(r'[/\\]')).last;
    return basename.replaceFirst(RegExp(r'\.gguf$', caseSensitive: false), '');
  }
}

/// Tracks physical resources and the user's active model choice.
class ModelSelectionService extends GetxService {
  ModelSelectionService({
    AvailableRamReader? availableRamReader,
    TotalRamReader? totalRamReader,
    AvailableModelStorageReader? availableStorageReader,
  })  : _availableRamReader = availableRamReader,
        _totalRamReader = totalRamReader,
        _availableStorageReader = availableStorageReader;

  static const selectedModelSettingKey = 'selected_local_model_identifier';

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
    await refreshHardwareInfo();
    final hive =
        Get.isRegistered<HiveService>() ? Get.find<HiveService>() : null;
    var identifier = hive?.getSetting<String>(selectedModelSettingKey);
    identifier ??= _legacySelectionIdentifier(hive?.getSetting<String>(
      AppConstants.keyLocalModelName,
    ));

    var selected = identifier == null
        ? AutomaticModelPolicy.maxliteModel1
        : AutomaticModelPolicy.modelForIdentifier(identifier);
    selected ??= AutomaticModelPolicy.maxliteModel1;

    if (!isModelCompatible(selected)) {
      selected = AutomaticModelPolicy.maxliteModel1;
      selectionMessage.value = _proCompatibilityMessage();
    } else {
      selectionMessage.value = '${selected.name} selected for this device.';
    }
    selectedModel.value = selected;
    await hive?.setSetting(selectedModelSettingKey, selected.identifier);
    _logSelection();
  }

  Future<void> refreshHardwareInfo() async {
    double? measuredTotal;
    double? measuredAvailable;
    int? measuredStorage;
    try {
      measuredTotal = await (_totalRamReader ?? _readTotalRam)();
    } catch (_) {}
    try {
      measuredAvailable = await (_availableRamReader ?? _readAvailableRam)();
    } catch (_) {}
    try {
      measuredStorage =
          await (_availableStorageReader ?? _readAvailableStorage)();
    } catch (_) {}

    totalRamGb.value = _validRam(measuredTotal);
    availableRamGb.value = _validRam(measuredAvailable);
    freeStorageBytes.value = measuredStorage != null && measuredStorage >= 0
        ? measuredStorage
        : null;
    ramDetectionStatus.value = totalRamGb.value == null
        ? RamDetectionStatus.unavailable
        : RamDetectionStatus.detected;
  }

  bool isModelCompatible(SelectedLocalModel model) {
    if (!model.requiresProHardware) return true;
    final ram = totalRamGb.value;
    return ram != null && ram.isFinite && ram >= model.minimumTotalRamGb;
  }

  /// True for MaxPro models on phones with at least 4 GB but less than an
  /// advertised 8 GB of RAM.
  bool isSlowOnThisDevice(SelectedLocalModel model) {
    if (!model.requiresProHardware || !isModelCompatible(model)) return false;
    final ram = totalRamGb.value!;
    return ram < AutomaticModelPolicy.proComfortableTotalRamGb;
  }

  String compatibilityMessage(SelectedLocalModel model) {
    if (!model.requiresProHardware) return '';
    final ram = totalRamGb.value;
    if (ram == null || !ram.isFinite) {
      return 'MaxAI could not verify physical RAM. MaxPro models require at least 4 GB of physical RAM.';
    }
    return ram < model.minimumTotalRamGb
        ? 'Requires at least 4GB RAM. Incompatible with this device.'
        : '';
  }

  Future<bool> selectModel(String identifier) async {
    await refreshHardwareInfo();
    final model = AutomaticModelPolicy.modelForIdentifier(identifier);
    if (model == null) {
      selectionMessage.value = 'This model is not supported.';
      return false;
    }
    if (!isModelCompatible(model)) {
      selectionMessage.value = compatibilityMessage(model);
      return false;
    }

    selectedModel.value = model;
    selectionMessage.value = '${model.name} is selected.';
    if (Get.isRegistered<HiveService>()) {
      await Get.find<HiveService>()
          .setSetting(selectedModelSettingKey, model.identifier);
    }
    return true;
  }

  String? _legacySelectionIdentifier(String? filename) {
    if (filename == 'Qwen_Qwen3-0.6B-Q4_K_M.gguf') {
      return AutomaticModelPolicy.maxliteModel1.identifier;
    }
    if (filename == 'Qwen3-4B-Q4_K_M.gguf') {
      return AutomaticModelPolicy.maxproModel2.identifier;
    }
    return null;
  }

  double? _validRam(double? value) =>
      value != null && value.isFinite && value >= 0 ? value : null;

  Future<double?> _readAvailableRam() async {
    final deviceInfo = Get.find<DeviceInfoService>();
    if (!deviceInfo.hasAvailableRamMeasurement.value) return null;
    return deviceInfo.availableRamGB.value;
  }

  Future<double?> _readTotalRam() async {
    final deviceInfo = Get.find<DeviceInfoService>();
    await deviceInfo.refreshMemoryInfo();
    if (!deviceInfo.hasTotalRamMeasurement.value) return null;
    return deviceInfo.totalRamGB.value;
  }

  Future<int?> _readAvailableStorage() =>
      Get.find<DownloadService>().getAvailableStorageBytes();

  String _proCompatibilityMessage() {
    final ram = totalRamGb.value;
    if (ram == null) {
      return 'Maxlite Model 1 selected. Physical RAM could not be verified; MaxPro models remain locked.';
    }
    return 'Maxlite Model 1 selected. MaxPro models require at least 4GB physical RAM.';
  }

  void _logSelection() {
    if (!Get.isRegistered<AppLogService>()) return;
    final selected = selectedModel.value;
    if (selected == null) return;
    final ram = totalRamGb.value;
    Get.find<AppLogService>().info(
      '[ModelSelection] ${selected.identifier}; total RAM: '
      '${ram == null ? 'unavailable' : '${ram.toStringAsFixed(2)} GB'}',
    );
  }
}
