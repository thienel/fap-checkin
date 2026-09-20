import 'package:fap_check_attendance/domain/class_overview.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const student = CourseStudent(
    id: 'student-1',
    email: 'student@fpt.edu.vn',
    studentCode: 'SE0001',
    fullName: 'Nguyễn Văn A',
    active: true,
  );

  const slots = [
    CourseSlotOverview(
      number: 1,
      date: '2026-09-01',
      daySlot: 1,
      state: CourseSlotState.completed,
      sessionIds: ['session-1'],
    ),
    CourseSlotOverview(
      number: 2,
      date: '2026-09-08',
      daySlot: 1,
      state: CourseSlotState.completed,
      sessionIds: ['session-2'],
    ),
    CourseSlotOverview(
      number: 3,
      date: '2026-09-15',
      daySlot: 1,
      state: CourseSlotState.notOpened,
      sessionIds: [],
    ),
  ];

  test('slot chưa mở không bị tính là vắng hoặc đưa vào mẫu số', () {
    final overview = CourseOverview(
      courseClassId: 'PRM_SE01',
      subject: 'PRM',
      classCode: 'SE01',
      students: const [student],
      slots: slots,
      entries: {
        attendanceEntryKey('student-1', 1): const AttendanceEntry(
          studentId: 'student-1',
          slot: 1,
          status: AttendanceStatus.present,
          source: 'qr',
          syncStatus: 'synced',
        ),
      },
    );

    expect(overview.openedSlotCount, 2);
    expect(overview.statusFor('student-1', slots[1]), AttendanceStatus.absent);
    expect(
      overview.statusFor('student-1', slots[2]),
      AttendanceStatus.notYetOpen,
    );
    expect(overview.attendanceRate, .5);
    expect(overview.atRiskStudentCount, 1);
  });

  test('buổi có phép bị loại khỏi mẫu số tỷ lệ tham dự', () {
    final overview = CourseOverview(
      courseClassId: 'PRM_SE01',
      subject: 'PRM',
      classCode: 'SE01',
      students: const [student],
      slots: slots,
      entries: {
        attendanceEntryKey('student-1', 1): const AttendanceEntry(
          studentId: 'student-1',
          slot: 1,
          status: AttendanceStatus.present,
          source: 'qr',
          syncStatus: 'synced',
        ),
        attendanceEntryKey('student-1', 2): const AttendanceEntry(
          studentId: 'student-1',
          slot: 2,
          status: AttendanceStatus.excused,
          source: 'policy',
          syncStatus: 'synced',
        ),
      },
    );

    expect(overview.excusedCount(student), 1);
    expect(overview.attendanceRate, 1);
    expect(overview.atRiskStudentCount, 0);
  });

  test('trạng thái nhập tay được tính là đã tham dự', () {
    final overview = CourseOverview(
      courseClassId: 'PRM_SE01',
      subject: 'PRM',
      classCode: 'SE01',
      students: const [student],
      slots: slots,
      entries: {
        attendanceEntryKey('student-1', 1): const AttendanceEntry(
          studentId: 'student-1',
          slot: 1,
          status: AttendanceStatus.manual,
          source: 'teacher',
          syncStatus: 'error',
        ),
      },
    );

    expect(overview.attendedCount(student), 1);
    expect(overview.syncErrorCount, 1);
  });
}
