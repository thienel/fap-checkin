import 'package:fap_check_attendance/domain/class_overview.dart';
import 'package:fap_check_attendance/domain/models.dart';
import 'package:fap_check_attendance/screens/class_overview_screen.dart';
import 'package:fap_check_attendance/services/attendance_api.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _BulkApi implements AttendanceApi {
  final calls = <List<String>>[];
  final course = const CourseClassSummary(
    id: 'course-1',
    subject: 'PRM393',
    classCode: 'SE1801',
  );

  @override
  Future<List<CourseClassSummary>> getCourseClasses() async => [course];

  @override
  Future<CourseOverview> getCourseOverview(String courseClassId) async =>
      CourseOverview(
        courseClassId: courseClassId,
        subject: 'PRM393',
        classCode: 'SE1801',
        students: [
          for (var index = 0; index < 10; index++)
            CourseStudent(
              id: 'student-$index',
              email: 'student$index@fpt.edu.vn',
              studentCode: 'SE${index.toString().padLeft(3, '0')}',
              fullName: 'Student $index',
              active: true,
              attendancePolicy: AttendancePolicy.normal,
            ),
        ],
        slots: const [
          CourseSlotOverview(
            number: 1,
            date: '2026-09-26',
            daySlot: 1,
            state: CourseSlotState.completed,
            sessionIds: ['session-1'],
          ),
        ],
        entries: {},
      );

  @override
  Future<BulkAttendanceResult> adjustAttendanceBulk({
    required String courseClassId,
    required int slot,
    required Iterable<String> studentIds,
    required AttendanceStatus status,
    required String reason,
  }) async {
    final ids = studentIds.toList();
    calls.add(ids);
    if (calls.length == 1) {
      return const BulkAttendanceResult(
        syncedCount: 7,
        pendingSync: {},
        failures: {
          'student-7': 'Network error',
          'student-8': 'Network error',
          'student-9': 'Network error',
        },
      );
    }
    return const BulkAttendanceResult(
      syncedCount: 3,
      pendingSync: {},
      failures: {},
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets(
    'bulk edit reports partial failure and retries only failed students',
    (tester) async {
      final api = _BulkApi();
      tester.view.physicalSize = const Size(1500, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(0.8)),
            child: Scaffold(body: ClassOverviewScreen(api: api)),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(
        find.byType(DropdownButtonFormField<CourseClassSummary>),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('PRM393 · SE1801').last);
      await tester.pumpAndSettle();

      final bulkButton = find.byTooltip('Điều chỉnh tất cả sinh viên đang lọc');
      await tester.ensureVisible(bulkButton);
      await tester.tap(bulkButton);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'Giáo viên xác nhận');
      await tester.tap(find.text('Lưu thay đổi'));
      await tester.pumpAndSettle();

      expect(find.text('Đã lưu 7/10 sinh viên'), findsOneWidget);
      expect(find.text('Chưa lưu: 3'), findsOneWidget);
      expect(find.textContaining('Student 7: Network error'), findsOneWidget);
      await tester.tap(find.text('Thử lại 3 trường hợp'));
      await tester.pumpAndSettle();
      expect(api.calls[1], ['student-7', 'student-8', 'student-9']);
      expect(find.text('Đã lưu 3/3 sinh viên'), findsOneWidget);
    },
  );
}
