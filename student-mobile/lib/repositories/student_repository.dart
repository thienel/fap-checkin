import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../models/student_models.dart';

class StudentRepository {
  StudentRepository({
    required this.uid,
    required this.email,
    FirebaseFirestore? db,
    FirebaseAuth? auth,
  }) : db = db ?? FirebaseFirestore.instance,
       auth = auth ?? FirebaseAuth.instance;
  final String uid, email;
  final FirebaseFirestore db;
  final FirebaseAuth auth;
  String get studentId => studentIdFor(email);
  String get normalizedEmail => normalizeEmail(email);
  void _checkAccount() {
    if (auth.currentUser?.uid != uid) {
      throw StateError('Tài khoản đã thay đổi. Hãy mở lại màn hình.');
    }
  }

  DocumentReference<Map<String, dynamic>> _course(String id) =>
      db.collection('courseClasses').doc(id);

  Future<void> _access(String courseId, StudentProfile student) async {
    _checkAccount();
    if (student.id != studentId ||
        student.emailNormalized != normalizedEmail ||
        !student.active) {
      throw StateError(
        'Roster chưa khớp email đăng nhập. Hãy liên hệ giảng viên.',
      );
    }
    final ref = _course(courseId).collection('studentAccess').doc(uid);
    await db.runTransaction((tx) async {
      final existing = await tx.get(ref);
      _checkAccount();
      if (existing.exists) {
        if (existing.data()?['studentId'] != studentId ||
            existing.data()?['emailNormalized'] != normalizedEmail) {
          throw StateError('Liên kết tài khoản không khớp roster.');
        }
      } else {
        tx.set(ref, {
          'studentId': studentId,
          'emailNormalized': normalizedEmail,
          'createdAt': FieldValue.serverTimestamp(),
        });
      }
    });
  }

  Stream<CourseLoad> watchCourses() {
    late StreamController<CourseLoad> output;
    StreamSubscription? rosterSubscription;
    final courseSubscriptions = <StreamSubscription>[];
    final courses = <String, StudentCourse>{};
    final errors = <String, String>{};
    final pendingDocuments = <String>{};
    var generation = 0;
    var fromCache = true;
    var cancelled = false;
    void emit() {
      if (cancelled) return;
      final list = courses.values.toList()
        ..sort((a, b) => a.label.compareTo(b.label));
      output.add(
        CourseLoad(
          list,
          Map.of(errors),
          fromCache: fromCache,
          loading: pendingDocuments.isNotEmpty,
        ),
      );
    }

    output = StreamController<CourseLoad>(
      onListen: () {
        rosterSubscription = db
            .collectionGroup('students')
            .where('emailNormalized', isEqualTo: normalizedEmail)
            .where('active', isEqualTo: true)
            .snapshots(includeMetadataChanges: true)
            .listen(
              (roster) async {
                final current = ++generation;
                final previous = courseSubscriptions.toList();
                courseSubscriptions.clear();
                for (final subscription in previous) {
                  await subscription.cancel();
                }
                if (cancelled || current != generation) return;
                courses.clear();
                errors.clear();
                pendingDocuments.clear();
                fromCache = roster.metadata.isFromCache;
                // Do not display an empty cache as "no enrollment" or bootstrap
                // membership from cached data after it has been revoked.
                if (fromCache) {
                  emit();
                  return;
                }
                pendingDocuments.addAll(
                  roster.docs.map((d) => d.reference.path),
                );
                emit();
                for (final document in roster.docs) {
                  if (cancelled || current != generation) return;
                  final parts = document.reference.path.split('/');
                  if (parts.length != 4 ||
                      parts[0] != 'courseClasses' ||
                      parts[2] != 'students') {
                    errors[document.id] =
                        'Roster nằm ngoài cấu trúc lớp được hỗ trợ.';
                    pendingDocuments.remove(document.reference.path);
                    continue;
                  }
                  final id = parts[1];
                  try {
                    final student = StudentProfile(
                      document.id,
                      document.data(),
                    );
                    await _access(id, student);
                    if (cancelled || current != generation) return;
                    courseSubscriptions.add(
                      _course(id)
                          .snapshots(includeMetadataChanges: true)
                          .listen(
                            (snapshot) {
                              if (cancelled || current != generation) return;
                              if (snapshot.metadata.isFromCache) return;
                              pendingDocuments.remove(document.reference.path);
                              if (!snapshot.exists) {
                                courses.remove(id);
                                errors[id] = 'Lớp không còn tồn tại.';
                              } else if (!snapshot.metadata.isFromCache) {
                                try {
                                  courses[id] = StudentCourse(
                                    id,
                                    snapshot.data()!,
                                    student,
                                  );
                                  errors.remove(id);
                                } catch (_) {
                                  errors[id] = 'Dữ liệu lịch lớp chưa hợp lệ.';
                                }
                              }
                              emit();
                            },
                            onError: (Object error) {
                              if (cancelled || current != generation) return;
                              pendingDocuments.remove(document.reference.path);
                              courses.remove(id);
                              errors[id] = friendlyError(error);
                              emit();
                            },
                          ),
                    );
                  } catch (error) {
                    if (cancelled || current != generation) return;
                    pendingDocuments.remove(document.reference.path);
                    errors[id] = friendlyError(error);
                  }
                }
                emit();
              },
              onError: (Object error) {
                if (!cancelled) output.addError(error);
              },
            );
      },
      onCancel: () async {
        cancelled = true;
        ++generation;
        await rosterSubscription?.cancel();
        for (final subscription in courseSubscriptions) {
          await subscription.cancel();
        }
      },
    );
    return output.stream;
  }

  Stream<StudentCourse> watchCourse(String id) {
    late StreamController<StudentCourse> output;
    final subscriptions = <StreamSubscription>[];
    Map<String, dynamic>? course, student;
    var cancelled = false;
    void emit() {
      if (cancelled || course == null || student == null) return;
      try {
        _checkAccount();
        if (student!['active'] != true) {
          throw StateError('Bạn không còn quyền xem lớp này.');
        }
        output.add(
          StudentCourse(id, course!, StudentProfile(studentId, student!)),
        );
      } catch (e) {
        output.addError(e);
      }
    }

    output = StreamController<StudentCourse>(
      onListen: () {
        subscriptions.add(
          _course(id)
              .snapshots(includeMetadataChanges: true)
              .listen(
                (snapshot) {
                  if (snapshot.metadata.isFromCache || cancelled) return;
                  course = snapshot.data();
                  if (course == null) {
                    output.addError(StateError('Lớp không còn tồn tại.'));
                  } else {
                    emit();
                  }
                },
                onError: (Object e) {
                  if (!cancelled) output.addError(e);
                },
              ),
        );
        subscriptions.add(
          _course(id)
              .collection('students')
              .doc(studentId)
              .snapshots(includeMetadataChanges: true)
              .listen(
                (snapshot) {
                  if (snapshot.metadata.isFromCache || cancelled) return;
                  student = snapshot.data();
                  if (student == null) {
                    output.addError(StateError('Roster không còn tồn tại.'));
                  } else {
                    emit();
                  }
                },
                onError: (Object e) {
                  if (!cancelled) output.addError(e);
                },
              ),
        );
      },
      onCancel: () async {
        cancelled = true;
        for (final subscription in subscriptions) {
          await subscription.cancel();
        }
      },
    );
    return output.stream;
  }

  Stream<AttendanceSummary> watchAttendance(StudentCourse course) {
    late StreamController<AttendanceSummary> output;
    final subscriptions = <StreamSubscription>[];
    final canonical = <int, Map<String, dynamic>?>{};
    final legacy = <int, bool>{};
    List<Map<String, dynamic>>? sessions;
    var cancelled = false;
    void emit() {
      if (cancelled) return;
      final rows = course.slots.map((slot) {
        final history = sessions
            ?.where((s) => s['slot'] == slot.number)
            .toList();
        final state = history == null
            ? SlotState.unknown
            : history.any((s) => s['status'] == 'active')
            ? SlotState.active
            : history.isEmpty
            ? SlotState.notOpened
            : SlotState.completed;
        final data = canonical[slot.number];
        final ready =
            canonical.containsKey(slot.number) &&
            (data != null || legacy.containsKey(slot.number));
        return SlotAttendance(
          slot,
          state,
          ready
              ? inferAttendance(
                  state,
                  data == null
                      ? null
                      : (data['attendanceStatus'] as String? ?? 'unknown'),
                  legacy: legacy[slot.number] == true,
                )
              : AttendanceState.unknown,
          checkedInAt: (data?['checkedInAt'] as Timestamp?)?.toDate(),
        );
      }).toList();
      output.add(AttendanceSummary(course, rows));
    }

    output = StreamController<AttendanceSummary>(
      onListen: () {
        subscriptions.add(
          db
              .collection('attendanceSessions')
              .where('courseClassId', isEqualTo: course.id)
              .snapshots(includeMetadataChanges: true)
              .listen(
                (snapshot) {
                  sessions = snapshot.metadata.isFromCache
                      ? null
                      : snapshot.docs.map((d) => d.data()).toList();
                  emit();
                },
                onError: (Object error) {
                  sessions = null;
                  output.addError(error);
                },
              ),
        );
        for (final slot in course.slots) {
          final ref = db
              .collection('attendance')
              .doc(course.id)
              .collection('slots')
              .doc('${slot.number}');
          subscriptions.add(
            ref
                .collection('records')
                .doc(studentId)
                .snapshots(includeMetadataChanges: true)
                .listen(
                  (snapshot) {
                    if (!snapshot.metadata.isFromCache &&
                        !snapshot.metadata.hasPendingWrites) {
                      canonical[slot.number] = snapshot.data();
                      emit();
                    }
                  },
                  onError: (Object error) {
                    canonical.remove(slot.number);
                    output.addError(error);
                  },
                ),
          );
          subscriptions.add(
            ref
                .collection('checkIns')
                .doc(uid)
                .snapshots(includeMetadataChanges: true)
                .listen(
                  (snapshot) {
                    if (!snapshot.metadata.isFromCache) {
                      legacy[slot.number] = snapshot.exists;
                      emit();
                    }
                  },
                  onError: (Object error) {
                    legacy.remove(slot.number);
                    output.addError(error);
                  },
                ),
          );
        }
      },
      onCancel: () async {
        cancelled = true;
        for (final sub in subscriptions) {
          await sub.cancel();
        }
      },
    );
    return output.stream;
  }

  Stream<List<StudentLeave>> watchLeave(String courseId) =>
      _course(courseId)
          .collection('leaveRequests')
          .where('firebaseUid', isEqualTo: uid)
          .snapshots(includeMetadataChanges: true)
          .map(
            (snapshot) =>
                snapshot.docs
                    .where((d) => !d.metadata.hasPendingWrites)
                    .map((d) => StudentLeave(d.id, d.data()))
                    .toList()
                  ..sort((a, b) => a.slot.compareTo(b.slot)),
          );

  Future<void> submitLeave(
    StudentCourse course,
    List<int> numbers,
    String reason,
  ) async {
    _checkAccount();
    final text = reason.trim();
    if (text.length < 10 || text.length > 1000 || numbers.isEmpty) {
      throw StateError('Chọn buổi học và nhập lý do từ 10 đến 1000 ký tự.');
    }
    final today = dateKey(vietnamNow());
    final selected = numbers
        .toSet()
        .map((n) => course.slots.firstWhere((s) => s.number == n))
        .toList();
    if (selected.any((s) => s.date.compareTo(today) <= 0)) {
      throw StateError('Chỉ gửi đơn cho buổi học từ ngày mai.');
    }
    final existing = await _course(course.id)
        .collection('leaveRequests')
        .where('firebaseUid', isEqualTo: uid)
        .get(const GetOptions(source: Source.server));
    if (existing.docs.any((d) => numbers.contains(d.data()['slot']))) {
      throw StateError('Một buổi đã có đơn. Hãy tải lại danh sách.');
    }
    _checkAccount();
    final batch = db.batch();
    for (final slot in selected) {
      batch.set(
        _course(course.id)
            .collection('leaveRequests')
            .doc('${studentId}_${slot.number}'),
        {
          'ownerUid': course.ownerUid,
          'courseClassId': course.id,
          'studentId': studentId,
          'firebaseUid': uid,
          'emailNormalized': normalizedEmail,
          'slot': slot.number,
          'date': slot.date,
          'slotDate': Timestamp.fromDate(
            DateTime.parse('${slot.date}T00:00:00Z'),
          ),
          'reason': text,
          'status': 'pending',
          'createdAt': FieldValue.serverTimestamp(),
        },
      );
    }
    // One atomic batch for the existing <=30-slot schedules. Duplicate writes
    // are denied by Rules; success is only shown after server acknowledgement.
    await batch.commit();
  }

  Future<QrPreview> preview(String token) async {
    _checkAccount();
    final qr = await db
        .collection('qrTokens')
        .doc(token)
        .get(const GetOptions(source: Source.server));
    if (!qr.exists) throw StateError('QR không còn tồn tại. Hãy quét lại.');
    final session = await db
        .collection('attendanceSessions')
        .doc(qr.data()!['sessionId'] as String)
        .get(const GetOptions(source: Source.server));
    if (!session.exists || session.data()?['status'] != 'active') {
      throw StateError('Phiên điểm danh đã dừng.');
    }
    final data = session.data()!;
    final student = await _course(data['courseClassId'] as String)
        .collection('students')
        .doc(studentId)
        .get(const GetOptions(source: Source.server));
    if (!student.exists || student.data()?['active'] != true) {
      throw StateError('Email này chưa có trong lớp.');
    }
    return QrPreview(token, {
      ...data,
      'sessionId': session.id,
    }, StudentProfile(studentId, student.data()!));
  }

  Future<AttendanceState> checkIn(String token, String code) async {
    _checkAccount();
    final checkout = code.trim().toUpperCase();
    if (!RegExp(r'^[A-Z0-9]{5}$').hasMatch(checkout)) {
      throw StateError('Mã xác nhận gồm 5 chữ cái hoặc chữ số.');
    }
    return db.runTransaction((tx) async {
      final qr = await tx.get(db.collection('qrTokens').doc(token));
      if (!qr.exists) throw StateError('QR đã hết hạn hoặc không tồn tại.');
      final sessionId = qr.data()!['sessionId'] as String;
      final sessionDoc = await tx.get(
        db.collection('attendanceSessions').doc(sessionId),
      );
      final s = sessionDoc.data();
      if (s == null || s['status'] != 'active') {
        throw StateError('Phiên điểm danh đã dừng.');
      }
      final courseId = s['courseClassId'] as String;
      final profile = await tx.get(
        _course(courseId).collection('students').doc(studentId),
      );
      final student = profile.data();
      if (student == null ||
          student['active'] != true ||
          student['emailNormalized'] != normalizedEmail) {
        throw StateError('Email này chưa có trong lớp đang học.');
      }
      final ref = db
          .collection('attendance')
          .doc(courseId)
          .collection('slots')
          .doc(s['slotKey'] as String)
          .collection('records')
          .doc(studentId);
      final current = await tx.get(ref);
      _checkAccount();
      if (current.exists) {
        return recordStatus(current.data()?['attendanceStatus'] as String?);
      }
      final now = FieldValue.serverTimestamp();
      tx.set(ref, {
        'ownerUid': s['ownerUid'],
        'firebaseUid': uid,
        'studentId': studentId,
        'email': student['email'],
        'emailNormalized': normalizedEmail,
        'studentCode': student['studentCode'],
        'fullName': student['fullName'],
        'sessionId': sessionId,
        'courseClassId': courseId,
        'subject': s['subject'],
        'classCode': s['classCode'],
        'slot': s['slot'],
        'slotKey': s['slotKey'],
        'date': s['date'],
        'qrToken': token,
        'checkoutCode': checkout,
        'checkedInAt': now,
        'createdAt': now,
        'updatedAt': now,
        'updatedBy': uid,
        'syncStatus': 'pending',
        'attendanceStatus': 'present',
        'recordSource': 'qr',
        'revision': 1,
      });
      return AttendanceState.present;
    });
  }
}

String friendlyError(Object error) {
  if (error is FirebaseException) {
    return switch (error.code) {
      'permission-denied' => 'Chưa có quyền truy cập hoặc QR/mã xác nhận đã thay đổi. Hãy tải lại, quét QR mới và kiểm tra email với giảng viên.',
      'unavailable' => 'Chưa kết nối được máy chủ. Kiểm tra mạng và thử lại.',
      'failed-precondition' =>
        'Dữ liệu máy chủ chưa sẵn sàng. Kiểm tra Rules/indexes đã triển khai.',
      _ => 'Không thể hoàn thành thao tác (${error.code}). Hãy thử lại.',
    };
  }
  if (error is StateError) return error.message.toString();
  if (error is FormatException) return error.message;
  return 'Không thể tải dữ liệu. Hãy thử lại.';
}
