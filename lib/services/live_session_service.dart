import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';

import '../domain/class_overview.dart';
import '../domain/live_attendance.dart';
import '../domain/models.dart';
import 'attendance_api.dart';

/// Service phụ trách ghép realtime danh sách lớp (Roster) và lịch sử quét mã (CheckInRecords)
/// cho màn hình điểm danh trực tiếp (Module 3).
class LiveSessionService {
  LiveSessionService({FirebaseFirestore? firestore, AttendanceApi? api})
    : _customFirestore = firestore,
      _customApi = api;

  final FirebaseFirestore? _customFirestore;
  final AttendanceApi? _customApi;

  FirebaseFirestore get _firestore =>
      _customFirestore ?? FirebaseFirestore.instance;
  AttendanceApi get _api =>
      _customApi ?? AttendanceApi(firestore: _customFirestore);

  /// Pure function ghép Roster và Check-in records thành danh sách sinh viên trực tiếp.
  /// Rất thuận tiện và độc lập cho Unit Testing.
  static LiveAttendanceState combineRosterAndRecords({
    required List<CourseStudent> roster,
    required List<CheckInRecord> records,
    Set<String> recentStudentIds = const {},
  }) {
    // Chỉ lấy sinh viên đang active trong lớp
    final activeStudents = roster.where((s) => s.active).toList();

    if (activeStudents.isEmpty) {
      return const LiveAttendanceEmpty(
        message:
            'Lớp học hiện chưa có sinh viên nào trong danh sách hoạt động.',
      );
    }

    // Ánh xạ record theo studentId (chỉ join theo studentId duy nhất, không dùng tên/MSSV)
    final Map<String, CheckInRecord> recordsMap = {};
    for (final record in records) {
      if (record.studentId.isNotEmpty) {
        recordsMap[record.studentId] = record;
      }
    }

    final List<LiveStudentAttendance> joined = [];

    for (final student in activeStudents) {
      final record = recordsMap[student.id];

      if (record == null) {
        // Sinh viên chưa có record trong slot này -> Chưa điểm danh
        joined.add(
          LiveStudentAttendance(
            student: student,
            status: AttendanceStatus.pending,
            checkedInAt: null,
            source: null,
            syncStatus: null,
            syncError: null,
            isRecent: false,
          ),
        );
      } else {
        // Sinh viên đã có record
        final status = _parseAttendanceStatus(record.attendanceStatus);
        final isRecent = recentStudentIds.contains(student.id);

        joined.add(
          LiveStudentAttendance(
            student: student,
            status: status,
            checkedInAt: record.checkedInAt,
            source: record.source,
            syncStatus: record.syncStatus,
            syncError: record.syncError,
            isRecent: isRecent,
          ),
        );
      }
    }

    // Sắp xếp danh sách:
    // 1. Sinh viên vừa check-in trong vài giây qua (isRecent) lên đầu
    // 2. Các sinh viên còn lại sắp xếp ổn định theo Mã số sinh viên (studentCode)
    joined.sort((a, b) {
      if (a.isRecent && !b.isRecent) return -1;
      if (!a.isRecent && b.isRecent) return 1;
      if (a.isRecent && b.isRecent) {
        final aTime = a.checkedInAt ?? DateTime(0);
        final bTime = b.checkedInAt ?? DateTime(0);
        return bTime.compareTo(aTime);
      }
      return a.studentCode.compareTo(b.studentCode);
    });

    final stats = LiveSessionStats.fromList(joined);

    return LiveAttendanceLoaded(students: joined, stats: stats);
  }

  static AttendanceStatus _parseAttendanceStatus(String? raw) {
    switch (raw) {
      case 'present':
        return AttendanceStatus.present;
      case 'absent':
        return AttendanceStatus.absent;
      case 'excused':
        return AttendanceStatus.excused;
      default:
        return AttendanceStatus.present;
    }
  }

  /// Lắng nghe danh sách sinh viên trong lớp học (active roster)
  Stream<List<CourseStudent>> watchActiveCourseStudents(String courseClassId) {
    return _firestore
        .collection('courseClasses')
        .doc(courseClassId)
        .collection('students')
        .snapshots()
        .map((snapshot) {
          return snapshot.docs
              .map((doc) {
                final data = doc.data();
                return CourseStudent(
                  id: doc.id,
                  email: data['email'] as String? ?? '',
                  studentCode: data['studentCode'] as String? ?? '',
                  fullName: data['fullName'] as String? ?? '',
                  active: data['active'] as bool? ?? true,
                  attendancePolicy: data['attendancePolicy'] == 'alwaysExcused'
                      ? AttendancePolicy.alwaysExcused
                      : AttendancePolicy.normal,
                );
              })
              .where((student) => student.active)
              .toList()
            ..sort((a, b) => a.studentCode.compareTo(b.studentCode));
        });
  }

  /// Lắng nghe luồng dữ liệu hợp nhất (Roster + CheckIns) cho phiên điểm danh
  Stream<LiveAttendanceState> watchLiveAttendance({
    required AttendanceSession session,
  }) {
    late StreamController<LiveAttendanceState> controller;
    StreamSubscription<List<CourseStudent>>? rosterSub;
    StreamSubscription<List<CheckInRecord>>? checkInsSub;

    List<CourseStudent>? currentRoster;
    List<CheckInRecord>? currentRecords;
    final Set<String> knownPresentIds = {};
    final Set<String> recentIds = {};
    final Map<String, Timer> recentTimers = {};

    void emitLatest() {
      if (controller.isClosed) return;
      if (currentRoster == null || currentRecords == null) {
        controller.add(const LiveAttendanceLoading());
        return;
      }

      final state = combineRosterAndRecords(
        roster: currentRoster!,
        records: currentRecords!,
        recentStudentIds: recentIds,
      );
      controller.add(state);
    }

    void onListen() {
      controller.add(const LiveAttendanceLoading());

      // 1. Lắng nghe active roster
      rosterSub = watchActiveCourseStudents(session.courseClassId).listen(
        (roster) {
          currentRoster = roster;
          emitLatest();
        },
        onError: (error) {
          if (!controller.isClosed) {
            controller.add(
              LiveAttendanceError(
                message: 'Không thể tải danh sách sinh viên: $error',
              ),
            );
          }
        },
      );

      // 2. Lắng nghe check-ins
      checkInsSub = _api
          .watchSessionCheckIns(session)
          .listen(
            (records) {
              // Phát hiện sinh viên mới check-in để tạo micro-animation highlight
              for (final record in records) {
                if (record.attendanceStatus == 'present' &&
                    !knownPresentIds.contains(record.studentId)) {
                  knownPresentIds.add(record.studentId);
                  recentIds.add(record.studentId);

                  // Huỷ timer cũ nếu có
                  recentTimers[record.studentId]?.cancel();
                  // Sau 6 giây tự động gỡ trạng thái recent để danh sách trở về thứ tự chuẩn
                  recentTimers[record.studentId] = Timer(
                    const Duration(seconds: 6),
                    () {
                      recentIds.remove(record.studentId);
                      recentTimers.remove(record.studentId);
                      emitLatest();
                    },
                  );
                }
              }

              currentRecords = records;
              emitLatest();
            },
            onError: (error) {
              if (!controller.isClosed) {
                controller.add(
                  LiveAttendanceError(
                    message: 'Không thể tải lượt điểm danh: $error',
                  ),
                );
              }
            },
          );
    }

    void onCancel() {
      rosterSub?.cancel();
      checkInsSub?.cancel();
      for (final timer in recentTimers.values) {
        timer.cancel();
      }
      recentTimers.clear();
    }

    controller = StreamController<LiveAttendanceState>.broadcast(
      onListen: onListen,
      onCancel: onCancel,
    );

    return controller.stream;
  }
}
