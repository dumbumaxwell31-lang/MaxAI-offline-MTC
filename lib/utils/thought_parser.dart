class ThoughtParts {
  final String thought;
  final String answer;
  final bool isThinking;

  const ThoughtParts({
    required this.thought,
    required this.answer,
    required this.isThinking,
  });

  bool get hasThought => thought.trim().isNotEmpty;
  bool get hasAnswer => answer.trim().isNotEmpty;
}

ThoughtParts splitThoughtTags(String text) {
  final startExp = RegExp(r'<think>', caseSensitive: false);
  final endExp = RegExp(r'</think>', caseSensitive: false);
  final start = startExp.firstMatch(text);

  if (start == null) {
    return ThoughtParts(thought: '', answer: text, isThinking: false);
  }

  final before = text.substring(0, start.start);
  final afterStart = text.substring(start.end);
  final end = endExp.firstMatch(afterStart);

  if (end == null) {
    return ThoughtParts(
      thought: afterStart,
      answer: before,
      isThinking: true,
    );
  }

  final thought = afterStart.substring(0, end.start);
  final after = afterStart.substring(end.end);
  final answer = '$before$after'.trimLeft();

  return ThoughtParts(
    thought: thought,
    answer: answer,
    isThinking: false,
  );
}

String visibleAnswerText(String text) => splitThoughtTags(text).answer.trim();

/// Streams only visible answer text when a model emits `<think>` blocks.
class ThoughtOutputFilter {
  static const _openTag = '<think>';
  static const _closeTag = '</think>';

  final StringBuffer _output = StringBuffer();
  String _pending = '';
  bool _insideThought = false;

  String add(String chunk) {
    _pending += chunk;
    final visible = StringBuffer();

    while (_pending.isNotEmpty) {
      if (_insideThought) {
        final end = _indexOf(_pending, _closeTag);
        if (end < 0) {
          _pending = _retainPossibleTagSuffix(_pending, _closeTag);
          break;
        }
        _pending = _pending.substring(end + _closeTag.length);
        _insideThought = false;
        continue;
      }

      final start = _indexOf(_pending, _openTag);
      final strayEnd = _indexOf(_pending, _closeTag);
      if (start >= 0 && (strayEnd < 0 || start < strayEnd)) {
        visible.write(_pending.substring(0, start));
        _pending = _pending.substring(start + _openTag.length);
        _insideThought = true;
        continue;
      }
      if (strayEnd >= 0) {
        visible.write(_pending.substring(0, strayEnd));
        _pending = _pending.substring(strayEnd + _closeTag.length);
        continue;
      }

      final safeLength = _pending.length - _longestPossibleTagSuffix(_pending);
      if (safeLength > 0) {
        visible.write(_pending.substring(0, safeLength));
        _pending = _pending.substring(safeLength);
      }
      break;
    }

    final result = visible.toString();
    _output.write(result);
    return result;
  }

  String finish() {
    if (_insideThought) {
      _pending = '';
      return '';
    }
    final lower = _pending.toLowerCase();
    final tail = _openTag.startsWith(lower) || _closeTag.startsWith(lower)
        ? ''
        : _pending;
    _pending = '';
    _output.write(tail);
    return tail;
  }

  String get visibleText => _output.toString();

  int _indexOf(String text, String tag) => text.toLowerCase().indexOf(tag);

  int _longestPossibleTagSuffix(String text) {
    final lower = text.toLowerCase();
    var longest = 0;
    for (final tag in [_openTag, _closeTag]) {
      final maximum =
          tag.length - 1 < lower.length ? tag.length - 1 : lower.length;
      for (var length = 1; length <= maximum; length++) {
        if (tag.startsWith(lower.substring(lower.length - length))) {
          if (length > longest) longest = length;
        }
      }
    }
    return longest;
  }

  String _retainPossibleTagSuffix(String text, String tag) {
    final lower = text.toLowerCase();
    final maximum =
        tag.length - 1 < lower.length ? tag.length - 1 : lower.length;
    for (var length = maximum; length > 0; length--) {
      if (tag.startsWith(lower.substring(lower.length - length))) {
        return text.substring(text.length - length);
      }
    }
    return '';
  }
}
