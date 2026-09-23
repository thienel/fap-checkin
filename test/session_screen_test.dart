import 'dart:async';

import 'package:fap_check_attendance/domain/class_overview.dart';
import 'package:fap_check_attendance/domain/live_attendance.dart';
import 'package:fap_check_attendance/domain/models.dart';
import 'package:fap_check_attendance/screens/session_screen.dart';
import 'package:fap_check_attendance/services/attendance_api.dart';
import 'package:fap_check_attendance/services/live_session_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeAttendanceApi implements AttendanceApi {
  @override
  Future<IssuedQr> issueQr(String sessionId) async {
    return IssuedQr(
      url: 'https://test-qr.web.app?token=test-token',
      expiresAt: DateTime.now().add(const Duration(seconds: 15)),
    );
  }

  @override
  Future<String> rotateCheckoutKey(String sessionId, String previousKey) async {
    return 'KEY123';
  }

  @override
  Future<void> stopAttendance(String sessionId) async {}

  @override
  Future<void> syncPendingCheckIns({String? sessionId}) async {}

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeLiveSessionService implements LiveSessionService {
  FakeLiveSessionService(this.stream);

  final Stream<LiveAttendanceState> stream;

  @override
  Stream<LiveAttendanceState> watchLiveAttendance({
    required AttendanceSession session,
  }) {
    return stream;
  }

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  const session = AttendanceSession(
    id: 'session-123',
    courseClassId: 'PRM393_SE1801',
    subject: 'PRM393',
    classCode: 'SE1801',
    slot: 1,
    daySlot: 2,
    slotCount: 30,
    date: '2026-09-22',
    rotationSeconds: 15,
    validitySeconds: 20,
  );

  const student1 = CourseStudent(
    id: 's1',
    email: 'vy@fpt.edu.vn',
    studentCode: 'SE183571',
    fullName: 'Nguyễn Ngọc Tường Vy',
    active: true,
    attendancePolicy: AttendancePolicy.normal,
  );

  const student2 = CourseStudent(
    id: 's2',
    email: 'khoi@fpt.edu.vn',
    studentCode: 'SE182046',
    fullName: 'Dương Đình Khôi',
    active: true,
    attendancePolicy: AttendancePolicy.normal,
  );

  testWidgets('SessionScreen hiển thị đầy đủ danh sách, thống kê và bộ lọc trạng thái',
      (tester) async {
    // Giả lập stream dữ liệu
    final controller = StreamController<LiveAttendanceState>.broadcast();

    final liveStudents = [
      const LiveStudentAttendance(
        student: student1,
        status: AttendanceStatus.present,
        checkedInAt: null,
      ),
      const LiveStudentAttendance(
        student: student2,
        status: AttendanceStatus.notYetOpen,
        checkedInAt: null,
      ),
    ];

    final fakeService = FakeLiveSessionService(controller.stream);
    final fakeApi = FakeAttendanceApi();

    // Set kích thước màn hình desktop
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(
      MaterialApp(
        home: SessionScreen(
          api: fakeApi,
          session: session,
          liveSessionService: fakeService,
        ),
      ),
    );

    // Ban đầu hiển thị loading
    controller.add(const LiveAttendanceLoading());
    await tester.pump();
    expect(find.text('Đang tải danh sách lớp học…'), findsOneWidget);

    // Khi dữ liệu loaded tới
    controller.add(
      LiveAttendanceLoaded(
        students: liveStudents,
        stats: LiveSessionStats.fromList(liveStudents),
      ),
    );
    await tester.pumpAndSettle();

    // Kiểm tra thông tin header & thống kê
    expect(find.text('PRM393 · SE1801'), findsOneWidget);
    expect(find.text('Đã điểm danh'), findsAtLeastNWidgets(1));
    expect(find.text('Chưa điểm danh'), findsAtLeastNWidgets(1));

    // Tìm thấy 2 sinh viên trong bảng
    expect(find.text('Nguyễn Ngọc Tường Vy'), findsOneWidget);
    expect(find.text('SE183571'), findsOneWidget);
    expect(find.text('Dương Đình Khôi'), findsOneWidget);
    expect(find.text('SE182046'), findsOneWidget);

    // Nút Phóng to QR có xuất hiện
    expect(find.text('Phóng to QR'), findsOneWidget);

    // Bấm nút Phóng to QR
    await tester.tap(find.text('Phóng to QR'));
    await tester.pumpAndSettle();

    // Dialog fullscreen QR hiển thị
    expect(find.text('ESC để thoát'), findsOneWidget);

    // Đóng dialog
    await tester.tap(find.byIcon(Icons.close_rounded));
    await tester.pumpAndSettle();
    expect(find.text('ESC để thoát'), findsNothing);

    await controller.close();
  });
}
