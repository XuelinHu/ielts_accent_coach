import 'package:flutter_test/flutter_test.dart';
import 'package:ielts_accent_coach/pronunciation_score.dart';

void main() {
  test('scores an exact transcript at 100', () {
    final result = scorePronunciation(
      'Public transport needs to be reliable.',
      'Public transport needs to be reliable',
      1,
    );

    expect(result.overall, 100);
    expect(result.accuracy, 100);
    expect(result.completeness, 100);
    expect(result.referenceMarks.every((mark) => mark.isMatch), isTrue);
  });

  test('marks omitted words and lowers completeness', () {
    final result = scorePronunciation(
      'I grew up in a quiet coastal town.',
      'I grew up quiet town',
      0.8,
    );

    expect(result.completeness, lessThan(100));
    expect(result.referenceMarks.where((mark) => !mark.isMatch), isNotEmpty);
  });
}
