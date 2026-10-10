class WordMark {
  const WordMark(this.word, this.isMatch);

  final String word;
  final bool isMatch;
}

class PronunciationResult {
  const PronunciationResult({
    required this.overall,
    required this.accuracy,
    required this.completeness,
    required this.fluency,
    required this.referenceMarks,
  });

  final int overall;
  final int accuracy;
  final int completeness;
  final int fluency;
  final List<WordMark> referenceMarks;
}

List<String> _tokens(String text) {
  return RegExp(
    r"[a-z]+(?:'[a-z]+)?",
    caseSensitive: false,
  ).allMatches(text.toLowerCase()).map((match) => match.group(0)!).toList();
}

PronunciationResult scorePronunciation(
  String reference,
  String transcript,
  double confidence,
) {
  final expected = _tokens(reference);
  final spoken = _tokens(transcript);
  final rows = expected.length + 1;
  final columns = spoken.length + 1;
  final distance = List.generate(rows, (_) => List<int>.filled(columns, 0));

  for (var i = 0; i < rows; i++) {
    distance[i][0] = i;
  }
  for (var j = 0; j < columns; j++) {
    distance[0][j] = j;
  }

  for (var i = 1; i < rows; i++) {
    for (var j = 1; j < columns; j++) {
      final substitution = expected[i - 1] == spoken[j - 1] ? 0 : 1;
      distance[i][j] = _minimum(
        distance[i - 1][j] + 1,
        distance[i][j - 1] + 1,
        distance[i - 1][j - 1] + substitution,
      );
    }
  }

  final matchedIndices = <int>{};
  var i = expected.length;
  var j = spoken.length;
  while (i > 0 || j > 0) {
    if (i > 0 &&
        j > 0 &&
        expected[i - 1] == spoken[j - 1] &&
        distance[i][j] == distance[i - 1][j - 1]) {
      matchedIndices.add(i - 1);
      i--;
      j--;
    } else if (i > 0 && j > 0 && distance[i][j] == distance[i - 1][j - 1] + 1) {
      i--;
      j--;
    } else if (j > 0 && distance[i][j] == distance[i][j - 1] + 1) {
      j--;
    } else {
      i--;
    }
  }

  final referenceCount = expected.isEmpty ? 1 : expected.length;
  final accuracy = ((1 - distance.last.last / referenceCount) * 100)
      .clamp(0, 100)
      .round();
  final completeness = (spoken.length / referenceCount * 100)
      .clamp(0, 100)
      .round();
  final confidenceScore = confidence <= 0
      ? accuracy
      : (confidence * 100).round();
  final fluency = ((confidenceScore * 0.65) + (completeness * 0.35)).round();
  final overall = (accuracy * 0.55 + completeness * 0.25 + fluency * 0.20)
      .round();

  return PronunciationResult(
    overall: overall,
    accuracy: accuracy,
    completeness: completeness,
    fluency: fluency,
    referenceMarks: [
      for (var index = 0; index < expected.length; index++)
        WordMark(expected[index], matchedIndices.contains(index)),
    ],
  );
}

int _minimum(int a, int b, int c) {
  var value = a < b ? a : b;
  return value < c ? value : c;
}
