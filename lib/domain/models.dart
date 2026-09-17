class TodaySlot {
  const TodaySlot({
    required this.courseClassId,
    required this.subject,
    required this.classCode,
    required this.slot,
    required this.date,
  });

  factory TodaySlot.fromMap(Map<String, dynamic> map) => TodaySlot(
    courseClassId: map['courseClassId'] as String,
    subject: map['subject'] as String,
    classCode: map['classCode'] as String,
    slot: (map['slot'] as num).toInt(),
    date: map['date'] as String,
  );

  final String courseClassId;
  final String subject;
  final String classCode;
  final int slot;
  final String date;
}

class AttendanceSession {
  const AttendanceSession({
    required this.id,
    required this.subject,
    required this.classCode,
    required this.slot,
    required this.date,
    required this.rotationSeconds,
    required this.validitySeconds,
  });

  factory AttendanceSession.fromMap(Map<String, dynamic> map) =>
      AttendanceSession(
        id: map['sessionId'] as String,
        subject: map['subject'] as String,
        classCode: map['classCode'] as String,
        slot: (map['slot'] as num).toInt(),
        date: map['date'] as String,
        rotationSeconds: (map['rotationSeconds'] as num).toInt(),
        validitySeconds: (map['validitySeconds'] as num).toInt(),
      );

  final String id;
  final String subject;
  final String classCode;
  final int slot;
  final String date;
  final int rotationSeconds;
  final int validitySeconds;
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
