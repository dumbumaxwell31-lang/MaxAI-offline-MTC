import 'package:flutter_test/flutter_test.dart';
import 'package:maxai/services/model_selection_service.dart';

void main() {
  group('AutomaticModelPolicy catalog', () {
    test('contains exactly the four branded model choices', () {
      expect(
        AutomaticModelPolicy.supportedModels.map((model) => model.name),
        [
          'Maxlite Model 1',
          'Maxlite Model 2',
          'MaxPro Model 1',
          'MaxPro Model 2',
        ],
      );
    });

    test('maps all four names to the requested quantized GGUF artifacts', () {
      expect(AutomaticModelPolicy.maxliteModel1.filename,
          'SmolLM2-1.7B-Instruct-Q4_K_M.gguf');
      expect(AutomaticModelPolicy.maxliteModel2.filename,
          'google_gemma-3-1b-it-Q4_K_M.gguf');
      expect(AutomaticModelPolicy.maxproModel1.filename,
          'microsoft_Phi-4-mini-instruct-Q4_K_M.gguf');
      expect(
          AutomaticModelPolicy.maxproModel2.filename, 'Qwen3-4B-Q4_K_M.gguf');
      for (final model in AutomaticModelPolicy.supportedModels) {
        expect(model.quantization, 'Q4_K_M');
        expect(model.downloadUrl, startsWith('https://huggingface.co/'));
        expect(model.expectedFileSizeBytes, greaterThan(700 * 1024 * 1024));
        expect(model.sha256, hasLength(64));
      }
    });

    test('keeps the verified public source URLs and exact sizes', () {
      expect(
        [
          AutomaticModelPolicy.maxliteModel1.downloadUrl,
          AutomaticModelPolicy.maxliteModel2.downloadUrl,
          AutomaticModelPolicy.maxproModel1.downloadUrl,
          AutomaticModelPolicy.maxproModel2.downloadUrl,
        ],
        [
          'https://huggingface.co/bartowski/SmolLM2-1.7B-Instruct-GGUF/resolve/3084dd417b5e2567e786340037cd3b512068fad0/SmolLM2-1.7B-Instruct-Q4_K_M.gguf',
          'https://huggingface.co/bartowski/google_gemma-3-1b-it-GGUF/resolve/116f76234503685a98f572982177b11d44ec8ff1/google_gemma-3-1b-it-Q4_K_M.gguf',
          'https://huggingface.co/bartowski/microsoft_Phi-4-mini-instruct-GGUF/resolve/faffc28d86d0c0781b4ec92d30e400a6d350a53b/microsoft_Phi-4-mini-instruct-Q4_K_M.gguf',
          'https://huggingface.co/Qwen/Qwen3-4B-GGUF/resolve/a9a60d009fa7ff9606305047c2bf77ac25dbec49/Qwen3-4B-Q4_K_M.gguf',
        ],
      );
      expect(
        AutomaticModelPolicy.supportedModels
            .map((model) => model.expectedFileSizeBytes),
        [1055609824, 806058496, 2491874688, 2497280256],
      );
    });

    test('pins known artifact checksums and required license summaries', () {
      expect(AutomaticModelPolicy.maxliteModel1.sha256,
          '77665ea4815999596525c636fbeb56ba8b080b46ae85efef4f0d986a139834d7');
      expect(AutomaticModelPolicy.maxliteModel1.licenseSummary, 'Apache-2.0');
      expect(AutomaticModelPolicy.maxliteModel2.licenseSummary,
          'Google Gemma Terms');
      expect(AutomaticModelPolicy.maxproModel1.licenseSummary, 'MIT');
      expect(AutomaticModelPolicy.maxproModel2.licenseSummary, 'Apache-2.0');
    });

    test('only MaxPro entries require 4 GB total physical RAM', () {
      expect(
        AutomaticModelPolicy.supportedModels
            .where((model) => model.requiresProHardware)
            .map((model) => model.name),
        ['MaxPro Model 1', 'MaxPro Model 2'],
      );
      expect(AutomaticModelPolicy.proMinimumTotalRamGb, 4.0);
    });

    test('maps internal filenames to user-facing names', () {
      expect(
        AutomaticModelPolicy.displayNameForFilename(
          AutomaticModelPolicy.maxliteModel1.filename,
        ),
        'Maxlite Model 1',
      );
      expect(
        AutomaticModelPolicy.displayNameForFilename(
          AutomaticModelPolicy.maxproModel2.filename,
        ),
        'MaxPro Model 2',
      );
      expect(
        AutomaticModelPolicy.displayNameForFilename(
          'Qwen_Qwen3-0.6B-Q4_K_M.gguf',
        ),
        'Maxlite AI Model',
      );
    });
  });

  group('ModelSelectionService hardware-aware choice', () {
    test('allows both Lite choices below 4 GB physical RAM', () async {
      final service = ModelSelectionService(
        totalRamReader: () async => 3.5,
        availableRamReader: () async => 0.5,
        availableStorageReader: () async => 0,
      );
      await service.init();

      expect(service.isModelCompatible(AutomaticModelPolicy.maxliteModel1),
          isTrue);
      expect(service.isModelCompatible(AutomaticModelPolicy.maxliteModel2),
          isTrue);
      expect(service.isModelCompatible(AutomaticModelPolicy.maxproModel1),
          isFalse);
      expect(service.isModelCompatible(AutomaticModelPolicy.maxproModel2),
          isFalse);
    });

    test('allows Pro at exactly 4 GB total physical RAM', () async {
      final service = ModelSelectionService(
        totalRamReader: () async => 4.0,
        availableRamReader: () async => 0.4,
        availableStorageReader: () async => 0,
      );
      await service.init();

      expect(
          service.isModelCompatible(AutomaticModelPolicy.maxproModel1), isTrue);
      expect(
          service.isModelCompatible(AutomaticModelPolicy.maxproModel2), isTrue);
    });

    test('unknown physical RAM keeps Lite available and locks Pro', () async {
      final service = ModelSelectionService(
        totalRamReader: () async => throw StateError('memory unavailable'),
        availableRamReader: () async => null,
        availableStorageReader: () async => null,
      );
      await service.init();

      expect(service.ramDetectionStatus.value, RamDetectionStatus.unavailable);
      expect(service.selectedModel.value, AutomaticModelPolicy.maxliteModel1);
      expect(service.isModelCompatible(AutomaticModelPolicy.maxliteModel1),
          isTrue);
      expect(service.isModelCompatible(AutomaticModelPolicy.maxproModel1),
          isFalse);
      expect(service.compatibilityMessage(AutomaticModelPolicy.maxproModel1),
          contains('could not verify physical RAM'));
    });

    test('reports the hardware threshold when Pro is incompatible', () async {
      final service = ModelSelectionService(
        totalRamReader: () async => 3.99,
        availableRamReader: () async => 2,
        availableStorageReader: () async => 0,
      );
      await service.init();

      expect(
        service.compatibilityMessage(AutomaticModelPolicy.maxproModel2),
        'Requires at least 4GB RAM. Incompatible with this device.',
      );
    });

    test('selects a compatible model without auto-downloading it', () async {
      final service = ModelSelectionService(
        totalRamReader: () async => 6,
        availableRamReader: () async => 2,
        availableStorageReader: () async => 0,
      );
      await service.init();

      expect(
        await service.selectModel(AutomaticModelPolicy.maxproModel2.identifier),
        isTrue,
      );
      expect(service.selectedModel.value, AutomaticModelPolicy.maxproModel2);
    });
  });

  group('MaxPro slow-phone warning', () {
    Future<ModelSelectionService> serviceWithRam(double? ram) async {
      final service = ModelSelectionService(
        totalRamReader: () async => ram,
        availableRamReader: () async => 1.0,
        availableStorageReader: () async => 0,
      );
      await service.init();
      return service;
    }

    test('warns for Pro models on 4 GB up to below 8 GB phones', () async {
      // 4 GB, 6 GB (reports ~5.2) and 6.9 GB reported.
      for (final ram in [4.0, 5.2, 6.9]) {
        final service = await serviceWithRam(ram);
        expect(
            service.isSlowOnThisDevice(AutomaticModelPolicy.maxproModel1),
            isTrue,
            reason: '$ram GB');
        expect(
            service.isSlowOnThisDevice(AutomaticModelPolicy.maxproModel2),
            isTrue,
            reason: '$ram GB');
      }
    });

    test('does not warn on 8 GB phones, which report about 7.2-7.7 GB',
        () async {
      for (final ram in [7.2, 7.6, 11.2]) {
        final service = await serviceWithRam(ram);
        expect(
            service.isSlowOnThisDevice(AutomaticModelPolicy.maxproModel2),
            isFalse,
            reason: '$ram GB');
      }
    });

    test('never warns for Lite models or incompatible phones', () async {
      final mid = await serviceWithRam(5.2);
      expect(
          mid.isSlowOnThisDevice(AutomaticModelPolicy.maxliteModel1), isFalse);
      expect(
          mid.isSlowOnThisDevice(AutomaticModelPolicy.maxliteModel2), isFalse);

      for (final ram in [3.5, null]) {
        final low = await serviceWithRam(ram);
        expect(low.isSlowOnThisDevice(AutomaticModelPolicy.maxproModel2),
            isFalse,
            reason: 'Pro is blocked, not slow, at $ram');
      }
    });
  });
}
