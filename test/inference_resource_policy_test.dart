import 'package:flutter_test/flutter_test.dart';
import 'package:maxai/services/inference_resource_policy.dart';
import 'package:maxai/services/model_selection_service.dart';

void main() {
  group('InferenceResourcePolicy', () {
    test('offers long-response Lite limits when available RAM is ample', () {
      final limits = InferenceResourcePolicy.forAvailableRam(
        availableRamGb: 3.0,
        modelContextLimit: AutomaticModelPolicy.maxliteModel1.maxContextSize,
        modelOutputLimit: AutomaticModelPolicy.maxliteModel1.maxOutputTokens,
      );

      expect(limits.contextSize, 8192);
      expect(limits.maxOutputTokens, 4096);
      expect(limits.explanation, isNull);
    });

    test('keeps the selected Pro model caps unchanged', () {
      final limits = InferenceResourcePolicy.forAvailableRam(
        availableRamGb: 5.0,
        modelContextLimit: AutomaticModelPolicy.maxproModel2.maxContextSize,
        modelOutputLimit: AutomaticModelPolicy.maxproModel2.maxOutputTokens,
      );

      expect(limits.contextSize, 8192);
      expect(limits.maxOutputTokens, 4096);
    });

    test('reduces the profile under memory pressure and explains why', () {
      final limits = InferenceResourcePolicy.forAvailableRam(
        availableRamGb: 1.2,
        modelContextLimit: 8192,
        modelOutputLimit: 4096,
      );

      expect(limits.contextSize, 4096);
      expect(limits.maxOutputTokens, 3072);
      expect(limits.explanation, contains('1.2 GB'));
      expect(limits.explanation, contains('instead of the model maximum'));
    });

    test('uses a conservative profile if available RAM cannot be measured', () {
      final limits = InferenceResourcePolicy.forAvailableRam(
        availableRamGb: null,
        modelContextLimit: 8192,
        modelOutputLimit: 4096,
      );

      expect(limits.contextSize, 512);
      expect(limits.maxOutputTokens, 128);
      expect(limits.explanation, contains('could not be measured'));
    });

    test('all model choices have output room for long responses', () {
      for (final model in AutomaticModelPolicy.supportedModels) {
        expect(model.maxContextSize, 8192);
        expect(model.maxOutputTokens, 4096);
      }
    });

    test('retries allocation failures with smaller contexts to a safe floor',
        () {
      expect(
        InferenceResourcePolicy.contextRetrySequence(8192),
        [8192, 4096, 2048, 1024, 512],
      );
      expect(
        InferenceResourcePolicy.isAllocationFailure(
          'PlatformException: Failed to create context (out of memory)',
        ),
        isTrue,
      );
      expect(
        InferenceResourcePolicy.isAllocationFailure('Invalid GGUF header'),
        isFalse,
      );
      expect(
        InferenceResourcePolicy.allocationFailureMessage('OutOfMemoryError'),
        contains('saved settings'),
      );
    });

    test('limits output according to both model and active context', () {
      expect(
        InferenceResourcePolicy.outputLimitForContext(
          contextSize: 2048,
          configuredOutputLimit: 4096,
          modelOutputLimit: 4096,
        ),
        1536,
      );
      expect(
        InferenceResourcePolicy.outputLimitForContext(
          contextSize: 8192,
          configuredOutputLimit: 4096,
          modelOutputLimit: 4096,
        ),
        4096,
      );
    });
  });
}
