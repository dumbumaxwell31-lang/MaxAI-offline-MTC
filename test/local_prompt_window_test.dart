import 'package:flutter_test/flutter_test.dart';
import 'package:maxai/utils/local_prompt_window.dart';

void main() {
  test('Qwen3 prompts request non-thinking mode and avoid duplicate turns', () {
    const prompt = 'What is RAM?';
    final window = buildLocalPromptWindow(
      prompt: prompt,
      history: const [
        {'role': 'user', 'content': 'Earlier question'},
        {'role': 'assistant', 'content': 'Earlier answer'},
        {'role': 'user', 'content': prompt},
      ],
      systemPrompt: 'Be concise.',
      contextSize: 1024,
      qwen3Model: true,
    );

    expect(window.userPrompt, '$prompt\n/no_think');
    expect(window.history, hasLength(2));
    expect(window.history.last['content'], 'Earlier answer');
  });

  test('prompt, system message, and recent history stay within context budget',
      () {
    final history = List.generate(
      16,
      (index) => {
        'role': index.isEven ? 'user' : 'assistant',
        'content': 'turn $index ${'x' * 500}',
      },
    );
    final window = buildLocalPromptWindow(
      prompt: 'Question ${'q' * 200}',
      history: history,
      systemPrompt: 'System ${'s' * 5000}',
      contextSize: 1024,
      qwen3Model: true,
    );

    final promptCharacters = window.systemPrompt.length +
        window.userPrompt.length +
        window.history.fold<int>(
          0,
          (total, message) => total + (message['content']?.length ?? 0) + 32,
        );
    expect(promptCharacters, lessThanOrEqualTo(1024));
    expect(window.userPrompt, contains('/no_think'));
    expect(window.history.last['content'], contains('turn 15'));
    expect(window.history.last['content'], endsWith('x' * 32));
  });

  test('truncates an oversized current message within the prompt budget', () {
    final window = buildLocalPromptWindow(
      prompt: 'Question ${'q' * 10000}',
      history: const [],
      systemPrompt: 'Be concise.',
      contextSize: 1024,
      qwen3Model: true,
    );

    expect(window.userPrompt.length, lessThanOrEqualTo(926));
    expect(window.userPrompt, endsWith('/no_think'));
  });

  test('non-Qwen models do not receive Qwen mode markers', () {
    final window = buildLocalPromptWindow(
      prompt: 'Hello',
      history: const [],
      systemPrompt: 'Be concise.',
      contextSize: 1024,
      qwen3Model: false,
    );

    expect(window.userPrompt, 'Hello');
  });
}
