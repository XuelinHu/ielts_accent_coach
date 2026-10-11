import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ielts_accent_coach/main.dart';

void main() {
  testWidgets('history pagination emits the requested page', (tester) async {
    int? requestedPage;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ProgressPage(
            attempts: const [],
            databaseOnline: true,
            syncing: false,
            page: 2,
            total: 41,
            totalPages: 3,
            loading: false,
            onPageChanged: (value) => requestedPage = value,
          ),
        ),
      ),
    );

    expect(find.text('2 / 3 页'), findsOneWidget);
    await tester.tap(find.text('下一页'));
    expect(requestedPage, 3);
    await tester.tap(find.text('上一页'));
    expect(requestedPage, 1);
  });
}
