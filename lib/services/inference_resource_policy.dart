/// Chooses conservative llama.cpp limits from the currently available RAM.
/// These are estimates; a successful native model load is the final check.
class InferenceResourceLimits {
  const InferenceResourceLimits({
    required this.contextSize,
    required this.maxOutputTokens,
    required this.explanation,
  });

  final int contextSize;
  final int maxOutputTokens;
  final String? explanation;
}

class InferenceResourcePolicy {
  InferenceResourcePolicy._();

  static const fullProfileMinAvailableRamGb = 2.5;
  static const mediumProfileMinAvailableRamGb = 1.0;
  static const lowProfileMinAvailableRamGb = 0.5;

  static InferenceResourceLimits forAvailableRam({
    required double? availableRamGb,
    required int modelContextLimit,
    required int modelOutputLimit,
  }) {
    final ram = availableRamGb != null &&
            availableRamGb.isFinite &&
            availableRamGb >= 0
        ? availableRamGb
        : null;

    final int suggestedContext;
    final int suggestedOutput;
    if (ram == null) {
      suggestedContext = 512;
      suggestedOutput = 128;
    } else if (ram >= fullProfileMinAvailableRamGb) {
      suggestedContext = 8192;
      suggestedOutput = 4096;
    } else if (ram >= mediumProfileMinAvailableRamGb) {
      suggestedContext = 4096;
      suggestedOutput = 3072;
    } else if (ram >= lowProfileMinAvailableRamGb) {
      suggestedContext = 2048;
      suggestedOutput = 1024;
    } else {
      suggestedContext = 512;
      suggestedOutput = 128;
    }

    final contextSize = suggestedContext.clamp(512, modelContextLimit).toInt();
    final outputTokens = suggestedOutput.clamp(1, modelOutputLimit).toInt();
    final isReduced = contextSize < modelContextLimit ||
        outputTokens < modelOutputLimit;
    final explanation = ram == null
        ? 'Available RAM could not be measured. MaxAI will try a conservative '
            '$contextSize-token context and $outputTokens-token output; the '
            'native model load will determine whether it can run.'
        : isReduced
            ? 'Available RAM is ${ram.toStringAsFixed(1)} GB. '
                'Using a conservative $contextSize-token context and '
                '$outputTokens-token output instead of the model maximum '
                '($modelContextLimit/$modelOutputLimit) to reduce memory pressure.'
            : null;

    return InferenceResourceLimits(
      contextSize: contextSize,
      maxOutputTokens: outputTokens,
      explanation: explanation,
    );
  }

  static List<int> contextRetrySequence(
    int requestedContextSize, {
    int minimumContextSize = 512,
  }) {
    final contexts = <int>[];
    if (requestedContextSize < minimumContextSize) {
      return [requestedContextSize];
    }
    var contextSize = requestedContextSize;
    while (contextSize >= minimumContextSize) {
      if (!contexts.contains(contextSize)) contexts.add(contextSize);
      if (contextSize == minimumContextSize) break;
      contextSize =
          (contextSize ~/ 2).clamp(minimumContextSize, contextSize).toInt();
    }
    return contexts;
  }

  static int outputLimitForContext({
    required int contextSize,
    required int configuredOutputLimit,
    required int modelOutputLimit,
  }) {
    final promptReserve = (contextSize ~/ 4).clamp(128, 1024).toInt();
    final contextOutputLimit =
        (contextSize - promptReserve).clamp(1, contextSize).toInt();
    return configuredOutputLimit
        .clamp(1, modelOutputLimit)
        .clamp(1, contextOutputLimit)
        .toInt();
  }

  static bool isAllocationFailure(Object error) {
    final message = error.toString().toLowerCase();
    return message.contains('out of memory') ||
        message.contains('outofmemory') ||
        message.contains('failed to allocate') ||
        message.contains('allocation failed') ||
        message.contains('cannot allocate') ||
        message.contains('could not allocate') ||
        message.contains('failed to create context') ||
        message.contains('memory allocation') ||
        message.contains('bad_alloc');
  }

  static String allocationFailureMessage(Object error) =>
      'The device could not allocate enough memory for this inference '
      'configuration. MaxAI has not changed your saved settings. Try closing '
      'other apps or reducing the context/output limits. Details: $error';
}
