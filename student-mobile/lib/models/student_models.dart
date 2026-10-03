import 'dart:convert';

import 'package:crypto/crypto.dart';

String normalizeEmail(String email) => email.trim().toLowerCase();
String studentIdFor(String email) =>
    sha256.convert(utf8.encode(normalizeEmail(email))).toString();
DateTime vietnamNow([DateTime? instant]) =>
    (instant ?? DateTime.now()).toUtc().add(const Duration(hours: 7));
String dateKey(DateTime day) =>
    '${day.year.toString().padLeft(4, '0')}-${day.month.toString().padLeft(2, '0')}-${day.day.toString().padLeft(2, '0')}';
DateTime weekStart(DateTime day) => DateTime.utc(
  day.year,
  day.month,
  day.day,
).subtract(Duration(days: day.weekday - DateTime.monday));

enum SlotState { notOpened, active, completed, unknown }

enum AttendanceState { present, absent, excused, pending, notOpened, unknown }

extension AttendanceLabel on AttendanceState {
  String get label => switch (this) {
    AttendanceState.present => 'Có mặt',
    AttendanceState.absent => 'Vắng',
    AttendanceState.excused => 'Có phép',
    AttendanceState.pending => 'Chờ điểm danh',
    AttendanceState.notOpened => 'Chưa mở điểm danh',
    AttendanceState.unknown => 'Chưa xác định',
  };
}

AttendanceState recordStatus(String? value) => switch (value) {
  'present' => AttendanceState.present,
  'absent' => AttendanceState.absent,
  'excused' => AttendanceState.excused,
  _ => AttendanceState.unknown,
};

class StudentProfile {
  StudentProfile(this.id, Map<String, dynamic> data)
    : email = data['email'] as String? ?? '',
      emailNormalized = data['emailNormalized'] as String? ?? '',
      code = data['studentCode'] as String? ?? '',
      name = data['fullName'] as String? ?? '',
      active = data['active'] == true,
      alwaysExcused = data['attendancePolicy'] == 'alwaysExcused';
  final String id, email, emailNormalized, code, name;
  final bool active, alwaysExcused;
}

class CourseSlot {
  CourseSlot(Map<String, dynamic> data)
    : number = (data['number'] as num).toInt(),
      date = data['date'] as String,
      daySlot = (data['daySlot'] as num?)?.toInt();
  final int number;
  final String date;
  final int? daySlot;
  // Source: desktop lib/domain/schedule.dart. Clock ranges are defined
  // for 135-minute courses; do not fabricate times for 90-minute courses.
  String timeLabel(int duration) {
    const ranges = {
      1: '07:00–09:15',
      2: '09:30–11:45',
      3: '12:30–14:45',
      4: '15:00–17:15',
      5: '17:45–20:00',
    };
    final time = duration == 135 ? ranges[daySlot] : null;
    return '${daySlot == null ? '' : 'Slot $daySlot · '}${time ?? 'Chưa có giờ cụ thể'}';
  }
}

class StudentCourse {
  StudentCourse(this.id, Map<String, dynamic> data, this.student)
    : subject = data['subject'] as String? ?? '',
      classCode = data['classCode'] as String? ?? '',
      term = data['academicTerm'] as String?,
      ownerUid = data['ownerUid'] as String? ?? '',
      duration = (data['slotDurationMinutes'] as num?)?.toInt() ?? 135,
      slots =
          (data['schedule'] as List? ?? [])
              .map((e) => CourseSlot(Map<String, dynamic>.from(e as Map)))
              .toList()
            ..sort((a, b) => a.number.compareTo(b.number));
  final String id, subject, classCode, ownerUid;
  final String? term;
  final int duration;
  final StudentProfile student;
  final List<CourseSlot> slots;
  String get label => '$subject · $classCode';
}

class CourseLoad {
  const CourseLoad(
    this.courses,
    this.errors, {
    this.fromCache = false,
    this.loading = false,
  });
  final List<StudentCourse> courses;
  final Map<String, String> errors;
  final bool fromCache;
  final bool loading;
}

class SlotAttendance {
  const SlotAttendance(
    this.slot,
    this.slotState,
    this.status, {
    this.checkedInAt,
  });
  final CourseSlot slot;
  final SlotState slotState;
  final AttendanceState status;
  final DateTime? checkedInAt;
}

class AttendanceSummary {
  AttendanceSummary(this.course, this.rows);
  final StudentCourse course;
  final List<SlotAttendance> rows;
  List<SlotAttendance> get completed =>
      rows.where((r) => r.slotState == SlotState.completed).toList();
  bool get reliable => rows.every((r) => r.status != AttendanceState.unknown);
  int count(AttendanceState state) =>
      completed.where((r) => r.status == state).length;
  int get present => count(AttendanceState.present);
  int get absent => count(AttendanceState.absent);
  int get excused => count(AttendanceState.excused);
  double? get attendanceRate {
    final denominator = completed.length - excused;
    return !reliable || denominator == 0 ? null : present / denominator;
  }

  String? get warning {
    if (!reliable ||
        course.student.alwaysExcused ||
        !course.student.active ||
        course.slots.isEmpty) {
      return null;
    }
    if (absent * 5 > course.slots.length) {
      return 'Vắng trên 20% số buổi trong lịch môn. Hãy liên hệ giảng viên.';
    }
    if (absent * 10 >= course.slots.length) {
      return 'Đã vắng từ 10% số buổi trong lịch môn.';
    }
    return null;
  }
}

AttendanceState inferAttendance(
  SlotState state,
  String? canonical, {
  bool legacy = false,
}) {
  if (canonical != null) return recordStatus(canonical);
  if (legacy) return AttendanceState.present;
  return switch (state) {
    SlotState.notOpened => AttendanceState.notOpened,
    SlotState.active => AttendanceState.pending,
    SlotState.completed => AttendanceState.absent,
    SlotState.unknown => AttendanceState.unknown,
  };
}

class StudentLeave {
  StudentLeave(this.id, Map<String, dynamic> data)
    : slot = (data['slot'] as num).toInt(),
      date = data['date'] as String,
      reason = data['reason'] as String? ?? '',
      status = data['status'] as String? ?? 'pending',
      response = data['response'] as String? ?? '';
  final String id, date, reason, status, response;
  final int slot;
  String get label => switch (status) {
    'approved' => 'Đã duyệt',
    'rejected' => 'Đã từ chối',
    _ => 'Đang chờ duyệt',
  };
}

class QrPreview {
  const QrPreview(this.token, this.session, this.student);
  final String token;
  final Map<String, dynamic> session;
  final StudentProfile student;
  String get label => '${session['subject']} · ${session['classCode']}';
}

String parseQr(String raw, String publicWebUrl) {
  final uri = Uri.tryParse(raw.trim());
  final expected = Uri.parse(publicWebUrl);
  final tokens = uri?.queryParametersAll['t'];
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host != expected.host ||
      uri.port != expected.port ||
      uri.userInfo.isNotEmpty ||
      uri.fragment.isNotEmpty ||
      uri.path != '/check-in' ||
      tokens == null ||
      tokens.length != 1 ||
      !RegExp(r'^[A-Za-z0-9_-]{1,256}$').hasMatch(tokens.single)) {
    throw const FormatException('QR không thuộc hệ thống điểm danh này.');
  }
  return tokens.single;
}
