import 'package:get/get.dart';

import '../services/app_log_service.dart';
import '../services/automatic_model_download_service.dart';
import '../services/device_eligibility_service.dart';
import '../services/download_service.dart';
import '../services/device_info_service.dart';
import '../services/inference_service.dart';
import '../services/model_selection_service.dart';
import 'settings_controller.dart';

/// Coordinates the one automatically selected local GGUF model.
class ModelController extends GetxController {
  final DownloadService _download = Get.find<DownloadService>();
  final InferenceService _inference = Get.find<InferenceService>();
  final SettingsController _settings = Get.find<SettingsController>();
  final ModelSelectionService _selection = Get.find<ModelSelectionService>();
  final AutomaticModelDownloadService _automaticDownloads =
      Get.find<AutomaticModelDownloadService>();
  final DeviceEligibilityService _eligibility =
      Get.find<DeviceEligibilityService>();

  final downloadedFiles = <String>[].obs;
  Worker? _selectionWatcher;

  SelectedLocalModel? get selectedAutomaticModel =>
      _selection.selectedModel.value;
  bool get isSelectedModelReady => _automaticDownloads.isReady;
  int get downloadedCount => downloadedFiles.length;

  @override
  void onInit() {
    super.onInit();
    _selectionWatcher = ever<SelectedLocalModel?>(
      _selection.selectedModel,
      (_) => refreshDownloaded(),
    );
    refreshDownloaded();
  }

  @override
  void onClose() {
    _selectionWatcher?.dispose();
    super.onClose();
  }

  Future<void> refreshDownloaded() async {
    final files = await _download.getDownloadedModels();
    downloadedFiles.value =
        files.where((file) => file.endsWith('.gguf')).toList();
  }

  bool isDownloaded(String filename) {
    final selected = selectedAutomaticModel;
    return selected?.filename == filename && _automaticDownloads.isReady;
  }

  Future<void> retrySelectedModelDownload() async {
    await _automaticDownloads.retrySelectedModelDownload();
    await refreshDownloaded();
  }

  Future<void> loadModel(String filename) async {
    await _selection.refreshSelection();
    final selected = selectedAutomaticModel;
    if (!_eligibility.isEligible) {
      _showStatus('Local AI Unavailable', _eligibility.statusMessage.value);
      return;
    }
    if (selected == null) {
      _showStatus('Local AI Unavailable', _selection.selectionMessage.value);
      return;
    }
    if (filename != selected.filename) {
      _showStatus(
        'Automatic Model Selection',
        'MaxAI can only load the model selected for this device.',
      );
      return;
    }
    if (_inference.isLoadingModel.value) return;

    if (_inference.isModelLoaded.value &&
        _inference.loadedModelName.value == selected.filename) {
      await _settings.setInferenceMode('local');
      _showStatus('Local Model Loaded', '${selected.name} is ready to chat.');
      return;
    }

    await _automaticDownloads.ensureSelectedModel();
    if (!_automaticDownloads.isReady ||
        !await _download.isModelDownloaded(selected.filename)) {
      _showStatus('Model Not Ready', _automaticDownloads.statusMessage.value);
      return;
    }

    final deviceInfo = Get.find<DeviceInfoService>();
    await deviceInfo.refreshMemoryInfo();
    await _loadSelectedModel(selected);
  }

  Future<void> _loadSelectedModel(SelectedLocalModel selected) async {
    final path = await _download.modelPath(selected.filename);
    final result =
        await _inference.loadModel(path, modelName: selected.filename);
    if (_inference.isModelLoaded.value) {
      await _settings.setInferenceMode('local');
      final notice = _inference.resourceConfigurationNotice.value;
      _showStatus(
        'Local Model Loaded',
        notice.isEmpty
            ? '${selected.name} is ready to chat.'
            : '${selected.name} is ready to chat. $notice',
      );
      return;
    }

    Get.find<AppLogService>()
        .error('Selected model failed to load', details: result);
    _showStatus('Model Could Not Load', _friendlyLoadMessage(result));
  }

  Future<void> unloadModel() => _inference.unloadModel();

  void _showStatus(String title, String message) {
    Get.snackbar(title, message, snackPosition: SnackPosition.BOTTOM);
  }

  String _friendlyLoadMessage(String rawError) {
    final error = rawError.toLowerCase();
    if (error.contains('memory') ||
        error.contains('allocate') ||
        error.contains('outofmemory') ||
        error.contains('failed to create context')) {
      final notice = _inference.resourceConfigurationNotice.value;
      if (notice.isNotEmpty) return notice;
      return 'MaxAI could not reserve enough memory for this model.';
    }
    if (error.contains('gguf') || error.contains('corrupt')) {
      return 'The downloaded model could not be read. Retry the download.';
    }
    return 'MaxAI could not prepare the local model. Retry from the Models tab.';
  }
}
