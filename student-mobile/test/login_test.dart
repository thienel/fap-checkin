import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fap_student/app.dart';

void main() {
  testWidgets('login prevents duplicate taps while authentication is pending', (
    tester,
  ) async {
    final completer = Completer<void>();
    var calls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: StudentLogin(
          onSignIn: () {
            calls++;
            return completer.future;
          },
        ),
      ),
    );
    await tester.tap(find.text('Đăng nhập với Google'));
    await tester.pump();
    await tester.tap(find.text('Đăng nhập với Google'));
    await tester.pump();
    expect(calls, 1);
    completer.complete();
    await tester.pumpAndSettle();
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });
  testWidgets('configuration errors are shown and sign-in can be retried', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: StudentLogin(
          onSignIn: () async {
            throw StateError('Thiếu cấu hình Google');
          },
        ),
      ),
    );
    await tester.tap(find.text('Đăng nhập với Google'));
    await tester.pumpAndSettle();
    expect(find.text('Thiếu cấu hình Google'), findsOneWidget);
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNotNull,
    );
  });
}
