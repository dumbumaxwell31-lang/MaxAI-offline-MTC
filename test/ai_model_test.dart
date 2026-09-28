import 'package:flutter_test/flutter_test.dart';
import 'package:maxai/models/ai_model.dart';

void main() {
  group('AiModel.hasVisionMarker', () {
    test('does not classify text-only Gemma 4 bundles as vision models', () {
      expect(
        AiModel.hasVisionMarker('Gemma-4-E2B-Abliterated.gguf'),
        isFalse,
      );
    });

    test('recognizes unambiguous vision model markers', () {
      expect(AiModel.hasVisionMarker('Qwen2-VL-Instruct.gguf'), isTrue);
      expect(AiModel.hasVisionMarker('LLaVA-Next.gguf'), isTrue);
      expect(AiModel.hasVisionMarker('mobile-vision-model.gguf'), isTrue);
    });
  });
}
