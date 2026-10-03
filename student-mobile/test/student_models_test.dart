import 'package:flutter_test/flutter_test.dart';
import 'package:fap_student/models/student_models.dart';

StudentCourse course({bool excused = false, int count = 10}) => StudentCourse(
  'course',
  {
    'subject': 'PRM393',
    'classCode': 'SE1910',
    'schedule': List.generate(
      count,
      (i) => {'number': i + 1, 'date': '2026-10-05', 'daySlot': 2},
    ),
  },
  StudentProfile(studentIdFor('student@example.com'), {
    'active': true,
    'attendancePolicy': excused ? 'alwaysExcused' : 'normal',
  }),
);

void main() {
  test('email hash matches SHA-256 hex and preserves email aliases', () {
    expect(
      studentIdFor(' User@Example.COM '),
      studentIdFor('user@example.com'),
    );
    expect(
      studentIdFor('abc'),
      'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
    );
    expect(
      studentIdFor('a+b@example.com'),
      isNot(studentIdFor('a@example.com')),
    );
    expect(
      studentIdFor('a.b@example.com'),
      isNot(studentIdFor('ab@example.com')),
    );
  });
  test(
    'QR parser accepts desktop URL and rejects foreign or ambiguous tokens',
    () {
      const host = 'https://test.web.app';
      expect(parseQr('$host/check-in?t=Abc_-123', host), 'Abc_-123');
      for (final url in [
        'http://test.web.app/check-in?t=a',
        'https://evil.com/check-in?t=a',
        '$host/check-in?t=a&t=b',
        '$host/check-in?t=a%2Fb',
        '$host/check-in?t=',
        '$host/other?t=a',
        'https://evil@test.web.app/check-in?t=a',
        '$host/check-in?t=a#b',
      ]) {
        expect(() => parseQr(url, host), throwsFormatException);
      }
    },
  );
  test('Vietnam date and week are independent of the phone timezone', () {
    final day = vietnamNow(DateTime.parse('2026-10-04T18:30:00Z'));
    expect(dateKey(day), '2026-10-05');
    expect(dateKey(weekStart(day)), '2026-10-05');
    expect(
      dateKey(weekStart(vietnamNow(DateTime.parse('2026-10-03T01:00:00Z')))),
      '2026-09-28',
    );
  });
  test('missing records depend on session state, canonical beats legacy', () {
    expect(
      inferAttendance(SlotState.notOpened, null),
      AttendanceState.notOpened,
    );
    expect(inferAttendance(SlotState.active, null), AttendanceState.pending);
    expect(inferAttendance(SlotState.completed, null), AttendanceState.absent);
    expect(inferAttendance(SlotState.unknown, null), AttendanceState.unknown);
    expect(
      inferAttendance(SlotState.completed, 'excused', legacy: true),
      AttendanceState.excused,
    );
    expect(
      inferAttendance(SlotState.completed, 'unexpected'),
      AttendanceState.unknown,
    );
  });
  test('statistics exclude active and excused sessions and use desktop warning thresholds', () {
    final c = course();
    final rows = [
      SlotAttendance(c.slots[0], SlotState.completed, AttendanceState.present),
      SlotAttendance(c.slots[1], SlotState.completed, AttendanceState.absent),
      SlotAttendance(c.slots[2], SlotState.completed, AttendanceState.excused),
      SlotAttendance(c.slots[3], SlotState.active, AttendanceState.present),
    ];
    final summary = AttendanceSummary(c, rows);
    expect(summary.present, 1);
    expect(summary.absent, 1);
    expect(summary.excused, 1);
    expect(summary.attendanceRate, .5);
    expect(summary.warning, contains('10%'));
    final exact20 = AttendanceSummary(c, [
      ...rows,
      SlotAttendance(c.slots[4], SlotState.completed, AttendanceState.absent),
    ]);
    expect(exact20.warning, contains('10%'));
    final over20 = AttendanceSummary(c, [
      ...exact20.rows,
      SlotAttendance(c.slots[5], SlotState.completed, AttendanceState.absent),
    ]);
    expect(over20.warning, contains('20%'));
    expect(
      AttendanceSummary(course(excused: true), over20.rows).warning,
      isNull,
    );
  });
  test('unknown or unopened attendance does not produce a misleading rate', () {
    final c = course();
    expect(
      AttendanceSummary(c, [
        SlotAttendance(
          c.slots[0],
          SlotState.notOpened,
          AttendanceState.notOpened,
        ),
      ]).attendanceRate,
      isNull,
    );
    final unknown = AttendanceSummary(c, [
      SlotAttendance(c.slots[0], SlotState.completed, AttendanceState.unknown),
    ]);
    expect(unknown.attendanceRate, isNull);
    expect(unknown.warning, isNull);
    expect(c.slots[0].timeLabel(90), contains('Chưa có giờ cụ thể'));
  });
}
