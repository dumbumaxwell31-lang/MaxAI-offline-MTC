class LocalPromptWindow {
  const LocalPromptWindow({
    required this.systemPrompt,
    required this.userPrompt,
    required this.history,
  });

  final String systemPrompt;
  final String userPrompt;
  final List<Map<String, String>> history;
}

LocalPromptWindow buildLocalPromptWindow({
  required String prompt,
  required List<Map<String, String>>? history,
  required String systemPrompt,
  required int contextSize,
  required bool qwen3Model,
}) {
  final maxCharacters = contextSize;
  final boundedSystem = _truncate(systemPrompt, maxCharacters ~/ 5);
  const suffix = '\n/no_think';
  final userSuffix = qwen3Model ? suffix : '';
  final promptLimit = maxCharacters - boundedSystem.length - 96;
  final boundedPrompt =
      '${_truncate(prompt, promptLimit - userSuffix.length)}$userSuffix';

  final selectedHistory = <Map<String, String>>[];
  if (history != null && history.isNotEmpty) {
    final candidates =
        history.length > 16 ? history.sublist(history.length - 16) : history;
    var remaining =
        maxCharacters - boundedSystem.length - boundedPrompt.length - 128;
    for (final message in candidates.reversed) {
      if (message['role'] == 'user' && message['content'] == prompt) continue;
      if (remaining <= 32) break;
      final content = message['content'] ?? '';
      final boundedContent =
          _truncate(content, remaining - 32, preserveEdges: true);
      selectedHistory.add({
        'role': message['role'] ?? 'user',
        'content': boundedContent,
      });
      remaining -= boundedContent.length + 32;
      if (boundedContent.length < content.length) break;
    }
  }

  return LocalPromptWindow(
    systemPrompt: boundedSystem,
    userPrompt: boundedPrompt,
    history: selectedHistory.reversed.toList(growable: false),
  );
}

String _truncate(
  String value,
  int maxCharacters, {
  bool preserveEdges = false,
}) {
  if (maxCharacters <= 0) return '';
  if (value.length <= maxCharacters) return value;
  if (maxCharacters <= 3) return '.' * maxCharacters;
  if (!preserveEdges) return '${value.substring(0, maxCharacters - 3)}...';

  final retainedCharacters = maxCharacters - 3;
  final prefixLength = (retainedCharacters + 1) ~/ 2;
  final suffixLength = retainedCharacters - prefixLength;
  final suffixStart = value.length - suffixLength;
  return '${value.substring(0, prefixLength)}...${value.substring(suffixStart)}';
}
