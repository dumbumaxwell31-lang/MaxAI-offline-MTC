import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maxai/services/automatic_model_download_service.dart';
import 'package:maxai/services/model_selection_service.dart';

SelectedLocalModel _model(String sha) => SelectedLocalModel(
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
      sha256: sha,
      minimumAvailableRamGb: 0,
      maxContextSize: 64,
      maxOutputTokens: 16,
    );

void main() {
  const bytes = <int>[0x47, 0x47, 0x55, 0x46, 1, 2, 3, 4, 5, 6];

  test('accepts a GGUF file whose SHA-256 matches', () async {
    final directory = await Directory.systemTemp.createTemp('maxai-test-');
    addTearDown(() => directory.delete(recursive: true));
    final path = '${directory.path}${Platform.pathSeparator}test.gguf';
    await File(path).writeAsBytes(bytes);

    final result = await ModelFileValidator.validate(
      path: path,
      model: _model(sha256.convert(bytes).toString()),
    );

    expect(result.message, 'Model file is valid.');
    // A second pass uses the verification marker and stays valid.
    final cached = await ModelFileValidator.validate(
      path: path,
      model: _model(sha256.convert(bytes).toString()),
    );
    expect(cached.isValid, isTrue);
  });

  test('rejects a GGUF file whose SHA-256 differs', () async {
    final directory = await Directory.systemTemp.createTemp('maxai-test-');
    addTearDown(() => directory.delete(recursive: true));
    final path = '${directory.path}${Platform.pathSeparator}test.gguf';
    await File(path).writeAsBytes(bytes);

    final result = await ModelFileValidator.validate(
      path: path,
      model: _model('0' * 64),
    );

    expect(result.isValid, isFalse);
    expect(result.message, contains('checksum'));
  });
}
