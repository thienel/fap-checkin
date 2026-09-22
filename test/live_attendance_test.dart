import 'package:fap_check_attendance/domain/class_overview.dart';
import 'package:fap_check_attendance/domain/live_attendance.dart';
import 'package:fap_check_attendance/domain/models.dart';
import 'package:fap_check_attendance/services/live_session_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('LiveSessionService.combineRosterAndRecords', () {
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

    const student3 = CourseStudent(
      id: 's3',
      email: 'thien@fpt.edu.vn',
      studentCode: 'SE172145',
      fullName: 'Nguyễn Mai Hào Thiên',
      active: true,
      attendancePolicy: AttendancePolicy.normal,
    );

    const inactiveStudent = CourseStudent(
      id: 's4',
      email: 'inactive@fpt.edu.vn',
      studentCode: 'SE000000',
      fullName: 'Đã Thôi Học',
      active: false,
      attendancePolicy: AttendancePolicy.normal,
    );

    test('Lớp 3 sinh viên, chưa ai quét mã: hiển thị 3 sinh viên Chưa điểm danh', () {
      final state = LiveSessionService.combineRosterAndRecords(
        roster: [student1, student2, student3],
        records: [],
      );

      expect(state, isA<LiveAttendanceLoaded>());
      final loaded = state as LiveAttendanceLoaded;

      expect(loaded.students.length, 3);
      expect(loaded.stats.totalActive, 3);
      expect(loaded.stats.presentCount, 0);
      expect(loaded.stats.notYetOpenCount, 3);
      expect(loaded.stats.rate, 0.0);

      // Tất cả đều có status notYetOpen
      for (final s in loaded.students) {
        expect(s.status, AttendanceStatus.notYetOpen);
        expect(s.isNotYetOpen, isTrue);
        expect(s.checkedInAt, isNull);
      }
    });

    test('1 sinh viên quét mã thành công: chỉ sinh viên đó đổi sang Đã điểm danh, count = 1/3, không sinh thêm dòng', () {
      final checkInTime = DateTime(2026, 9, 22, 18, 30, 0);
      final record = CheckInRecord(
        id: 'rec-1',
        studentId: 's1',
        email: 'vy@fpt.edu.vn',
        studentCode: 'SE183571',
        fullName: 'Nguyễn Ngọc Tường Vy',
        syncStatus: 'synced',
        syncError: null,
        source: 'qr',
        attendanceStatus: 'present',
        checkedInAt: checkInTime,
      );

      final state = LiveSessionService.combineRosterAndRecords(
        roster: [student1, student2, student3],
        records: [record],
      );

      final loaded = state as LiveAttendanceLoaded;
      expect(loaded.students.length, 3); // Vẫn chính xác 3 dòng
      expect(loaded.stats.presentCount, 1);
      expect(loaded.stats.notYetOpenCount, 2);
      expect(loaded.stats.percentageFormatted, '33.3%');

      final vy = loaded.students.firstWhere((s) => s.id == 's1');
      expect(vy.status, AttendanceStatus.present);
      expect(vy.isPresent, isTrue);
      expect(vy.checkedInAt, checkInTime);

      final khoi = loaded.students.firstWhere((s) => s.id == 's2');
      expect(khoi.status, AttendanceStatus.notYetOpen);

      final thien = loaded.students.firstWhere((s) => s.id == 's3');
      expect(thien.status, AttendanceStatus.notYetOpen);
    });

    test('Quét lặp (duplicate) không làm tăng count hoặc thay đổi thời gian điểm danh', () {
      final checkInTime = DateTime(2026, 9, 22, 18, 30, 0);
      final record = CheckInRecord(
        id: 'rec-1',
        studentId: 's1',
        email: 'vy@fpt.edu.vn',
        studentCode: 'SE183571',
        fullName: 'Nguyễn Ngọc Tường Vy',
        syncStatus: 'synced',
        syncError: null,
        source: 'qr',
        attendanceStatus: 'present',
        checkedInAt: checkInTime,
      );

      // Cùng 1 record lặp lại trong danh sách
      final state = LiveSessionService.combineRosterAndRecords(
        roster: [student1, student2, student3],
        records: [record, record],
      );

      final loaded = state as LiveAttendanceLoaded;
      expect(loaded.students.length, 3);
      expect(loaded.stats.presentCount, 1);
      expect(loaded.stats.notYetOpenCount, 2);
    });

    test('Record absent và excused được hiển thị đúng trạng thái độc lập với syncStatus', () {
      final absentRec = CheckInRecord(
        id: 'rec-absent',
        studentId: 's2',
        email: 'khoi@fpt.edu.vn',
        studentCode: 'SE182046',
        fullName: 'Dương Đình Khôi',
        syncStatus: 'error',
        syncError: 'Google Sheets sync failed',
        source: 'manual',
        attendanceStatus: 'absent',
        checkedInAt: DateTime.now(),
      );

      final state = LiveSessionService.combineRosterAndRecords(
        roster: [student1, student2, student3],
        records: [absentRec],
      );

      final loaded = state as LiveAttendanceLoaded;
      expect(loaded.stats.absentCount, 1);
      expect(loaded.stats.presentCount, 0);

      final khoi = loaded.students.firstWhere((s) => s.id == 's2');
      expect(khoi.status, AttendanceStatus.absent);
      expect(khoi.syncStatus, 'error');
      expect(khoi.syncError, 'Google Sheets sync failed');
    });

    test('Bỏ qua sinh viên đã bị deactive khỏi danh sách lớp', () {
      final state = LiveSessionService.combineRosterAndRecords(
        roster: [student1, inactiveStudent],
        records: [],
      );

      final loaded = state as LiveAttendanceLoaded;
      expect(loaded.students.length, 1);
      expect(loaded.students.first.id, 's1');
      expect(loaded.stats.totalActive, 1);
    });

    test('Roster không có sinh viên active: trả về LiveAttendanceEmpty', () {
      final state = LiveSessionService.combineRosterAndRecords(
        roster: [inactiveStudent],
        records: [],
      );

      expect(state, isA<LiveAttendanceEmpty>());
      expect((state as LiveAttendanceEmpty).message, contains('chưa có sinh viên'));
    });

    test('Sinh viên vừa check-in được đưa lên đầu danh sách (isRecent), các bạn khác sắp xếp theo MSSV', () {
      final state = LiveSessionService.combineRosterAndRecords(
        roster: [student1, student2, student3],
        records: [
          CheckInRecord(
            id: 'r2',
            studentId: 's2',
            email: 'khoi@fpt.edu.vn',
            studentCode: 'SE182046',
            fullName: 'Dương Đình Khôi',
            syncStatus: 'synced',
            syncError: null,
            source: 'qr',
            attendanceStatus: 'present',
            checkedInAt: DateTime.now(),
          ),
        ],
        recentStudentIds: {'s2'}, // Dương Đình Khôi vừa quét
      );

      final loaded = state as LiveAttendanceLoaded;
      // student2 (SE182046) có isRecent nên phải đứng đầu
      expect(loaded.students[0].id, 's2');
      expect(loaded.students[0].isRecent, isTrue);

      // 2 sinh viên còn lại xếp theo MSSV: SE172145 (thien) trước SE183571 (vy)
      expect(loaded.students[1].id, 's3');
      expect(loaded.students[2].id, 's1');
    });
  });
}
