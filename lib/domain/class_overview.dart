enum AttendanceStatus { present, absent, excused, notYetOpen }

enum AbsenceRiskLevel { none, warning, examRisk }

enum AttendancePolicy { normal, alwaysExcused }

enum CourseSlotState { notOpened, active, completed }

class CourseStudent {
  const CourseStudent({
    required this.id,
    required this.email,
    required this.studentCode,
    required this.fullName,
    required this.active,
    required this.attendancePolicy,
  });

  final String id;
  final String email;
  final String studentCode;
  final String fullName;
  final bool active;
  final AttendancePolicy attendancePolicy;

  String get displayName => fullName.isEmpty ? email : fullName;
  bool get isAlwaysExcused =>
      attendancePolicy == AttendancePolicy.alwaysExcused;
}

class CourseSlotOverview {
  const CourseSlotOverview({
    required this.number,
    required this.date,
    required this.daySlot,
    required this.state,
    required this.sessionIds,
  });

  final int number;
  final String date;
  final int? daySlot;
  final CourseSlotState state;
  final List<String> sessionIds;

  bool get hasOpened => state != CourseSlotState.notOpened;
}

class AttendanceEntry {
  const AttendanceEntry({
    required this.studentId,
    required this.slot,
    required this.status,
    required this.source,
    required this.syncStatus,
    this.checkedInAt,
    this.sessionId,
    this.reason,
    this.updatedAt,
    this.updatedBy,
  });

  final String studentId;
  final int slot;
  final AttendanceStatus status;
  final String source;
  final String syncStatus;
  final DateTime? checkedInAt;
  final String? sessionId;
  final String? reason;
  final DateTime? updatedAt;
  final String? updatedBy;
}

class StudentAttendanceDetail {
  const StudentAttendanceDetail({
    required this.student,
    required this.attendedSlots,
    required this.totalSlots,
    required this.openedSlots,
    required this.excusedSlots,
  });

  final CourseStudent student;
  final int attendedSlots;
  final int totalSlots;
  final int openedSlots;
  final int excusedSlots;
}

class CourseOverview {
  CourseOverview({
    required this.courseClassId,
    required this.subject,
    required this.classCode,
    required this.students,
    required this.slots,
    required this.entries,
  });

  final String courseClassId;
  final String subject;
  final String classCode;
  final List<CourseStudent> students;
  final List<CourseSlotOverview> slots;
  final Map<String, AttendanceEntry> entries;

  String _key(String studentId, int slot) => '$studentId::$slot';

  AttendanceEntry? entryFor(String studentId, int slot) =>
      entries[_key(studentId, slot)];

  AttendanceStatus statusFor(String studentId, CourseSlotOverview slot) {
    final entry = entryFor(studentId, slot.number);
    if (entry != null) return entry.status;
    return slot.hasOpened
        ? AttendanceStatus.absent
        : AttendanceStatus.notYetOpen;
  }

  int get activeStudentCount => students.where((item) => item.active).length;
  int get openedSlotCount => slots.where((item) => item.hasOpened).length;
  int get completedSlotCount =>
      slots.where((item) => item.state == CourseSlotState.completed).length;
  CourseSlotOverview? get activeSlot {
    for (final slot in slots) {
      if (slot.state == CourseSlotState.active) return slot;
    }
    return null;
  }

  int attendedCount(CourseStudent student) => slots.where((slot) {
    final status = statusFor(student.id, slot);
    return status == AttendanceStatus.present;
  }).length;

  int excusedCount(CourseStudent student) => slots
      .where((slot) => statusFor(student.id, slot) == AttendanceStatus.excused)
      .length;

  int absentCount(CourseStudent student) => slots.where((slot) {
    return slot.state == CourseSlotState.completed &&
        statusFor(student.id, slot) == AttendanceStatus.absent;
  }).length;

  double absenceRate(CourseStudent student) => slots.isEmpty
      ? 0
      : absentCount(student) / slots.length;

  AbsenceRiskLevel absenceRiskFor(CourseStudent student) {
    if (!student.active || student.isAlwaysExcused || slots.isEmpty) {
      return AbsenceRiskLevel.none;
    }
    final absences = absentCount(student);
    if (absences * 5 > slots.length) return AbsenceRiskLevel.examRisk;
    if (absences * 10 >= slots.length) return AbsenceRiskLevel.warning;
    return AbsenceRiskLevel.none;
  }

  int get absenceAlertStudentCount => students
      .where((student) => absenceRiskFor(student) != AbsenceRiskLevel.none)
      .length;

  int get examRiskStudentCount => students
      .where((student) => absenceRiskFor(student) == AbsenceRiskLevel.examRisk)
      .length;

  double get attendanceRate {
    final activeStudents = students.where((student) => student.active);
    var attended = 0;
    var eligible = 0;
    for (final student in activeStudents) {
      for (final slot in slots.where((item) => item.hasOpened)) {
        final status = statusFor(student.id, slot);
        if (status == AttendanceStatus.excused) continue;
        eligible++;
        if (status == AttendanceStatus.present) {
          attended++;
        }
      }
    }
    return eligible == 0 ? 0 : attended / eligible;
  }

  int get syncErrorCount =>
      entries.values.where((entry) => entry.syncStatus == 'error').length;

  int get atRiskStudentCount {
    if (openedSlotCount == 0) return 0;
    return students.where((student) {
      if (!student.active) return false;
      final excused = excusedCount(student);
      final denominator = openedSlotCount - excused;
      return denominator > 0 && attendedCount(student) / denominator < .8;
    }).length;
  }
}

String attendanceEntryKey(String studentId, int slot) => '$studentId::$slot';
