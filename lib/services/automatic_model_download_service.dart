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

/// Coordinates startup downloads for the single RAM-selected GGUF model.
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

  Worker? _downloadWatcher;
  Future<void>? _inFlightCheck;
  DeviceEligibilityResult? _lastEligibility;

  bool get isReady => state.value == AutomaticModelDownloadState.ready;
  bool get isDownloading =>
      state.value == AutomaticModelDownloadState.downloading;
  bool get canRetry =>
      state.value == AutomaticModelDownloadState.waitingForNetwork ||
      state.value == AutomaticModelDownloadState.insufficientStorage ||
      state.value == AutomaticModelDownloadState.failed ||
      (state.value == AutomaticModelDownloadState.ineligible &&
          (_lastEligibility?.canRetry ?? true));

  int get requiredStorageBytes =>
      currentModel.expectedFileSizeBytes * 2 + 64 * 1024 * 1024;

  SelectedLocalModel? get selectedModel =>
      (_selectedModelReader ?? _readSelectedModel)();

  SelectedLocalModel get currentModel => selectedModel!;

  Future<AutomaticModelDownloadService> init() async {
    if (_downloadStarter == null) {
      _downloadWatcher = ever(
        Get.find<DownloadService>().downloadUpdateSequence,
        (_) => unawaited(_reconcileDownloadCompletion()),
      );
    }
    unawaited(ensureSelectedModel());
    return this;
  }

  Future<void> ensureSelectedModel({bool forceRetry = false}) {
    if (!forceRetry && _inFlightCheck != null) return _inFlightCheck!;
    if (!forceRetry && isDownloading) return Future.value();

    final check = _ensureSelectedModel();
    _inFlightCheck = check;
    return check.whenComplete(() {
      if (identical(_inFlightCheck, check)) {
        _inFlightCheck = null;
      }
    });
  }

  Future<void> retrySelectedModelDownload() =>
      ensureSelectedModel(forceRetry: true);

  Future<void> completeDownload() async {
    try {
      state.value = AutomaticModelDownloadState.checking;
      final validation = await _validate(currentModel);
      if (validation.isValid) {
        _setReady();
      } else {
        _setFailure(validation.message);
      }
    } catch (error) {
      _setFailure(_friendlyDownloadError(error));
    }
  }

  void updateProgress(
      {required int receivedBytes, required int expectedBytes}) {
    downloadedBytes.value = receivedBytes;
    totalBytes.value = expectedBytes;
    progress.value = expectedBytes <= 0
        ? 0
        : (receivedBytes / expectedBytes).clamp(0.0, 1.0).toDouble();
  }

  Future<void> _ensureSelectedModel() async {
    try {
      final eligibility = await _checkEligibility();
      _lastEligibility = eligibility;
      if (!eligibility.isEligible) {
        _setIneligible(eligibility);
        return;
      }

      if (_selectedModelReader == null) {
        await Get.find<ModelSelectionService>().refreshSelection();
        final selected = selectedModel;
        if (selected == null) {
          _lastEligibility = null;
          state.value = AutomaticModelDownloadState.ineligible;
          statusMessage.value =
              Get.find<ModelSelectionService>().selectionMessage.value;
          failureMessage.value = statusMessage.value;
          return;
        }
      }
      final model = currentModel;
      state.value = AutomaticModelDownloadState.checking;
      statusMessage.value = 'Checking ${model.name}.';
      failureMessage.value = '';

      final validation = await _validate(model);
      if (validation.isValid) {
        _setReady();
        return;
      }

      if (!await _hasNetworkConnection()) {
        state.value = AutomaticModelDownloadState.waitingForNetwork;
        statusMessage.value =
            'Connect to the internet to download ${model.name} for offline use.';
        return;
      }

      final availableStorage = await _readAvailableStorage();
      if (availableStorage == null || availableStorage < requiredStorageBytes) {
        state.value = AutomaticModelDownloadState.insufficientStorage;
        statusMessage.value =
            'Not enough free storage to download ${model.name} safely.';
        failureMessage.value = availableStorage == null
            ? 'Unable to determine available app storage.'
            : 'Requires about ${DownloadService.formatBytes(requiredStorageBytes)} free storage; ${DownloadService.formatBytes(availableStorage)} is available.';
        return;
      }

      state.value = AutomaticModelDownloadState.downloading;
      statusMessage.value = 'Downloading ${model.name}.';
      failureMessage.value = '';
      final result = await _startDownload(model);
      if (result == AutomaticDownloadStartResult.completed) {
        await completeDownload();
      }
    } catch (error) {
      _setFailure(_friendlyDownloadError(error));
    }
  }

  Future<void> _reconcileDownloadCompletion() async {
    if (_downloadStarter != null || !isDownloading) return;

    final downloadService = Get.find<DownloadService>();
    final filename = currentModel.filename;
    final active = downloadService.activeDownloads[filename];
    if (active != null) {
      updateProgress(
        receivedBytes: active.downloadedBytes.value,
        expectedBytes: active.totalBytes.value > 0
            ? active.totalBytes.value
            : currentModel.expectedFileSizeBytes,
      );
      return;
    }

    final failure = downloadService.failedDownloads[filename];
    if (failure != null && failure.isNotEmpty) {
      _setFailure(failure);
      return;
    }
    await completeDownload();
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
    if (result.startsWith('INELIGIBLE:')) {
      _setIneligible(Get.find<DeviceEligibilityService>().currentResult);
      return AutomaticDownloadStartResult.alreadyInProgress;
    }
    if (result == 'NATIVE_BACKGROUND_STARTED') {
      return AutomaticDownloadStartResult.started;
    }
    return AutomaticDownloadStartResult.completed;
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

  Future<DeviceEligibilityResult> _checkEligibility() {
    final checker = _eligibilityChecker;
    if (checker != null) return checker();
    if (_selectedModelReader != null) {
      return Future.value(const DeviceEligibilityResult(
        status: DeviceEligibilityStatus.eligible,
      ));
    }
    return Get.find<DeviceEligibilityService>().refreshEligibility();
  }

  SelectedLocalModel? _readSelectedModel() =>
      Get.find<ModelSelectionService>().selectedModel.value;

  void _setReady() {
    state.value = AutomaticModelDownloadState.ready;
    statusMessage.value = '${currentModel.name} is ready for local use.';
    failureMessage.value = '';
    progress.value = 1;
    totalBytes.value = currentModel.expectedFileSizeBytes;
    downloadedBytes.value = totalBytes.value;
  }

  void _setFailure(String message) {
    final model = selectedModel;
    state.value = AutomaticModelDownloadState.failed;
    statusMessage.value = model == null
        ? 'Unable to prepare local AI.'
        : 'Unable to download ${model.name}.';
    failureMessage.value = message;
  }

  void _setIneligible(DeviceEligibilityResult eligibility) {
    state.value = AutomaticModelDownloadState.ineligible;
    statusMessage.value = eligibility.message;
    failureMessage.value = eligibility.detailMessage;
    downloadedBytes.value = 0;
    totalBytes.value = 0;
    progress.value = 0;
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
