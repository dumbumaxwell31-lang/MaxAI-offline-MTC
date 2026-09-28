import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:maxai/services/automatic_model_download_service.dart';
import 'package:maxai/services/device_eligibility_service.dart';
import 'package:maxai/services/model_selection_service.dart';

void main() {
  const model = AutomaticModelPolicy.maxAiLite;
  const valid = ModelFileValidation.valid();
  const missing = ModelFileValidation.invalid('Model file is missing.');

  AutomaticModelDownloadService service({
    required SelectedModelValidator validator,
    required AutomaticDownloadStarter starter,
    required NetworkAvailabilityChecker network,
    required AvailableStorageReader storage,
    DeviceEligibilityChecker? eligibility,
  }) {
    return AutomaticModelDownloadService(
      validator: validator,
      downloadStarter: starter,
      networkAvailabilityChecker: network,
      availableStorageReader: storage,
      selectedModelReader: () => model,
      eligibilityChecker: eligibility,
    );
  }

  group('AutomaticModelDownloadService', () {
    test('marks an existing valid model ready without a download', () async {
      var starts = 0;
      final downloadService = service(
        validator: (_) async => valid,
        starter: (_) async {
          starts++;
          return AutomaticDownloadStartResult.started;
        },
        network: () async => false,
        storage: () async => 0,
      );

      await downloadService.ensureSelectedModel();

      expect(downloadService.state.value, AutomaticModelDownloadState.ready);
      expect(starts, 0);
    });

    test('handles a missing model safely while offline', () async {
      var starts = 0;
      final downloadService = service(
        validator: (_) async => missing,
        starter: (_) async {
          starts++;
          return AutomaticDownloadStartResult.started;
        },
        network: () async => false,
        storage: () async => model.expectedFileSizeBytes * 3,
      );

      await downloadService.ensureSelectedModel();

      expect(
        downloadService.state.value,
        AutomaticModelDownloadState.waitingForNetwork,
      );
      expect(downloadService.canRetry, isTrue);
      expect(starts, 0);
    });

    test('does not start a download when storage is insufficient', () async {
      var starts = 0;
      final downloadService = service(
        validator: (_) async => missing,
        starter: (_) async {
          starts++;
          return AutomaticDownloadStartResult.started;
        },
        network: () async => true,
        storage: () async => model.expectedFileSizeBytes,
      );

      await downloadService.ensureSelectedModel();

      expect(
        downloadService.state.value,
        AutomaticModelDownloadState.insufficientStorage,
      );
      expect(starts, 0);
    });

    test('does not start a download when the device is ineligible', () async {
      var starts = 0;
      final downloadService = service(
        validator: (_) async => missing,
        starter: (_) async {
          starts++;
          return AutomaticDownloadStartResult.started;
        },
        network: () async => true,
        storage: () async => model.expectedFileSizeBytes * 3,
        eligibility: () async => const DeviceEligibilityResult(
          status: DeviceEligibilityStatus.insufficientRam,
          totalRamGb: 1.5,
        ),
      );

      await downloadService.ensureSelectedModel();

      expect(
        downloadService.state.value,
        AutomaticModelDownloadState.ineligible,
      );
      expect(starts, 0);
    });

    test('applies selected-model storage requirements after eligibility',
        () async {
      var starts = 0;
      final downloadService = service(
        validator: (_) async => missing,
        starter: (_) async {
          starts++;
          return AutomaticDownloadStartResult.started;
        },
        network: () async => true,
        storage: () async => model.expectedFileSizeBytes * 2,
        eligibility: () async => const DeviceEligibilityResult(
          status: DeviceEligibilityStatus.eligible,
          totalRamGb: 4,
          freeStorageBytes: DeviceEligibilityService.minimumFreeStorageBytes,
        ),
      );

      await downloadService.ensureSelectedModel();

      expect(
        downloadService.state.value,
        AutomaticModelDownloadState.insufficientStorage,
      );
      expect(starts, 0);
    });

    test('reports streamed download progress', () async {
      final downloadService = service(
        validator: (_) async => missing,
        starter: (_) async => AutomaticDownloadStartResult.started,
        network: () async => true,
        storage: () async => model.expectedFileSizeBytes * 3,
      );
      final receivedBytes = model.expectedFileSizeBytes ~/ 2;

      await downloadService.ensureSelectedModel();
      downloadService.updateProgress(
        receivedBytes: receivedBytes,
        expectedBytes: model.expectedFileSizeBytes,
      );

      expect(
        downloadService.state.value,
        AutomaticModelDownloadState.downloading,
      );
      expect(downloadService.progress.value, 0.5);
      expect(downloadService.downloadedBytes.value, receivedBytes);
    });

    test('does not start duplicate simultaneous downloads', () async {
      final completion = Completer<AutomaticDownloadStartResult>();
      var starts = 0;
      final downloadService = service(
        validator: (_) async => missing,
        starter: (_) {
          starts++;
          return completion.future;
        },
        network: () async => true,
        storage: () async => model.expectedFileSizeBytes * 3,
      );

      final first = downloadService.ensureSelectedModel();
      await Future<void>.delayed(Duration.zero);
      final second = downloadService.ensureSelectedModel();
      await Future<void>.delayed(Duration.zero);
      completion.complete(AutomaticDownloadStartResult.started);
      await Future.wait([first, second]);

      expect(starts, 1);
      expect(
        downloadService.state.value,
        AutomaticModelDownloadState.downloading,
      );
    });

    test('reports a failed download and permits retry', () async {
      final downloadService = service(
        validator: (_) async => missing,
        starter: (_) async => throw const SocketException('network dropped'),
        network: () async => true,
        storage: () async => model.expectedFileSizeBytes * 3,
      );

      await downloadService.ensureSelectedModel();

      expect(downloadService.state.value, AutomaticModelDownloadState.failed);
      expect(downloadService.canRetry, isTrue);
      expect(downloadService.failureMessage.value, contains('Network'));
    });

    test('retry reaches ready after a completed download validates', () async {
      var online = false;
      var downloaded = false;
      var starts = 0;
      final downloadService = service(
        validator: (_) async => downloaded ? valid : missing,
        starter: (_) async {
          starts++;
          downloaded = true;
          return AutomaticDownloadStartResult.completed;
        },
        network: () async => online,
        storage: () async => model.expectedFileSizeBytes * 3,
      );

      await downloadService.ensureSelectedModel();
      online = true;
      await downloadService.retrySelectedModelDownload();

      expect(starts, 1);
      expect(downloadService.state.value, AutomaticModelDownloadState.ready);
    });

    test('retry repeats the device eligibility check', () async {
      var isEligible = false;
      var eligibilityChecks = 0;
      var starts = 0;
      final downloadService = service(
        validator: (_) async => missing,
        starter: (_) async {
          starts++;
          return AutomaticDownloadStartResult.started;
        },
        network: () async => true,
        storage: () async => model.expectedFileSizeBytes * 3,
        eligibility: () async {
          eligibilityChecks++;
          return DeviceEligibilityResult(
            status: isEligible
                ? DeviceEligibilityStatus.eligible
                : DeviceEligibilityStatus.insufficientStorage,
            totalRamGb: 4,
            freeStorageBytes: isEligible
                ? model.expectedFileSizeBytes * 3
                : DeviceEligibilityService.minimumFreeStorageBytes - 1,
          );
        },
      );

      await downloadService.ensureSelectedModel();
      isEligible = true;
      await downloadService.retrySelectedModelDownload();

      expect(eligibilityChecks, 2);
      expect(starts, 1);
    });

    test('does not mark an incomplete completed download ready', () async {
      final downloadService = service(
        validator: (_) async => missing,
        starter: (_) async => AutomaticDownloadStartResult.completed,
        network: () async => true,
        storage: () async => model.expectedFileSizeBytes * 3,
      );

      await downloadService.ensureSelectedModel();

      expect(downloadService.state.value, AutomaticModelDownloadState.failed);
      expect(downloadService.failureMessage.value, contains('missing'));
    });
  });

  group('ModelFileValidator', () {
    const smallModel = SelectedLocalModel(
      name: 'Test Model',
      identifier: 'test-model',
      filename: 'test.gguf',
      quantization: 'Q4_K_M',
      downloadUrl: 'https://example.invalid/test.gguf',
      sourceRepository: 'test/repository',
      sourcePublisher: 'test',
      licenseSummary: 'test',
      expectedFileSizeBytes: 10,
      expectedFileSizeLabel: '10 B',
      template: 'chatml',
      description: 'test',
      sha256: '',
      minimumAvailableRamGb: 0,
      maxContextSize: 64,
      maxOutputTokens: 16,
    );

    test('accepts a temporary GGUF file with a valid header', () async {
      final directory = await Directory.systemTemp.createTemp('maxai-test-');
      final path = '${directory.path}${Platform.pathSeparator}test.gguf';
      addTearDown(() => directory.delete(recursive: true));
      await File(path).writeAsBytes(
        <int>[0x47, 0x47, 0x55, 0x46, 1, 2, 3, 4, 5, 6],
      );

      final result = await ModelFileValidator.validate(
        path: path,
        model: smallModel,
      );

      expect(result.isValid, isTrue);
    });

    test('rejects an incomplete temporary GGUF file', () async {
      final directory = await Directory.systemTemp.createTemp('maxai-test-');
      final path = '${directory.path}${Platform.pathSeparator}test.gguf';
      addTearDown(() => directory.delete(recursive: true));
      await File(path).writeAsBytes(<int>[0x47, 0x47, 0x55, 0x46, 1, 2, 3]);

      final result = await ModelFileValidator.validate(
        path: path,
        model: smallModel,
      );

      expect(result.isValid, isFalse);
      expect(result.message, contains('size is invalid'));
    });

    test('rejects a non-GGUF temporary file', () async {
      final directory = await Directory.systemTemp.createTemp('maxai-test-');
      final path = '${directory.path}${Platform.pathSeparator}test.gguf';
      addTearDown(() => directory.delete(recursive: true));
      await File(path).writeAsBytes(<int>[0, 1, 2, 3, 4, 5, 6, 7, 8, 9]);

      final result = await ModelFileValidator.validate(
        path: path,
        model: smallModel,
      );

      expect(result.isValid, isFalse);
      expect(result.message, contains('GGUF header'));
    });

    test('rejects a GGUF with a mismatched verified source checksum', () async {
      const checksumModel = SelectedLocalModel(
        name: 'Checksum Test Model',
        identifier: 'checksum-test',
        filename: 'checksum.gguf',
        quantization: 'Q4_K_M',
        downloadUrl: 'https://example.invalid/checksum.gguf',
        sourceRepository: 'test/repository',
        sourcePublisher: 'test',
        licenseSummary: 'test',
        expectedFileSizeBytes: 10,
        expectedFileSizeLabel: '10 B',
        template: 'chatml',
        description: 'test',
        sha256:
            '0000000000000000000000000000000000000000000000000000000000000000',
        minimumAvailableRamGb: 0,
        maxContextSize: 64,
        maxOutputTokens: 16,
      );
      final directory = await Directory.systemTemp.createTemp('maxai-test-');
      final path = '${directory.path}${Platform.pathSeparator}checksum.gguf';
      addTearDown(() => directory.delete(recursive: true));
      await File(path).writeAsBytes(
        <int>[0x47, 0x47, 0x55, 0x46, 1, 2, 3, 4, 5, 6],
      );

      final result = await ModelFileValidator.validate(
        path: path,
        model: checksumModel,
      );

      expect(result.isValid, isFalse);
      expect(result.message, contains('checksum'));
    });
  });
}
