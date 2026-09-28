import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' as math;
import 'package:llama_flutter_android/llama_flutter_android.dart';
import '../utils/thought_parser.dart';
import '../utils/local_prompt_window.dart';

/// Whether the current platform supports local inference.
bool get supportsLocalInference => Platform.isAndroid;

/// Result from model loading.
class LoadResult {
  final bool success;
  final String message;
  final String gpuName;
  final int gpuLayers;
  final String runtime;
  final String backend;
  LoadResult({
    required this.success,
    required this.message,
    this.gpuName = '',
    this.gpuLayers = 0,
    this.runtime = '',
    this.backend = '',
  });
}

/// Android inference engine that wraps llama_flutter_android.
class InferenceEngine {
  LlamaController? _controller;
  StreamSubscription? _subscription;
  StreamSubscription? _loadProgressSub;
  Timer? _idleTimer;
  void Function()? _onStop;
  bool _disposed = false;
  bool _hasLoadedModel = false;
  int _contextSize = 1024;
  int _outputTokenLimit = 256;

  Future<LoadResult> loadModel({
    required String modelPath,
    required int contextSize,
    required String deviceTier,
    bool isTensorSoC = false,
    void Function(double)? onProgress,
  }) async {
    _disposed = false;
    _contextSize = contextSize;
    _controller = LlamaController();

    // ── GPU Detection ──
    int gpuLayers = 0;
    String gpuNameStr = '';

    try {
      final gpu = await _controller!.detectGpu();
      gpuNameStr = gpu.gpuName;

      print('[Inference] GPU: ${gpu.gpuName}');
      print('[Inference]   Vulkan: ${gpu.vulkanSupported}');
      print('[Inference]   Free RAM: ${gpu.freeRamBytes ~/ 1024 ~/ 1024}MB');
      print('[Inference]   Recommended layers: ${gpu.recommendedGpuLayers}');

      if (gpu.vulkanSupported && gpu.recommendedGpuLayers > 0) {
        final gpuNum = _extractGpuModel(gpu.gpuName);
        if (gpuNum >= 700) {
          gpuLayers = 99;
          print('[Inference] ✓ High-end GPU ($gpuNum) → full offload');
        } else if (gpuNum >= 650) {
          gpuLayers = gpu.recommendedGpuLayers;
          print('[Inference] ✓ Upper-mid GPU ($gpuNum) → $gpuLayers layers');
        } else {
          gpuLayers = 0;
          print(
              '[Inference] Mid-range GPU ($gpuNum) — CPU is faster, skipping GPU');
        }
      }
    } catch (e) {
      print('[Inference] GPU detection failed: $e — CPU fallback');
    }

    // ── Thread Tuning ──
    int threads;
    if (gpuLayers > 0) {
      threads = deviceTier == 'ultra'
          ? 4
          : deviceTier == 'high'
              ? 4
              : 4;
    } else {
      threads = deviceTier == 'ultra'
          ? 6
          : deviceTier == 'high'
              ? 5
              : deviceTier == 'mid'
                  ? 4
                  : 3;
    }

    // Google Tensor SoC (Pixel 6/7/8) has known Q4_K_M dequant bugs
    // that corrupt logits at >1 thread on Gemma models. Force single-threaded
    // to eliminate KV cache races in the quantization dot-product path.
    final modelName = modelPath.toLowerCase();
    if (isTensorSoC && modelName.contains('gemma')) {
      threads = 1;
      print(
          '[Inference] Tensor SoC + Gemma detected — forcing single-threaded inference');
    }

    // ── Load Progress ──
    threads = threads.clamp(1, Platform.numberOfProcessors);
    await _loadProgressSub?.cancel();
    _loadProgressSub = null;
    try {
      _loadProgressSub = _controller!.loadProgress.listen((progress) {
        onProgress?.call(_normalizeProgress(progress));
      });
    } catch (_) {}

    // ── Load ──
    try {
      await _controller!.loadModel(
        modelPath: modelPath,
        threads: threads,
        contextSize: contextSize,
        gpuLayers: gpuLayers,
      );
      _hasLoadedModel = true;
    } catch (error) {
      if (!error.toString().toLowerCase().contains('model already loaded')) {
        await _loadProgressSub?.cancel();
        _loadProgressSub = null;
        try {
          await _controller?.dispose();
        } catch (_) {}
        _controller = null;
        _disposed = true;
      }
      rethrow;
    }

    final accel = gpuLayers > 0
        ? 'GPU ($gpuLayers layers, $gpuNameStr)'
        : 'CPU ($threads threads)';
    print('[Inference] ✓ Model loaded: $accel, ctx=$contextSize');

    return LoadResult(
      success: true,
      message: 'Model loaded ($accel).',
      gpuName: gpuNameStr,
      gpuLayers: gpuLayers,
      runtime: 'llama',
      backend: gpuLayers > 0 ? 'gpu' : 'cpu',
    );
  }

  double _normalizeProgress(double progress) {
    if (progress.isNaN || progress.isInfinite) return 0.0;
    final normalized = progress > 1 ? progress / 100 : progress;
    return normalized.clamp(0.0, 1.0).toDouble();
  }

  Future<String> generate({
    required String prompt,
    List<Map<String, String>>? conversationHistory,
    required String systemPrompt,
    required String modelName,
    required int maxTokens,
    required double temperature,
    String? imagePath,
    String? audioPath,
    void Function(String token)? onToken,
  }) async {
    if (_controller == null) throw Exception('No model loaded');
    _outputTokenLimit = maxTokens;
    if (imagePath != null && imagePath.isNotEmpty) {
      return 'Image input is not supported by local text models in this build.';
    }
    if (audioPath != null && audioPath.isNotEmpty) {
      return 'Audio input is not supported by local text models in this build.';
    }

    final completer = Completer<String>();
    final buffer = StringBuffer();
    bool completed = false;

    void finish(String result) {
      if (!completed && !_disposed) {
        completed = true;
        _idleTimer?.cancel();
        _subscription?.cancel();
        _onStop = null;
        if (!completer.isCompleted) completer.complete(result);
      }
    }

    final qwen3Model = modelName.toLowerCase().contains('qwen3');
    final thoughtFilter = qwen3Model ? ThoughtOutputFilter() : null;

    void emitFilteredTail() {
      final tail = thoughtFilter?.finish() ?? '';
      if (tail.isEmpty) return;
      buffer.write(tail);
      onToken?.call(tail);
    }

    void finishWithVisibleText(String result) {
      if (result == buffer.toString()) {
        emitFilteredTail();
        result = buffer.toString();
      }
      finish(result);
    }

    _onStop = () => finishWithVisibleText(buffer.toString());

    // Each request contains the full conversation, so discard the previous KV cache.
    await _controller!.clearContext();

    // ── Use generateChat() for native template handling ──
    Stream<String>? stream;
    try {
      final messages = _buildChatMessages(
        prompt,
        conversationHistory,
        systemPrompt,
        imagePath: imagePath,
        qwen3Model: qwen3Model,
      );
      stream = _controller!.generateChat(
        messages: messages,
        template: null,
        maxTokens: maxTokens,
        temperature: temperature,
        topP: qwen3Model ? 0.8 : 0.9,
        topK: qwen3Model ? 20 : 40,
        minP: qwen3Model ? 0 : 0.05,
        repeatPenalty: 1.1,
        presencePenalty: qwen3Model ? 1.5 : 0,
        repeatLastN: 64,
      );
      print('[Inference] generateChat() started (${messages.length} messages)');
    } catch (e) {
      print('[Inference] generateChat() failed: $e — fallback to generate()');
      try {
        await _controller!.stop();
      } catch (_) {}
      await Future.delayed(const Duration(milliseconds: 100));
      final fullPrompt =
          _buildPrompt(prompt, conversationHistory, systemPrompt, modelName);
      stream = _controller!.generate(
        prompt: fullPrompt,
        maxTokens: maxTokens,
        temperature: temperature,
        topP: qwen3Model ? 0.8 : 0.9,
        topK: qwen3Model ? 20 : 40,
        minP: qwen3Model ? 0 : 0.05,
        repeatPenalty: 1.1,
        presencePenalty: qwen3Model ? 1.5 : 0,
        repeatLastN: 64,
      );
    }

    int tokenCount = 0;
    _subscription = stream.listen(
      (token) {
        if (tokenCount == 0) {
          print('[Inference] ✓ FIRST TOKEN received! Prefill done.');
        }
        final clean = _sanitizeGemmaGarbage(token);
        if (clean.isEmpty) return;
        final visible = thoughtFilter?.add(clean) ?? clean;
        if (visible.isEmpty) return;
        buffer.write(visible);
        tokenCount++;
        onToken?.call(visible);
        _idleTimer?.cancel();
        _idleTimer = Timer(const Duration(seconds: 5), () {
          print('[Inference] Idle timeout — $tokenCount tokens');
          finishWithVisibleText(buffer.toString());
        });
      },
      onDone: () {
        print('[Inference] Stream onDone — $tokenCount tokens total');
        finishWithVisibleText(buffer.toString());
      },
      onError: (error) {
        print('[Inference] Stream error: $error');
        finish('ERROR: Generation failed — $error');
      },
    );

    // Prefill timeout
    _idleTimer = Timer(const Duration(seconds: 60), () {
      if (tokenCount == 0) {
        finishWithVisibleText(
            'ERROR: Model did not respond. Try a smaller model or shorter conversation.');
      }
    });

    // Hard timeout
    Future.delayed(const Duration(seconds: 180), () {
      if (!completed) {
        final partial = buffer.toString();
        finishWithVisibleText(
            partial.isEmpty ? 'ERROR: Generation timed out.' : partial);
      }
    });

    return await completer.future;
  }

  Future<void> stop() async {
    if (_disposed) return;
    _idleTimer?.cancel();
    final stopCallback = _onStop;
    _onStop = null;
    stopCallback?.call();
    unawaited(_subscription?.cancel() ?? Future<void>.value());
    try {
      await _controller?.stop().timeout(const Duration(milliseconds: 800));
    } catch (_) {}
  }

  /// Reset any persistent conversation state so the next generation
  /// starts with a clean context. Essential when switching chat sessions.
  Future<void> resetConversation() async {
    // llama.cpp (GGUF) is stateless per-generation — no native
    // conversation object to reset.
  }

  Future<ContextInfo?> getContextInfo() async {
    try {
      return await _controller?.getContextInfo();
    } catch (_) {
      return null;
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    await stop();
    _disposed = true;
    if (_hasLoadedModel) {
      try {
        await _controller?.dispose();
      } catch (_) {}
    }
    unawaited(_loadProgressSub?.cancel() ?? Future<void>.value());
    _loadProgressSub = null;
    _controller = null;
    _hasLoadedModel = false;
  }

  // ── Helpers ──

  int _extractGpuModel(String gpuName) {
    final match = RegExp(r'(\d{3})').firstMatch(gpuName.toLowerCase());
    return match != null ? (int.tryParse(match.group(1)!) ?? 0) : 0;
  }

  /// Strip Gemma garbage tokens that leak when Q4_K_M dequant is corrupt
  /// on Google Tensor SoC. Harmless on devices that don't produce them.
  /// NOTE: Do NOT trim() — SentencePiece tokens rely on leading spaces.
  String _sanitizeGemmaGarbage(String text) {
    return text
        .replaceAll(RegExp(r'<unused\d+>'), '')
        .replaceAll(RegExp(r'\[@BOS@\]'), '')
        .replaceAll('<bos>', '')
        .replaceAll('<mask>', '')
        .replaceAll('<pad>', '')
        .replaceAll('<unk>', '')
        .replaceAll('<s>', '')
        .replaceAll('</s>', '');
  }

  List<ChatMessage> _buildChatMessages(
    String prompt,
    List<Map<String, String>>? history,
    String systemPrompt, {
    String? imagePath,
    bool qwen3Model = false,
  }) {
    final window = buildLocalPromptWindow(
      prompt: prompt,
      history: history,
      systemPrompt: systemPrompt,
      contextSize: math.max(64, _contextSize - _outputTokenLimit),
      qwen3Model: qwen3Model,
    );
    final messages = <ChatMessage>[];
    messages.add(ChatMessage(role: 'system', content: window.systemPrompt));
    for (final message in window.history) {
      messages.add(ChatMessage(
        role: message['role'] ?? 'user',
        content: message['content'] ?? '',
      ));
    }

    messages.add(ChatMessage(
      role: 'user',
      content: window.userPrompt,
      imagePath: imagePath,
    ));
    return messages;
  }

  String _buildPrompt(
    String userMessage,
    List<Map<String, String>>? history,
    String systemPrompt,
    String modelName,
  ) {
    final name = modelName.toLowerCase();
    final bounded = _buildChatMessages(
      userMessage,
      history,
      systemPrompt,
      qwen3Model: name.contains('qwen3'),
    );
    final system = bounded.first.content;
    final message = bounded.last.content;
    final boundedHistory = bounded
        .skip(1)
        .take(bounded.length - 2)
        .map((item) => {'role': item.role, 'content': item.content})
        .toList();
    if (name.contains('gemma')) {
      return _buildGemma(message, boundedHistory, system);
    }
    if (name.contains('llama-3') || name.contains('llama3')) {
      return _buildLlama3(message, boundedHistory, system);
    }
    return _buildChatML(message, boundedHistory, system);
  }

  String _buildChatML(
      String msg, List<Map<String, String>>? history, String sys) {
    final buf = StringBuffer();
    buf.write('<|im_start|>system\n$sys<|im_end|>\n');
    if (history != null) {
      for (final message in history) {
        buf.write(
          '<|im_start|>${message['role'] ?? 'user'}\n${message['content'] ?? ''}<|im_end|>\n',
        );
      }
    }
    buf.write('<|im_start|>user\n$msg<|im_end|>\n<|im_start|>assistant\n');
    return buf.toString();
  }

  String _buildGemma(
      String msg, List<Map<String, String>>? history, String sys) {
    final buf = StringBuffer();
    buf.write(
        '<start_of_turn>user\n$sys<end_of_turn>\n<start_of_turn>model\nUnderstood.<end_of_turn>\n');
    if (history != null) {
      final recent =
          history.length > 4 ? history.sublist(history.length - 4) : history;
      for (final m in recent) {
        final role = m['role'] == 'assistant' ? 'model' : 'user';
        final content = m['content'] ?? '';
        final trunc =
            content.length > 300 ? '${content.substring(0, 300)}...' : content;
        buf.write('<start_of_turn>$role\n$trunc<end_of_turn>\n');
      }
    }
    buf.write('<start_of_turn>user\n$msg<end_of_turn>\n<start_of_turn>model\n');
    return buf.toString();
  }

  String _buildLlama3(
      String msg, List<Map<String, String>>? history, String sys) {
    final buf = StringBuffer();
    buf.write(
        '<|begin_of_text|><|start_header_id|>system<|end_header_id|>\n\n$sys<|eot_id|>');
    if (history != null) {
      final recent =
          history.length > 4 ? history.sublist(history.length - 4) : history;
      for (final m in recent) {
        final content = m['content'] ?? '';
        final trunc =
            content.length > 300 ? '${content.substring(0, 300)}...' : content;
        buf.write(
            '<|start_header_id|>${m['role'] ?? 'user'}<|end_header_id|>\n\n$trunc<|eot_id|>');
      }
    }
    buf.write(
        '<|start_header_id|>user<|end_header_id|>\n\n$msg<|eot_id|><|start_header_id|>assistant<|end_header_id|>\n\n');
    return buf.toString();
  }
}
