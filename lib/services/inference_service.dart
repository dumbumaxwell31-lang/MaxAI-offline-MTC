import 'dart:async';
import 'dart:math' as math;
import 'package:get/get.dart';
import 'hive_service.dart';
import '../core/constants.dart';
import 'device_info_service.dart';
import 'app_log_service.dart';
import 'model_selection_service.dart';
import 'inference_resource_policy.dart';

// Conditionally import llama_flutter_android — only on Android
import 'inference_android.dart' as platform;

/// Cross-platform inference service.
class InferenceService extends GetxService {
  final HiveService _hive = Get.find<HiveService>();

  // ── Observable State ──
  final isModelLoaded = false.obs;
  final isGenerating = false.obs;
  final isLoadingModel = false.obs;
  final isVisionLoaded = false.obs;
  final loadingModelName = ''.obs;
  final loadedModelName = ''.obs;
  final tokenCount = 0.obs;
  final tokensPerSecond = 0.0.obs;
  final contextTokensUsed = 0.obs;
  final contextTokensTotal = 0.obs;
  final modelLoadProgress = 0.0.obs;
  final generationSource = ''.obs;
  final streamingText = ''.obs;
  final gpuName = ''.obs;
  final gpuLayersUsed = 0.obs;
  final isGpuAccelerated = false.obs;
  final loadedModelRuntime = ''.obs;
  final loadedBackend = ''.obs;
  final resourceConfigurationNotice = ''.obs;

  /// Whether the current platform supports local inference.
  bool get supportsLocalInference => platform.supportsLocalInference;

  // Platform-specific engine
  platform.InferenceEngine? _engine;
  int _activeMaxOutputTokens = 0;
  Future<String> loadModel(
    String modelPath, {
    String? modelName,
  }) async {
    if (!supportsLocalInference) {
      return 'ERROR: Local inference is not available on this platform. Use Cloud mode.';
    }
    if (isLoadingModel.value) return 'ERROR: Model is already loading.';
    if (!modelPath.toLowerCase().endsWith('.gguf')) {
      return 'ERROR: Local inference supports GGUF model files only.';
    }

    try {
      await unloadModel();
      isLoadingModel.value = true;
      loadingModelName.value = modelName ?? modelPath.split('/').last;
      modelLoadProgress.value = 0.0;

      final configuredContextSize = _hive.getSetting<int>(
            AppConstants.keyContextSize,
            defaultValue: AppConstants.defaultContextSize,
          ) ??
          AppConstants.defaultContextSize;
      final selectedModel = Get.isRegistered<ModelSelectionService>()
          ? Get.find<ModelSelectionService>().selectedModel.value
          : null;
      final requestedModelName = modelName ?? modelPath.split('/').last;
      final isSelectedModel = selectedModel != null &&
          (requestedModelName == selectedModel.filename ||
              modelPath.endsWith(selectedModel.filename));
      final configuredMaxTokens = _hive.getSetting<int>(
            AppConstants.keyMaxTokens,
            defaultValue: AppConstants.defaultMaxTokens,
          ) ??
          AppConstants.defaultMaxTokens;
      final modelContextLimit = isSelectedModel
          ? selectedModel.maxContextSize
          : configuredContextSize;
      final modelOutputLimit = isSelectedModel
          ? selectedModel.maxOutputTokens
          : configuredMaxTokens;

      double? availableRamGb;
      if (Get.isRegistered<DeviceInfoService>()) {
        final deviceInfo = Get.find<DeviceInfoService>();
        await deviceInfo.refreshMemoryInfo();
        if (deviceInfo.hasAvailableRamMeasurement.value) {
          availableRamGb = deviceInfo.availableRamGB.value;
        }
      }
      final resourceLimits = InferenceResourcePolicy.forAvailableRam(
        availableRamGb: availableRamGb,
        modelContextLimit: modelContextLimit,
        modelOutputLimit: modelOutputLimit,
      );
      final requestedContextSize = isSelectedModel
          ? math.min(configuredContextSize, modelContextLimit).toInt()
          : configuredContextSize;
      var contextSize = math
          .min(requestedContextSize, resourceLimits.contextSize)
          .toInt();
      final runtimeOutputLimit = math.min(
        configuredMaxTokens,
        resourceLimits.maxOutputTokens,
      );
      final configuredOutputForContext =
          InferenceResourcePolicy.outputLimitForContext(
        contextSize: contextSize,
        configuredOutputLimit: runtimeOutputLimit,
        modelOutputLimit: modelOutputLimit,
      );
      final notices = <String>[];
      if (resourceLimits.explanation != null) {
        notices.add(resourceLimits.explanation!);
      }
      if (contextSize < modelContextLimit ||
          configuredOutputForContext < modelOutputLimit) {
        notices.add(
          'Active limits are $contextSize context / '
          '$configuredOutputForContext output tokens; model maximum is '
          '$modelContextLimit / $modelOutputLimit. Saved settings are retained.',
        );
      }
      resourceConfigurationNotice.value = notices.join(' ');

      final deviceTier = _getDeviceTier();
      final isTensorSoC = _getIsTensorSoC();

      var activeModelName = requestedModelName;
      platform.LoadResult? loadResult;
      final contextAttempts =
          InferenceResourcePolicy.contextRetrySequence(contextSize);
      for (var attempt = 0; attempt < contextAttempts.length; attempt++) {
        contextSize = contextAttempts[attempt];
        final engine = platform.InferenceEngine();
        platform.LoadResult result;
        try {
          result = await engine.loadModel(
            modelPath: modelPath,
            contextSize: contextSize,
            deviceTier: deviceTier,
            isTensorSoC: isTensorSoC,
            onProgress: (p) => modelLoadProgress.value = p,
          );
        } catch (error) {
          if (error.toString().toLowerCase().contains('model already loaded')) {
            final savedModelName =
                _hive.getSetting<String>(AppConstants.keyLocalModelName) ?? '';
            activeModelName = savedModelName.isNotEmpty
                ? savedModelName
                : requestedModelName;
            _engine = engine;
            loadResult = platform.LoadResult(
              success: true,
              message: savedModelName == requestedModelName
                  ? 'Model already loaded.'
                  : 'A native model is already loaded. Unload it before loading another model.',
              runtime: 'llama',
              backend: _hive.getSetting<String>(
                      AppConstants.keyLocalModelBackend) ??
                  '',
            );
            break;
          }

          await engine.dispose();
          if (InferenceResourcePolicy.isAllocationFailure(error) &&
              attempt + 1 < contextAttempts.length) {
            final nextContext = contextAttempts[attempt + 1];
            final nextOutput = InferenceResourcePolicy.outputLimitForContext(
              contextSize: nextContext,
              configuredOutputLimit: runtimeOutputLimit,
              modelOutputLimit: modelOutputLimit,
            );
            resourceConfigurationNotice.value =
                'The native runtime could not allocate the requested context. '
                'MaxAI retried with $nextContext context and up to '
                '$nextOutput output tokens. Saved limits were not changed.';
            continue;
          }
          rethrow;
        }

        if (!result.success &&
            result.message.toLowerCase().contains('model already loaded')) {
          final savedModelName =
              _hive.getSetting<String>(AppConstants.keyLocalModelName) ?? '';
          activeModelName = savedModelName.isNotEmpty
              ? savedModelName
              : requestedModelName;
          _engine = engine;
          loadResult = platform.LoadResult(
            success: true,
            message: savedModelName == requestedModelName
                ? 'Model already loaded.'
                : 'A native model is already loaded. Unload it before loading another model.',
            runtime: 'llama',
            backend:
                _hive.getSetting<String>(AppConstants.keyLocalModelBackend) ??
                    '',
          );
          break;
        }

        if (!result.success &&
            InferenceResourcePolicy.isAllocationFailure(result.message) &&
            attempt + 1 < contextAttempts.length) {
          await engine.dispose();
          final nextContext = contextAttempts[attempt + 1];
          final nextOutput = InferenceResourcePolicy.outputLimitForContext(
            contextSize: nextContext,
            configuredOutputLimit: runtimeOutputLimit,
            modelOutputLimit: modelOutputLimit,
          );
          resourceConfigurationNotice.value =
              'The native runtime could not allocate the requested context. '
              'MaxAI retried with $nextContext context and up to '
              '$nextOutput output tokens. Saved limits were not changed.';
          continue;
        }

        if (result.success) {
          _engine = engine;
        } else {
          await engine.dispose();
        }
        loadResult = result;
        break;
      }

      final result = loadResult;
      if (result == null) {
        throw StateError('No inference context could be created.');
      }

      if (!result.success) {
        isModelLoaded.value = false;
        isLoadingModel.value = false;
        loadingModelName.value = '';
        modelLoadProgress.value = 0.0;
        loadedModelName.value = '';
        loadedModelRuntime.value = '';
        loadedBackend.value = '';
        gpuName.value = '';
        gpuLayersUsed.value = 0;
        isGpuAccelerated.value = false;
        Get.find<AppLogService>().error(
          'Local model load failed',
          details:
              'model=$requestedModelName, runtime=llama, backend=${result.backend}, message=${result.message}',
        );
        if (InferenceResourcePolicy.isAllocationFailure(result.message)) {
          resourceConfigurationNotice.value =
              InferenceResourcePolicy.allocationFailureMessage(result.message);
          return 'ERROR: ${resourceConfigurationNotice.value}';
        }
        return result.message;
      }

      isModelLoaded.value = result.success;
      isLoadingModel.value = false;
      loadingModelName.value = '';
      modelLoadProgress.value = 1.0;
      loadedModelName.value = activeModelName;
      loadedModelRuntime.value = result.runtime;
      loadedBackend.value = result.backend;
      gpuName.value = result.gpuName;
      gpuLayersUsed.value = result.gpuLayers;
      isGpuAccelerated.value = result.backend == 'gpu' || result.gpuLayers > 0;
      contextTokensUsed.value = 0;
      contextTokensTotal.value = contextSize;
      _activeMaxOutputTokens = InferenceResourcePolicy.outputLimitForContext(
        contextSize: contextSize,
        configuredOutputLimit: runtimeOutputLimit,
        modelOutputLimit: modelOutputLimit,
      );

      await _hive.setSetting(AppConstants.keyLocalModelPath, modelPath);
      await _hive.setSetting(
          AppConstants.keyLocalModelName, loadedModelName.value);
      await _hive.setSetting(
          AppConstants.keyLocalModelRuntime, loadedModelRuntime.value);
      await _hive.setSetting(
          AppConstants.keyLocalModelBackend, loadedBackend.value);

      return result.message;
    } catch (e) {
      final failedEngine = _engine;
      _engine = null;
      if (failedEngine != null) await failedEngine.dispose();
      isModelLoaded.value = false;
      isLoadingModel.value = false;
      loadingModelName.value = '';
      modelLoadProgress.value = 0.0;
      loadedBackend.value = '';
      Get.find<AppLogService>().error('Failed to load local model', details: e);
      if (InferenceResourcePolicy.isAllocationFailure(e)) {
        resourceConfigurationNotice.value =
            InferenceResourcePolicy.allocationFailureMessage(e);
      }
      return 'ERROR: Failed to load model — $e';
    }
  }

  Future<void> unloadModel() async {
    final engine = _engine;
    _engine = null;
    if (engine != null) {
      await stopGeneration();
      await engine.dispose();
    }
    isModelLoaded.value = false;
    isVisionLoaded.value = false;
    loadedModelName.value = '';
    loadingModelName.value = '';
    loadedModelRuntime.value = '';
    loadedBackend.value = '';
    gpuLayersUsed.value = 0;
    isGpuAccelerated.value = false;
    gpuName.value = '';
    contextTokensUsed.value = 0;
    contextTokensTotal.value = 0;
    _activeMaxOutputTokens = 0;
    resourceConfigurationNotice.value = '';
  }

  Future<String> generate({
    required String prompt,
    String? systemPrompt,
    List<Map<String, String>>? conversationHistory,
    String source = 'chat',
    String? imagePath,
    String? audioPath,
    void Function(String token)? onToken,
  }) async {
    if (!supportsLocalInference || _engine == null || !isModelLoaded.value) {
      return 'ERROR: No model loaded. Go to Models tab to download and load one.';
    }

    if (isGenerating.value) {
      // Wait for previous generation
      for (int i = 0; i < 10; i++) {
        await Future.delayed(const Duration(milliseconds: 500));
        if (!isGenerating.value) break;
      }
      if (isGenerating.value) {
        await stopGeneration();
        await Future.delayed(const Duration(milliseconds: 300));
      }
    }

    isGenerating.value = true;
    tokenCount.value = 0;
    tokensPerSecond.value = 0.0;
    generationSource.value = source;
    streamingText.value = '';

    final startTime = DateTime.now();
    DateTime? firstVisibleTokenAt;
    try {
      final temperature = _hive.getSetting<double>(
            AppConstants.keyTemperature,
            defaultValue: AppConstants.defaultTemperature,
          ) ??
          AppConstants.defaultTemperature;

      final configuredMaxTokens = _hive.getSetting<int>(
            AppConstants.keyMaxTokens,
            defaultValue: AppConstants.defaultMaxTokens,
          ) ??
          AppConstants.defaultMaxTokens;
      final selectedModel = Get.isRegistered<ModelSelectionService>()
          ? Get.find<ModelSelectionService>().selectedModel.value
          : null;
      final contextLimit = contextTokensTotal.value > 0
          ? contextTokensTotal.value
          : selectedModel?.maxContextSize ?? AppConstants.defaultContextSize;
      final modelOutputLimit = selectedModel != null &&
              selectedModel.filename == loadedModelName.value
          ? selectedModel.maxOutputTokens
          : configuredMaxTokens;
      final maxTokens = math.min(
        math.min(
          math.min(configuredMaxTokens, modelOutputLimit),
          _activeMaxOutputTokens > 0
              ? _activeMaxOutputTokens
              : modelOutputLimit,
        ),
        math.max(
          1,
          InferenceResourcePolicy.outputLimitForContext(
            contextSize: contextLimit,
            configuredOutputLimit: modelOutputLimit,
            modelOutputLimit: modelOutputLimit,
          ),
        ),
      );

      final result = await _engine!.generate(
        prompt: prompt,
        conversationHistory: conversationHistory,
        systemPrompt: systemPrompt ?? AppConstants.systemPrompt,
        modelName: loadedModelName.value,
        maxTokens: maxTokens,
        temperature: temperature,
        imagePath: imagePath,
        audioPath: audioPath,
        onToken: (token) {
          firstVisibleTokenAt ??= DateTime.now();
          tokenCount.value++;
          streamingText.value += token;
          final speedStart = firstVisibleTokenAt ?? startTime;
          final elapsedSeconds =
              DateTime.now().difference(speedStart).inMilliseconds / 1000.0;
          if (elapsedSeconds > 0) {
            tokensPerSecond.value = tokenCount.value / elapsedSeconds;
          }
          onToken?.call(token);
        },
      );
      await refreshContextInfo();
      isGenerating.value = false;
      generationSource.value = '';

      if (result.startsWith('ERROR:') &&
          InferenceResourcePolicy.isAllocationFailure(result)) {
        resourceConfigurationNotice.value =
            InferenceResourcePolicy.allocationFailureMessage(result);
        return 'ERROR: ${resourceConfigurationNotice.value}';
      }

      // Detect Tensor SoC + Gemma Q4_K_M corruption: model outputs only
      // special tokens and terminates immediately with empty result.
      if (result.trim().isEmpty &&
          tokenCount.value < 5 &&
          loadedModelName.value.toLowerCase().contains('gemma')) {
        final isTensor = _getIsTensorSoC();
        if (isTensor) {
          return '⚠️ This Gemma model is incompatible with your Pixel\'s Google Tensor chip. '
              'The Q4_K_M quantization format has a known bug on Tensor SoC that produces empty responses.\n\n'
              'Try one of these fixes:\n'
              '1. Download a Q4_0 or Q5_K_M version of the same model\n'
              '2. Use a different model (Qwen, Phi, or Llama-3)\n'
              '3. Switch to Cloud mode in Settings';
        }
      }

      return result;
    } catch (e) {
      isGenerating.value = false;
      generationSource.value = '';
      streamingText.value = '';
      Get.find<AppLogService>().error('Local generation failed', details: e);
      if (InferenceResourcePolicy.isAllocationFailure(e)) {
        resourceConfigurationNotice.value =
            InferenceResourcePolicy.allocationFailureMessage(e);
        return 'ERROR: ${resourceConfigurationNotice.value}';
      }
      return 'ERROR: $e';
    }
  }

  Future<void> stopGeneration() async {
    isGenerating.value = false;
    tokenCount.value = 0;
    generationSource.value = '';
    streamingText.value = '';
    final engine = _engine;
    if (engine != null) {
      unawaited(engine.stop().timeout(const Duration(seconds: 1)).catchError(
            (_) {},
          ));
    }
  }

  /// Reset the native conversation context. Call this whenever the user
  /// switches to a different chat session so old context doesn't leak.
  Future<void> resetConversation() async {
    final engine = _engine;
    if (engine != null) {
      await engine.resetConversation();
    }
  }

  Future<void> refreshContextInfo() async {
    if (!supportsLocalInference || _engine == null || !isModelLoaded.value) {
      return;
    }

    final info = await _engine!.getContextInfo();
    if (info == null) return;

    contextTokensUsed.value = info.tokensUsed;
    contextTokensTotal.value = info.contextSize;
  }

  String _getDeviceTier() {
    try {
      final device = Get.find<DeviceInfoService>();
      return device.deviceTier.value;
    } catch (_) {
      return 'mid';
    }
  }

  bool _getIsTensorSoC() {
    try {
      final device = Get.find<DeviceInfoService>();
      return device.isTensorSoC.value;
    } catch (_) {
      return false;
    }
  }
}
