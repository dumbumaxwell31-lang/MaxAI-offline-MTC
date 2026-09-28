import 'package:flutter_test/flutter_test.dart';
import 'package:maxai/utils/thought_parser.dart';

void main() {
  test('stored and displayed answer text excludes reasoning blocks', () {
    expect(
      visibleAnswerText('<think>private reasoning</think>Public answer.'),
      'Public answer.',
    );
    expect(visibleAnswerText('<think>private reasoning'), isEmpty);
  });

  test('filters thought blocks when tags are split across stream chunks', () {
    final filter = ThoughtOutputFilter();
    final visible = StringBuffer();

    for (final chunk in [
      '<thi',
      'nk>private reasoning</thi',
      'nk>Final ',
      'answer.',
    ]) {
      visible.write(filter.add(chunk));
    }
    visible.write(filter.finish());

    expect(visible.toString(), 'Final answer.');
    expect(visible.toString(), isNot(contains('private reasoning')));
  });

  test('discards unterminated reasoning instead of exposing it', () {
    final filter = ThoughtOutputFilter();

    expect(filter.add('<think>private'), '');
    expect(filter.finish(), '');
    expect(filter.visibleText, '');
  });

  test('passes ordinary output through at completion', () {
    final filter = ThoughtOutputFilter();

    expect(filter.add('Hello'), 'Hello');
    expect(filter.finish(), '');
    expect(filter.visibleText, 'Hello');
  });
}
