import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../services/app_log_service.dart';
import '../services/automatic_model_download_service.dart';
import '../services/download_service.dart';
import '../services/inference_service.dart';
import '../services/model_selection_service.dart';
import 'settings_controller.dart';

class ModelController extends GetxController {
  final DownloadService _download = Get.find<DownloadService>();
  final InferenceService _inference = Get.find<InferenceService>();
  final SettingsController _settings = Get.find<SettingsController>();
  final ModelSelectionService _selection = Get.find<ModelSelectionService>();
  final AutomaticModelDownloadService _downloads =
      Get.find<AutomaticModelDownloadService>();

  final downloadedFiles = <String>[].obs;
  Worker? _selectionWatcher;
  Worker? _downloadWatcher;

  List<SelectedLocalModel> get models => AutomaticModelPolicy.supportedModels;
  SelectedLocalModel? get selectedModel => _selection.selectedModel.value;
  SelectedLocalModel? get selectedAutomaticModel => selectedModel;
  bool get isSelectedModelReady => _downloads.isReady;
  int get downloadedCount => downloadedFiles.length;
  bool get isLoadingModel => _inference.isLoadingModel.value;
  bool get isAnyModelLoaded => _inference.isModelLoaded.value;
  String get loadedModelName => _inference.loadedModelName.value;

  bool isSelected(SelectedLocalModel model) =>
      selectedModel?.identifier == model.identifier;

  bool isCompatible(SelectedLocalModel model) =>
      _selection.isModelCompatible(model);

  String compatibilityMessage(SelectedLocalModel model) =>
      _selection.compatibilityMessage(model);

  AutomaticModelDownloadState statusFor(SelectedLocalModel model) =>
      _downloads.statusFor(model);

  String statusMessageFor(SelectedLocalModel model) =>
      _downloads.statusMessageFor(model);

  String failureMessageFor(SelectedLocalModel model) =>
      _downloads.failureMessageFor(model);

  double progressFor(SelectedLocalModel model) => _downloads.progressFor(model);

  bool isDownloaded(String filename) => downloadedFiles.contains(filename);

  bool isLoaded(SelectedLocalModel model) =>
      _inference.isModelLoaded.value &&
      _inference.loadedModelName.value == model.filename;

  @override
  void onInit() {
    super.onInit();
    _selectionWatcher = ever<SelectedLocalModel?>(
      _selection.selectedModel,
      (model) {
        if (model != null) _downloads.inspectModel(model);
      },
    );
    _downloadWatcher = ever<int>(
      _download.downloadUpdateSequence,
      (_) => refreshDownloaded(),
    );
    // Inspect every catalog model once so cards without a file leave the
    // disabled "Checking" state and offer Download.
    refreshModelStatuses();
  }

  @override
  void onClose() {
    _selectionWatcher?.dispose();
    _downloadWatcher?.dispose();
    super.onClose();
  }

  Future<void> refreshDownloaded() async {
    final previousFiles = downloadedFiles.toSet();
    final files = await _download.getDownloadedModels();
    downloadedFiles.value =
        files.where((file) => file.toLowerCase().endsWith('.gguf')).toList();
    for (final model in models) {
      final isNowPresent = downloadedFiles.contains(model.filename);
      final wasPresent = previousFiles.contains(model.filename);
      if (isNowPresent && !wasPresent) {
        await _downloads.inspectModel(model);
      }
    }
  }

  Future<void> refreshModelStatuses() async {
    await refreshDownloaded();
    await Future.wait(models.map(_downloads.inspectModel));
  }

  Future<bool> selectModel(SelectedLocalModel model) async {
    await _selection.refreshHardwareInfo();
    if (!isCompatible(model)) {
      _showCompatibilityDialog(model);
      return false;
    }
    final selected = await _selection.selectModel(model.identifier);
    if (selected) await _downloads.inspectModel(model);
    return selected;
  }

  Future<void> downloadModel(
    SelectedLocalModel model, {
    bool retry = false,
  }) async {
    await _selection.refreshHardwareInfo();
    if (!isCompatible(model)) {
      _showCompatibilityDialog(model);
      return;
    }
    await _downloads.downloadModel(model, forceRetry: retry);
    await refreshDownloaded();
  }

  /// Filename of the model a load was requested for, from the tap until the
  /// load finishes. Lets the UI show progress immediately and ignore re-taps.
  final pendingModelFilename = ''.obs;

  bool get isModelBusy =>
      pendingModelFilename.value.isNotEmpty || _inference.isModelBusy;

  /// Load and Unload share one button position. Ignoring taps briefly after
  /// an action finishes stops a burst of taps from undoing that action.
  static const _actionCooldown = Duration(seconds: 1);
  DateTime _actionCooldownUntil = DateTime.fromMillisecondsSinceEpoch(0);

  bool get _inCooldown => DateTime.now().isBefore(_actionCooldownUntil);

  void _startCooldown() {
    _actionCooldownUntil = DateTime.now().add(_actionCooldown);
  }

  Future<void> loadModel(String filename) async {
    final model = AutomaticModelPolicy.modelForFilename(filename);
    if (model == null) {
      _showStatus('Unsupported Model', 'Choose a supported model in Models.');
      return;
    }
    if (isModelBusy || _inCooldown) return;
    pendingModelFilename.value = filename;
    try {
      await _loadModel(model);
    } finally {
      pendingModelFilename.value = '';
      _startCooldown();
    }
  }

  Future<void> _loadModel(SelectedLocalModel model) async {
    if (!await selectModel(model)) return;

    await _downloads.inspectModel(model);
    if (_downloads.statusFor(model) != AutomaticModelDownloadState.ready ||
        !await _download.isModelDownloaded(model.filename)) {
      _showStatus(
        'Model Not Ready',
        '${model.name} must be downloaded and validated before loading.',
      );
      return;
    }

    if (_inference.isModelLoaded.value &&
        _inference.loadedModelName.value == model.filename) {
      await _settings.setInferenceMode('local');
      _showStatus('Local Model Loaded', '${model.name} is ready to chat.');
      return;
    }

    await _loadSelectedModel(model);
  }

  Future<void> _loadSelectedModel(SelectedLocalModel model) async {
    final path = await _download.modelPath(model.filename);
    final result = await _inference.loadModel(path, modelName: model.filename);
    if (_inference.isModelLoaded.value) {
      await _settings.setInferenceMode('local');
      final notice = _inference.resourceConfigurationNotice.value;
      _showStatus(
        'Local Model Loaded',
        notice.isEmpty
            ? '${model.name} is ready to chat.'
            : '${model.name} is ready to chat. $notice',
      );
      return;
    }

    Get.find<AppLogService>()
        .error('Selected model failed to load', details: result);
    _showStatus('Model Could Not Load', _friendlyLoadMessage(result));
  }

  Future<void> unloadModel() async {
    if (isModelBusy || _inCooldown) return;
    try {
      await _inference.unloadModel();
    } finally {
      _startCooldown();
    }
  }

  void _showCompatibilityDialog(SelectedLocalModel model) {
    final message = compatibilityMessage(model);
    Get.dialog<void>(
      AlertDialog(
        title: const Text('Model unavailable'),
        content: Text(message.isEmpty
            ? 'This model is not compatible with the current device.'
            : message),
        actions: [
          TextButton(
            onPressed: Get.back,
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

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
      return 'MaxAI could not reserve enough memory for this model. Try closing other apps or reducing the context/output limits.';
    }
    if (error.contains('gguf') || error.contains('corrupt')) {
      return 'The downloaded model could not be read. Retry its download.';
    }
    return 'MaxAI could not prepare the local model. Check its status in Models and retry.';
  }
}
