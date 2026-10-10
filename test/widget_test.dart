import 'package:flutter_test/flutter_test.dart';
import 'package:ielts_accent_coach/main.dart';

void main() {
  testWidgets('shows practice workspace', (tester) async {
    await tester.pumpWidget(const IeltsAccentApp());

    expect(find.text('IELTS Accent Lab'), findsOneWidget);
    expect(find.text('选择目标口音'), findsOneWidget);
    expect(find.text('开始跟读'), findsOneWidget);
    expect(find.text('AI 教练'), findsOneWidget);
  });
}
