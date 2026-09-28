import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:maxai/services/device_eligibility_service.dart';
import 'package:maxai/services/model_selection_service.dart';

void main() {
  group('AutomaticModelPolicy', () {
    test('selects Maxlite AI Model below 6 GB total RAM', () {
      final selected = AutomaticModelPolicy.selectForHardware(
        totalRamGb: 5.99,
        availableRamGb: 2.0,
        freeStorageBytes: AutomaticModelPolicy.requiredDownloadStorageBytes(
          AutomaticModelPolicy.maxAiLite,
        ),
      );

      expect(selected?.name, 'Maxlite AI Model');
      expect(selected?.identifier, 'qwen3-0.6b-q4_k_m');
      expect(selected?.quantization, 'Q4_K_M');
      expect(selected?.expectedFileSizeBytes, 484220320);
    });

    test('uses branded names while retaining technical model configuration',
        () {
      expect(AutomaticModelPolicy.maxAiLite.name, 'Maxlite AI Model');
      expect(AutomaticModelPolicy.maxAiLite.filename,
          'Qwen_Qwen3-0.6B-Q4_K_M.gguf');
      expect(AutomaticModelPolicy.maxAiLite.identifier, 'qwen3-0.6b-q4_k_m');
      expect(
        AutomaticModelPolicy.maxAiLite.downloadUrl,
        'https://huggingface.co/bartowski/Qwen_Qwen3-0.6B-GGUF/resolve/7bcae0bc7b0606f1e948f8cdb31b98a2c10635db/Qwen_Qwen3-0.6B-Q4_K_M.gguf',
      );

      expect(AutomaticModelPolicy.maxAiPro.name, 'MaxPro AI Model');
      expect(AutomaticModelPolicy.maxAiPro.filename, 'Qwen3-4B-Q4_K_M.gguf');
      expect(AutomaticModelPolicy.maxAiPro.identifier, 'qwen3-4b-q4_k_m');
      expect(
        AutomaticModelPolicy.maxAiPro.downloadUrl,
        'https://huggingface.co/Qwen/Qwen3-4B-GGUF/resolve/a9a60d009fa7ff9606305047c2bf77ac25dbec49/Qwen3-4B-Q4_K_M.gguf',
      );
    });

    test('maps internal filenames to user-facing model names', () {
      expect(
        AutomaticModelPolicy.displayNameForFilename(
          AutomaticModelPolicy.maxAiLite.filename,
        ),
        'Maxlite AI Model',
      );
      expect(
        AutomaticModelPolicy.displayNameForFilename(
          AutomaticModelPolicy.maxAiPro.filename,
        ),
        'MaxPro AI Model',
      );
    });

    test(
        'selects MaxPro AI Model at 6 GB only with sufficient free RAM and storage',
        () {
      final selected = AutomaticModelPolicy.selectForHardware(
        totalRamGb: 6,
        availableRamGb: AutomaticModelPolicy.minimumProAvailableRamGb,
        freeStorageBytes: AutomaticModelPolicy.requiredDownloadStorageBytes(
          AutomaticModelPolicy.maxAiPro,
        ),
      );

      expect(selected, same(AutomaticModelPolicy.maxAiPro));
      expect(selected?.identifier, 'qwen3-4b-q4_k_m');
      expect(selected?.expectedFileSizeBytes, 2497280256);
    });

    test('selects MaxPro AI Model above 6 GB with resources, otherwise Maxlite',
        () {
      final enoughResources = AutomaticModelPolicy.selectForHardware(
        totalRamGb: 8,
        availableRamGb: 5,
        freeStorageBytes: AutomaticModelPolicy.requiredDownloadStorageBytes(
          AutomaticModelPolicy.maxAiPro,
        ),
      );
      final lowFreeRam = AutomaticModelPolicy.selectForHardware(
        totalRamGb: 8,
        availableRamGb: 4.0,
        freeStorageBytes: AutomaticModelPolicy.requiredDownloadStorageBytes(
          AutomaticModelPolicy.maxAiPro,
        ),
      );
      final lowStorage = AutomaticModelPolicy.selectForHardware(
        totalRamGb: 8,
        availableRamGb: 5,
        freeStorageBytes: AutomaticModelPolicy.requiredDownloadStorageBytes(
              AutomaticModelPolicy.maxAiPro,
            ) -
            1,
      );

      expect(enoughResources, same(AutomaticModelPolicy.maxAiPro));
      expect(lowFreeRam, same(AutomaticModelPolicy.maxAiLite));
      expect(lowStorage, same(AutomaticModelPolicy.maxAiLite));
    });

    test('keeps Lite eligible under memory pressure for a conservative profile',
        () {
      final selected = AutomaticModelPolicy.selectForHardware(
        totalRamGb: 3.9,
        availableRamGb: 0.4,
        freeStorageBytes: AutomaticModelPolicy.requiredDownloadStorageBytes(
          AutomaticModelPolicy.maxAiLite,
        ),
      );

      expect(selected, same(AutomaticModelPolicy.maxAiLite));
    });

    test('keeps only the two supported models and no user-choice list', () {
      final selected = AutomaticModelPolicy.selectForHardware(
        totalRamGb: 3.9,
        availableRamGb: 2,
        freeStorageBytes: AutomaticModelPolicy.requiredDownloadStorageBytes(
          AutomaticModelPolicy.maxAiLite,
        ),
      );

      expect(selected, isA<SelectedLocalModel>());
      expect(selected, isNot(isA<List<SelectedLocalModel>>()));
      expect(
        [AutomaticModelPolicy.maxAiLite, AutomaticModelPolicy.maxAiPro],
        hasLength(2),
      );
    });

    test('uses pinned verified Q4_K_M public GGUF artifacts', () {
      expect(
        AutomaticModelPolicy.maxAiLite.downloadUrl,
        'https://huggingface.co/bartowski/Qwen_Qwen3-0.6B-GGUF/resolve/7bcae0bc7b0606f1e948f8cdb31b98a2c10635db/Qwen_Qwen3-0.6B-Q4_K_M.gguf',
      );
      expect(
        AutomaticModelPolicy.maxAiLite.sha256,
        '9acfc1e001311f34b4252001b626f2e466d592a42065f66571bff3790d4e1b14',
      );
      expect(
        AutomaticModelPolicy.maxAiPro.downloadUrl,
        'https://huggingface.co/Qwen/Qwen3-4B-GGUF/resolve/a9a60d009fa7ff9606305047c2bf77ac25dbec49/Qwen3-4B-Q4_K_M.gguf',
      );
      expect(
        AutomaticModelPolicy.maxAiPro.sha256,
        '7485fe6f11af29433bc51cab58009521f205840f5b4ae3a32fa7f92e8534fdf5',
      );
      expect(AutomaticModelPolicy.maxAiLite.licenseSummary, contains('Apache'));
      expect(AutomaticModelPolicy.maxAiPro.licenseSummary, contains('Apache'));
    });
  });

  test('RAM detection failure leaves local inference unavailable safely',
      () async {
    final service = ModelSelectionService(
      availableRamReader: () async => throw StateError('memory unavailable'),
      totalRamReader: () async => throw StateError('memory unavailable'),
      availableStorageReader: () async => null,
    );

    await service.init();

    expect(service.ramDetectionStatus.value, RamDetectionStatus.unavailable);
    expect(service.availableRamGb.value, isNull);
    expect(service.selectedModel.value, isNull);
    expect(
      service.selectionMessage.value,
      contains('could not verify the minimum device memory'),
    );
  });

  test(
      'missing storage cannot select a model, but missing free RAM selects Lite',
      () {
    expect(
      AutomaticModelPolicy.selectForHardware(
        totalRamGb: 8,
        availableRamGb: 5,
        freeStorageBytes: null,
      ),
      isNull,
    );
    expect(
      AutomaticModelPolicy.selectForHardware(
        totalRamGb: 8,
        availableRamGb: null,
        freeStorageBytes: 6 * 1024 * 1024 * 1024,
      ),
      same(AutomaticModelPolicy.maxAiLite),
    );
  });

  test('eligible devices use total RAM and available storage for selection',
      () async {
    Get.testMode = true;
    addTearDown(Get.reset);
    Get.put(DeviceEligibilityService(
      totalRamReader: () async => 8.0,
      freeStorageReader: () async =>
          AutomaticModelPolicy.requiredDownloadStorageBytes(
        AutomaticModelPolicy.maxAiPro,
      ),
    ));
    final service = ModelSelectionService(availableRamReader: () async => 5.0);

    await service.init();

    expect(service.selectedModel.value, AutomaticModelPolicy.maxAiPro);
  });
}
