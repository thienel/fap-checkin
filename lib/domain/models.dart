class TodaySlot {
  const TodaySlot({
    required this.courseClassId,
    required this.subject,
    required this.classCode,
    required this.slot,
    required this.slotCount,
    required this.daySlot,
    required this.date,
  });

  factory TodaySlot.fromMap(Map<String, dynamic> map) => TodaySlot(
    courseClassId: map['courseClassId'] as String,
    subject: map['subject'] as String,
    classCode: map['classCode'] as String,
    slot: (map['slot'] as num).toInt(),
    slotCount: (map['slotCount'] as num?)?.toInt() ?? 0,
    daySlot: (map['daySlot'] as num?)?.toInt(),
    date: map['date'] as String,
  );

  final String courseClassId;
  final String subject;
  final String classCode;

  /// Thứ tự buổi của môn học, ví dụ buổi 3/20.
  final int slot;
  final int slotCount;

  /// Khung giờ trong ngày (Slot 1–7). Null với dữ liệu cũ chưa được xếp.
  final int? daySlot;
  final String date;
}

class AttendanceSession {
  const AttendanceSession({
    required this.id,
    required this.courseClassId,
    required this.subject,
    required this.classCode,
    required this.slot,
    required this.slotCount,
    required this.daySlot,
    required this.date,
    required this.rotationSeconds,
    required this.validitySeconds,
  });

  factory AttendanceSession.fromMap(Map<String, dynamic> map) =>
      AttendanceSession(
        id: map['sessionId'] as String,
        courseClassId: map['courseClassId'] as String,
        subject: map['subject'] as String,
        classCode: map['classCode'] as String,
        slot: (map['slot'] as num).toInt(),
        slotCount: (map['slotCount'] as num?)?.toInt() ?? 0,
        daySlot: (map['daySlot'] as num?)?.toInt(),
        date: map['date'] as String,
        rotationSeconds: (map['rotationSeconds'] as num).toInt(),
        validitySeconds: (map['validitySeconds'] as num).toInt(),
      );

  final String id;
  final String courseClassId;
  final String subject;
  final String classCode;
  final int slot;
  final int slotCount;
  final int? daySlot;
  final String date;
  final int rotationSeconds;
  final int validitySeconds;
}

class CheckInRecord {
  const CheckInRecord({
    required this.id,
    required this.studentId,
    required this.email,
    required this.studentCode,
    required this.fullName,
    required this.syncStatus,
    required this.syncError,
    required this.source,
    required this.attendanceStatus,
    required this.checkedInAt,
  });

  final String id;
  final String studentId;
  final String email;
  final String studentCode;
  final String fullName;
  final String syncStatus;
  final String? syncError;
  final String source;
  final String attendanceStatus;
  final DateTime? checkedInAt;
}

class IssuedQr {
  const IssuedQr({required this.url, required this.expiresAt});

  factory IssuedQr.fromMap(Map<String, dynamic> map) => IssuedQr(
    url: map['checkInUrl'] as String,
    expiresAt: DateTime.parse(map['expiresAt'] as String).toLocal(),
  );

  final String url;
  final DateTime expiresAt;
}

class CourseClassSummary {
  const CourseClassSummary({
    required this.id,
    required this.subject,
    required this.classCode,
  });

  final String id;
  final String subject;
  final String classCode;

  String get label => '$subject · $classCode';
}

class RosterImportResult {
  const RosterImportResult({
    required this.totalRows,
    required this.validRows,
    required this.invalidRows,
  });

  final int totalRows;
  final int validRows;
  final int invalidRows;
}
