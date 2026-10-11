import 'package:flutter_test/flutter_test.dart';
import 'package:ielts_accent_coach/main.dart';

void main() {
  testWidgets(
    'requires unified sign-in before opening the practice workspace',
    (tester) async {
      await tester.pumpWidget(const IeltsAccentApp());

      expect(find.text('IELTS Accent Lab'), findsOneWidget);
      expect(find.text('使用统一账号登录'), findsOneWidget);
      expect(find.text('选择目标口音'), findsNothing);
      expect(find.text('开始跟读'), findsNothing);
    },
  );
}
