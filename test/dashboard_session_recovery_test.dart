import 'package:fap_check_attendance/domain/models.dart';
import 'package:fap_check_attendance/screens/dashboard_screen.dart';
import 'package:fap_check_attendance/services/attendance_api.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeUser implements User {
  @override
  String? get email => 'teacher@fpt.edu.vn';

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _StartFailureApi implements AttendanceApi {
  bool started = false;
  int resumeCalls = 0;

  @override
  bool get isSheetSyncConfigured => true;

  @override
  Future<List<TodaySlot>> getTodaySlots(DateTime date) async => [
    TodaySlot(
      courseClassId: 'course-1',
      subject: 'PRM393',
      classCode: 'SE1801',
      slot: 1,
      slotCount: 20,
      daySlot: 1,
      date:
          '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}',
    ),
  ];

  @override
  Future<AttendanceSession?> getActiveAttendance() async => started
      ? AttendanceSession(
          id: 'session-1',
          courseClassId: 'course-1',
          subject: 'PRM393',
          classCode: 'SE1801',
          slot: 1,
          slotCount: 20,
          daySlot: 1,
          date: '2026-09-26',
          rotationSeconds: 15,
          validitySeconds: 20,
        )
      : null;

  @override
  Future<AttendanceSession> startAttendance({
    required TodaySlot slot,
    required int rotationSeconds,
    required int validitySeconds,
    required int checkoutRotationSeconds,
  }) async {
    started = true;
    throw Exception('setup failed after commit');
  }

  @override
  Future<AttendanceSession?> resumeActiveAttendance() async {
    resumeCalls++;
    return null;
  }

  @override
  Future<SheetSyncSummary> syncPendingCheckIns({
    String? sessionId,
    bool force = false,
  }) async => const SheetSyncSummary();

  @override
  Future<void> createTestCourseClassNow() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets('a session committed before setup failure remains resumable', (
    tester,
  ) async {
    final api = _StartFailureApi();
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(0.8)),
          child: DashboardScreen(api: api, user: _FakeUser()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Bắt đầu điểm danh'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Bắt đầu'));
    await tester.pumpAndSettle();

    expect(find.text('Mở lại phiên'), findsOneWidget);
    await tester.tap(find.text('Mở lại phiên'));
    await tester.pumpAndSettle();
    expect(api.resumeCalls, 1);
  });
}
