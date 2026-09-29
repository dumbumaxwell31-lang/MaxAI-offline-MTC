import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:get/get.dart';

import 'device_eligibility_service.dart';
import 'download_service.dart';
import 'model_selection_service.dart';

enum AutomaticModelDownloadState {
  checking,
  missing,
  ready,
  waitingForNetwork,
  downloading,
  ineligible,
  insufficientStorage,
  failed,
}

Future<String> _sha256FileAtPath(String path) async {
  final digest = await sha256.bind(File(path).openRead()).first;
  return digest.toString();
}

class ModelFileValidation {
  const ModelFileValidation._(this.isValid, this.message);

  const ModelFileValidation.valid() : this._(true, 'Model file is valid.');

  const ModelFileValidation.invalid(String message) : this._(false, message);

  final bool isValid;
  final String message;
}

class ModelFileValidator {
  ModelFileValidator._();

  static Future<ModelFileValidation> validate({
    required String path,
    required SelectedLocalModel model,
  }) async {
    final file = File(path);
    if (!await file.exists()) {
      return const ModelFileValidation.invalid('Model file is missing.');
    }

    final size = await file.length();
    if (size != model.expectedFileSizeBytes) {
      return ModelFileValidation.invalid(
        'Model file size is invalid: $size bytes, expected ${model.expectedFileSizeBytes} bytes.',
      );
    }

    final reader = await file.open();
    try {
      final header = await reader.read(4);
      if (header.length != 4 ||
          header[0] != 0x47 ||
          header[1] != 0x47 ||
          header[2] != 0x55 ||
          header[3] != 0x46) {
        return const ModelFileValidation.invalid(
          'Model file does not have a GGUF header.',
        );
      }
    } finally {
      await reader.close();
    }

    final expectedHash = model.sha256.toLowerCase();
    if (expectedHash.isNotEmpty) {
      final modifiedAt = await file.lastModified();
      final marker = File('$path.verified');
      final markerValue =
          '$expectedHash:$size:${modifiedAt.millisecondsSinceEpoch}';
      var isVerified = false;
      try {
        isVerified = await marker.readAsString() == markerValue;
      } catch (_) {}

      if (!isVerified) {
        final actualHash = await Isolate.run(() => _sha256FileAtPath(path));
        if (actualHash.toLowerCase() != expectedHash) {
          return const ModelFileValidation.invalid(
            'Model checksum does not match the verified source file.',
          );
        }
        try {
          await marker.writeAsString(markerValue, flush: true);
        } catch (_) {}
      }
    }

    return const ModelFileValidation.valid();
  }
}

enum AutomaticDownloadStartResult { started, alreadyInProgress, completed }

typedef SelectedModelValidator = Future<ModelFileValidation> Function(
  SelectedLocalModel model,
);
typedef AutomaticDownloadStarter = Future<AutomaticDownloadStartResult>
    Function(SelectedLocalModel model);
typedef NetworkAvailabilityChecker = Future<bool> Function();
typedef AvailableStorageReader = Future<int?> Function();
typedef SelectedModelReader = SelectedLocalModel? Function();
typedef DeviceEligibilityChecker = Future<DeviceEligibilityResult> Function();

/// Validates all catalog entries and coordinates explicitly requested downloads.
class AutomaticModelDownloadService extends GetxService {
  AutomaticModelDownloadService({
    SelectedModelValidator? validator,
    AutomaticDownloadStarter? downloadStarter,
    NetworkAvailabilityChecker? networkAvailabilityChecker,
    AvailableStorageReader? availableStorageReader,
    SelectedModelReader? selectedModelReader,
    DeviceEligibilityChecker? eligibilityChecker,
  })  : _validator = validator,
        _downloadStarter = downloadStarter,
        _networkAvailabilityChecker = networkAvailabilityChecker,
        _availableStorageReader = availableStorageReader,
        _selectedModelReader = selectedModelReader,
        _eligibilityChecker = eligibilityChecker;

  final SelectedModelValidator? _validator;
  final AutomaticDownloadStarter? _downloadStarter;
  final NetworkAvailabilityChecker? _networkAvailabilityChecker;
  final AvailableStorageReader? _availableStorageReader;
  final SelectedModelReader? _selectedModelReader;
  final DeviceEligibilityChecker? _eligibilityChecker;

  final state = AutomaticModelDownloadState.checking.obs;
  final statusMessage = 'Checking the selected local model.'.obs;
  final failureMessage = ''.obs;
  final downloadedBytes = 0.obs;
  final totalBytes = 0.obs;
  final progress = 0.0.obs;
  final modelStates = <String, AutomaticModelDownloadState>{}.obs;
  final modelStatusMessages = <String, String>{}.obs;
  final modelFailureMessages = <String, String>{}.obs;
  final modelProgress = <String, double>{}.obs;

  Worker? _downloadWatcher;
  SelectedLocalModel? _activeModel;
  final Map<String, Future<void>> _inFlightDownloads = {};
  final Map<String, Future<void>> _inFlightValidations = {};

  bool get isReady => state.value == AutomaticModelDownloadState.ready;
  bool get isDownloading =>
      state.value == AutomaticModelDownloadState.downloading;
  bool get canRetry =>
      state.value == AutomaticModelDownloadState.waitingForNetwork ||
      state.value == AutomaticModelDownloadState.insufficientStorage ||
      state.value == AutomaticModelDownloadState.failed ||
      state.value == AutomaticModelDownloadState.ineligible;

  int get requiredStorageBytes => selectedModel == null
      ? 0
      : AutomaticModelPolicy.requiredDownloadStorageBytes(selectedModel!);

  SelectedLocalModel? get selectedModel =>
      (_selectedModelReader ?? _readSelectedModel)();

  SelectedLocalModel? get currentModel => _activeModel ?? selectedModel;

  Future<AutomaticModelDownloadService> init() async {
    if (_downloadStarter == null) {
      _downloadWatcher = ever(
        Get.find<DownloadService>().downloadUpdateSequence,
        (_) => unawaited(_reconcileDownloadCompletion()),
      );
    }
    final selected = selectedModel;
    if (selected != null) await inspectModel(selected);
    return this;
  }

  Future<void> ensureSelectedModel() async {
    final model = selectedModel;
    if (model == null) {
      state.value = AutomaticModelDownloadState.failed;
      statusMessage.value = 'Select a local model from the Models hub.';
      failureMessage.value = statusMessage.value;
      return;
    }
    await inspectModel(model);
  }

  Future<void> retrySelectedModelDownload() async {
    final model = selectedModel;
    if (model != null) await downloadModel(model, forceRetry: true);
  }

  Future<void> inspectModel(SelectedLocalModel model) {
    final existing = _inFlightValidations[model.identifier];
    if (existing != null) return existing;
    final validation = _inspectModel(model);
    _inFlightValidations[model.identifier] = validation;
    return validation.whenComplete(() {
      if (identical(_inFlightValidations[model.identifier], validation)) {
        _inFlightValidations.remove(model.identifier);
      }
    });
  }

  Future<void> _inspectModel(SelectedLocalModel model) async {
    _activeModel = model;
    _setForModel(
      model,
      AutomaticModelDownloadState.checking,
      'Checking ${model.name}.',
    );
    try {
      final validation = await _validate(model);
      if (validation.isValid) {
        _setReady(model);
      } else if (Get.isRegistered<DownloadService>() &&
          Get.find<DownloadService>()
              .activeDownloads
              .containsKey(model.filename)) {
        final active =
            Get.find<DownloadService>().activeDownloads[model.filename]!;
        updateProgress(
          receivedBytes: active.downloadedBytes.value,
          expectedBytes: active.totalBytes.value > 0
              ? active.totalBytes.value
              : model.expectedFileSizeBytes,
          model: model,
        );
      } else {
        _setForModel(
          model,
          AutomaticModelDownloadState.missing,
          '${model.name} is not downloaded yet.',
        );
      }
    } catch (error) {
      _setFailure(model, _friendlyDownloadError(error));
    }
  }

  Future<void> downloadModel(
    SelectedLocalModel model, {
    bool forceRetry = false,
  }) {
    final existing = _inFlightDownloads[model.identifier];
    if (existing != null) return existing;
    if (!forceRetry &&
        modelStates[model.identifier] ==
            AutomaticModelDownloadState.downloading) {
      return Future.value();
    }
    final download = _downloadModel(model);
    _inFlightDownloads[model.identifier] = download;
    return download.whenComplete(() {
      if (identical(_inFlightDownloads[model.identifier], download)) {
        _inFlightDownloads.remove(model.identifier);
      }
    });
  }

  Future<void> _downloadModel(SelectedLocalModel model) async {
    _activeModel = model;
    try {
      _setForModel(
        model,
        AutomaticModelDownloadState.checking,
        'Checking ${model.name}.',
      );
      final currentValidation = await _validate(model);
      if (currentValidation.isValid) {
        _setReady(model);
        return;
      }

      final eligibility = await _checkEligibility(model);
      if (!eligibility.isEligible) {
        _setIneligible(model, eligibility);
        return;
      }

      if (!await _hasNetworkConnection()) {
        _setForModel(
          model,
          AutomaticModelDownloadState.waitingForNetwork,
          'Connect to the internet to download ${model.name}.',
        );
        return;
      }

      final availableStorage = await _readAvailableStorage();
      final required = AutomaticModelPolicy.requiredDownloadStorageBytes(model);
      if (availableStorage == null || availableStorage < required) {
        final detail = availableStorage == null
            ? 'Unable to determine available app storage.'
            : 'Requires at least ${DownloadService.formatBytes(required)} free; '
                '${DownloadService.formatBytes(availableStorage)} is available.';
        _setForModel(
          model,
          AutomaticModelDownloadState.insufficientStorage,
          'Not enough free storage to download ${model.name}.',
          failure: detail,
        );
        return;
      }

      _setForModel(
        model,
        AutomaticModelDownloadState.downloading,
        'Downloading ${model.name}.',
      );
      final result = await _startDownload(model);
      if (result == AutomaticDownloadStartResult.completed) {
        await completeDownload(model);
      } else if (result == AutomaticDownloadStartResult.alreadyInProgress) {
        _setForModel(
          model,
          AutomaticModelDownloadState.downloading,
          'Downloading ${model.name}.',
        );
      }
    } catch (error) {
      _setFailure(model, _friendlyDownloadError(error));
    }
  }

  Future<void> completeDownload([SelectedLocalModel? model]) async {
    final target = model ?? currentModel;
    if (target == null) return;
    _activeModel = target;
    try {
      _setForModel(
        target,
        AutomaticModelDownloadState.checking,
        'Validating ${target.name}.',
      );
      final validation = await _validate(target);
      if (validation.isValid) {
        _setReady(target);
      } else {
        _setFailure(target, validation.message);
      }
    } catch (error) {
      _setFailure(target, _friendlyDownloadError(error));
    }
  }

  void updateProgress({
    required int receivedBytes,
    required int expectedBytes,
    SelectedLocalModel? model,
  }) {
    final target = model ?? currentModel;
    if (target == null) return;
    final safeReceived = receivedBytes.clamp(0, 1 << 62);
    final safeExpected = expectedBytes;
    final value = safeExpected <= 0
        ? 0.0
        : (safeReceived / safeExpected).clamp(0.0, 1.0).toDouble();
    modelProgress[target.identifier] = value;
    if (selectedModel?.identifier == target.identifier) {
      downloadedBytes.value = safeReceived;
      totalBytes.value = safeExpected;
      progress.value = value;
    }
    if (modelStates[target.identifier] !=
        AutomaticModelDownloadState.downloading) {
      _setForModel(
        target,
        AutomaticModelDownloadState.downloading,
        'Downloading ${target.name}.',
      );
    }
  }

  AutomaticModelDownloadState statusFor(SelectedLocalModel model) =>
      modelStates[model.identifier] ?? AutomaticModelDownloadState.checking;

  String statusMessageFor(SelectedLocalModel model) =>
      modelStatusMessages[model.identifier] ?? 'Checking ${model.name}.';

  String failureMessageFor(SelectedLocalModel model) =>
      modelFailureMessages[model.identifier] ?? '';

  double progressFor(SelectedLocalModel model) =>
      modelProgress[model.identifier] ?? 0;

  Future<void> _reconcileDownloadCompletion() async {
    if (_downloadStarter != null) return;
    final service = Get.find<DownloadService>();
    for (final model in AutomaticModelPolicy.supportedModels) {
      final active = service.activeDownloads[model.filename];
      if (active != null) {
        _activeModel = model;
        updateProgress(
          receivedBytes: active.downloadedBytes.value,
          expectedBytes: active.totalBytes.value > 0
              ? active.totalBytes.value
              : model.expectedFileSizeBytes,
          model: model,
        );
        continue;
      }

      final failure = service.failedDownloads[model.filename];
      if (failure != null && failure.isNotEmpty) {
        _setFailure(model, failure);
      } else if (modelStates[model.identifier] ==
          AutomaticModelDownloadState.downloading) {
        await completeDownload(model);
      }
    }
  }

  Future<ModelFileValidation> _validate(SelectedLocalModel model) {
    final validator = _validator;
    if (validator != null) return validator(model);
    return _validateFromStorage(model);
  }

  Future<ModelFileValidation> _validateFromStorage(
      SelectedLocalModel model) async {
    final path = await Get.find<DownloadService>().modelPath(model.filename);
    return ModelFileValidator.validate(path: path, model: model);
  }

  Future<AutomaticDownloadStartResult> _startDownload(
      SelectedLocalModel model) {
    final starter = _downloadStarter;
    if (starter != null) return starter(model);
    return _startPlatformDownload(model);
  }

  Future<AutomaticDownloadStartResult> _startPlatformDownload(
      SelectedLocalModel model) async {
    final result = await Get.find<DownloadService>().downloadModel(
      url: model.downloadUrl,
      filename: model.filename,
      expectedBytes: model.expectedFileSizeBytes,
    );
    if (result == 'ALREADY_DOWNLOADING') {
      return AutomaticDownloadStartResult.alreadyInProgress;
    }
    if (result == 'NATIVE_BACKGROUND_STARTED') {
      return AutomaticDownloadStartResult.started;
    }
    throw StateError(result);
  }

  Future<DeviceEligibilityResult> _checkEligibility(
      SelectedLocalModel model) async {
    if (!model.requiresProHardware) {
      return const DeviceEligibilityResult(
        status: DeviceEligibilityStatus.eligible,
      );
    }
    final checker = _eligibilityChecker;
    if (checker != null) return checker();
    if (_selectedModelReader != null &&
        !Get.isRegistered<ModelSelectionService>()) {
      return const DeviceEligibilityResult(
        status: DeviceEligibilityStatus.eligible,
      );
    }
    if (Get.isRegistered<ModelSelectionService>()) {
      final selection = Get.find<ModelSelectionService>();
      await selection.refreshHardwareInfo();
      final ram = selection.totalRamGb.value;
      if (ram == null) {
        return const DeviceEligibilityResult(
          status: DeviceEligibilityStatus.unavailable,
          requiredRamGb: AutomaticModelPolicy.proMinimumTotalRamGb,
        );
      }
      if (ram < model.minimumTotalRamGb) {
        return DeviceEligibilityResult(
          status: DeviceEligibilityStatus.insufficientRam,
          totalRamGb: ram,
          requiredRamGb: model.minimumTotalRamGb,
        );
      }
      return DeviceEligibilityResult(
        status: DeviceEligibilityStatus.eligible,
        totalRamGb: ram,
      );
    }
    return const DeviceEligibilityResult(
      status: DeviceEligibilityStatus.eligible,
    );
  }

  Future<bool> _hasNetworkConnection() async {
    final checker = _networkAvailabilityChecker;
    if (checker != null) return checker();
    try {
      final addresses = await InternetAddress.lookup('huggingface.co')
          .timeout(const Duration(seconds: 5));
      return addresses.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  Future<int?> _readAvailableStorage() {
    final reader = _availableStorageReader;
    if (reader != null) return reader();
    return Get.find<DownloadService>().getAvailableStorageBytes();
  }

  SelectedLocalModel? _readSelectedModel() =>
      Get.find<ModelSelectionService>().selectedModel.value;

  void _setForModel(
    SelectedLocalModel model,
    AutomaticModelDownloadState nextState,
    String message, {
    String failure = '',
  }) {
    modelStates[model.identifier] = nextState;
    modelStatusMessages[model.identifier] = message;
    modelFailureMessages[model.identifier] = failure;
    if (nextState != AutomaticModelDownloadState.downloading) {
      if (nextState == AutomaticModelDownloadState.ready) {
        modelProgress[model.identifier] = 1;
      } else if (nextState != AutomaticModelDownloadState.checking) {
        modelProgress[model.identifier] = 0;
      }
    }
    if (selectedModel?.identifier == model.identifier) {
      state.value = nextState;
      statusMessage.value = message;
      failureMessage.value = failure;
      progress.value = modelProgress[model.identifier] ?? 0;
      if (nextState == AutomaticModelDownloadState.ready) {
        totalBytes.value = model.expectedFileSizeBytes;
        downloadedBytes.value = totalBytes.value;
      } else if (nextState != AutomaticModelDownloadState.downloading) {
        downloadedBytes.value = 0;
        totalBytes.value = model.expectedFileSizeBytes;
      }
    }
  }

  void _setReady(SelectedLocalModel model) {
    modelProgress[model.identifier] = 1;
    _setForModel(
      model,
      AutomaticModelDownloadState.ready,
      '${model.name} is ready for local use.',
    );
  }

  void _setFailure(SelectedLocalModel model, String message) {
    _setForModel(
      model,
      AutomaticModelDownloadState.failed,
      'Unable to prepare ${model.name}.',
      failure: message,
    );
  }

  void _setIneligible(
      SelectedLocalModel model, DeviceEligibilityResult eligibility) {
    _setForModel(
      model,
      AutomaticModelDownloadState.ineligible,
      eligibility.message,
      failure: eligibility.detailMessage,
    );
  }

  String _friendlyDownloadError(Object error) {
    final message = error.toString();
    if (message.contains('SocketException') ||
        message.contains('connection error') ||
        message.contains('Network is unreachable')) {
      return 'Network connection failed. Check your internet connection and retry.';
    }
    return message;
  }

  @override
  void onClose() {
    _downloadWatcher?.dispose();
    super.onClose();
  }
}
