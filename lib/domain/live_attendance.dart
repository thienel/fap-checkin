import 'package:intl/intl.dart';

import 'class_overview.dart';

/// Trạng thái điểm danh realtime của một sinh viên trong phiên điểm danh.
class LiveStudentAttendance {
  const LiveStudentAttendance({
    required this.student,
    required this.status,
    this.checkedInAt,
    this.source,
    this.syncStatus,
    this.syncError,
    this.isRecent = false,
  });

  final CourseStudent student;
  final AttendanceStatus status;
  final DateTime? checkedInAt;
  final String? source;
  final String? syncStatus;
  final String? syncError;
  final bool isRecent;

  String get id => student.id;
  String get studentCode => student.studentCode;
  String get fullName => student.fullName;
  String get email => student.email;
  String get displayName => student.displayName;

  /// Hiển thị giờ điểm danh theo định dạng HH:mm:ss nếu có
  String get formattedCheckInTime {
    if (checkedInAt == null) return '--:--:--';
    return DateFormat('HH:mm:ss').format(checkedInAt!);
  }

  /// Kiểm tra xem sinh viên đã điểm danh hay chưa
  bool get isPresent => status == AttendanceStatus.present;
  bool get isNotYetOpen =>
      status == AttendanceStatus.pending ||
      status == AttendanceStatus.notYetOpen;
  bool get isExcused => status == AttendanceStatus.excused;
  bool get isAbsent => status == AttendanceStatus.absent;

  LiveStudentAttendance copyWith({
    CourseStudent? student,
    AttendanceStatus? status,
    DateTime? checkedInAt,
    String? source,
    String? syncStatus,
    String? syncError,
    bool? isRecent,
  }) {
    return LiveStudentAttendance(
      student: student ?? this.student,
      status: status ?? this.status,
      checkedInAt: checkedInAt ?? this.checkedInAt,
      source: source ?? this.source,
      syncStatus: syncStatus ?? this.syncStatus,
      syncError: syncError ?? this.syncError,
      isRecent: isRecent ?? this.isRecent,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LiveStudentAttendance &&
          runtimeType == other.runtimeType &&
          student == other.student &&
          status == other.status &&
          checkedInAt == other.checkedInAt &&
          source == other.source &&
          syncStatus == other.syncStatus &&
          isRecent == other.isRecent;

  @override
  int get hashCode =>
      student.hashCode ^
      status.hashCode ^
      checkedInAt.hashCode ^
      source.hashCode ^
      syncStatus.hashCode ^
      isRecent.hashCode;
}

/// Thống kê sĩ số và tỷ lệ điểm danh trong phiên hiện tại.
class LiveSessionStats {
  const LiveSessionStats({
    required this.totalActive,
    required this.presentCount,
    required this.notYetOpenCount,
    required this.excusedCount,
    required this.absentCount,
  });

  final int totalActive;
  final int presentCount;
  final int notYetOpenCount;
  final int excusedCount;
  final int absentCount;

  /// Tỷ lệ có mặt (0.0 -> 1.0)
  double get rate => totalActive > 0 ? (presentCount / totalActive) : 0.0;

  /// Tỷ lệ có mặt dưới dạng phần trăm (VD: "85.7%")
  String get percentageFormatted {
    if (totalActive == 0) return '0%';
    return '${(rate * 100).toStringAsFixed(1)}%';
  }

  factory LiveSessionStats.fromList(List<LiveStudentAttendance> list) {
    int present = 0;
    int notYet = 0;
    int excused = 0;
    int absent = 0;

    for (final item in list) {
      switch (item.status) {
        case AttendanceStatus.present:
          present++;
          break;
        case AttendanceStatus.notYetOpen:
        case AttendanceStatus.pending:
          notYet++;
          break;
        case AttendanceStatus.excused:
          excused++;
          break;
        case AttendanceStatus.absent:
          absent++;
          break;
      }
    }

    return LiveSessionStats(
      totalActive: list.length,
      presentCount: present,
      notYetOpenCount: notYet,
      excusedCount: excused,
      absentCount: absent,
    );
  }
}

/// Các trạng thái tải dữ liệu realtime của màn hình điểm danh.
sealed class LiveAttendanceState {
  const LiveAttendanceState();
}

class LiveAttendanceLoading extends LiveAttendanceState {
  const LiveAttendanceLoading();
}

class LiveAttendanceEmpty extends LiveAttendanceState {
  const LiveAttendanceEmpty({required this.message});
  final String message;
}

class LiveAttendanceError extends LiveAttendanceState {
  const LiveAttendanceError({required this.message});
  final String message;
}

class LiveAttendanceLoaded extends LiveAttendanceState {
  const LiveAttendanceLoaded({required this.students, required this.stats});

  final List<LiveStudentAttendance> students;
  final LiveSessionStats stats;
}
