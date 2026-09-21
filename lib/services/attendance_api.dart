import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:crypto/crypto.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../domain/models.dart';
import '../domain/class_overview.dart';
import '../domain/roster_import.dart';
import '../domain/schedule.dart';
import '../firebase_options.dart';
import 'apps_script_sheet_service.dart';

class AttendanceApi {
  AttendanceApi({
    FirebaseFirestore? firestore,
    FirebaseAuth? auth,
    AppsScriptSheetService? sheets,
  }) : _firestore = firestore ?? FirebaseFirestore.instance,
       _auth = auth ?? FirebaseAuth.instance,
       _sheets = sheets ?? AppsScriptSheetService();

  final FirebaseFirestore _firestore;
  final FirebaseAuth _auth;
  final AppsScriptSheetService _sheets;
  final Random _secureRandom = Random.secure();
  final Map<String, Future<String?>> _syncingRecords = {};

  bool get isSheetSyncConfigured => _sheets.isConfigured;

  Future<List<CourseClassSummary>> getCourseClasses() => _guard(() async {
    final uid = _teacherUid();
    final snapshot = await _firestore
        .collection('courseClasses')
        .where('ownerUid', isEqualTo: uid)
        .get();
    final classes = snapshot.docs.map((document) {
      final data = document.data();
      return CourseClassSummary(
        id: document.id,
        subject: data['subject'] as String? ?? '',
        classCode: data['classCode'] as String? ?? '',
      );
    }).toList();
    classes.sort((left, right) => left.label.compareTo(right.label));
    return classes;
  });

  Future<CourseOverview> getCourseOverview(
    String courseClassId,
  ) => _guard(() async {
    final uid = _teacherUid();
    final courseReference = _firestore
        .collection('courseClasses')
        .doc(courseClassId);
    final courseDocument = await courseReference.get();
    final course = courseDocument.data();
    if (!courseDocument.exists || course == null || course['ownerUid'] != uid) {
      throw const AttendanceApiException('Không tìm thấy môn–lớp.');
    }

    final studentSnapshot = await courseReference.collection('students').get();
    final students =
        studentSnapshot.docs.map((document) {
          final data = document.data();
          return CourseStudent(
            id: document.id,
            email: data['email'] as String? ?? '',
            studentCode: data['studentCode'] as String? ?? '',
            fullName: data['fullName'] as String? ?? '',
            active: data['active'] as bool? ?? true,
            attendancePolicy: data['attendancePolicy'] == 'alwaysExcused'
                ? AttendancePolicy.alwaysExcused
                : AttendancePolicy.normal,
          );
        }).toList()..sort(
          (left, right) => left.displayName.compareTo(right.displayName),
        );

    final sessionSnapshot = await _firestore
        .collection('attendanceSessions')
        .where('ownerUid', isEqualTo: uid)
        .get();
    final sessionsBySlot =
        <int, List<QueryDocumentSnapshot<Map<String, dynamic>>>>{};
    for (final session in sessionSnapshot.docs) {
      final data = session.data();
      if (data['courseClassId'] != courseClassId || data['slot'] is! num) {
        continue;
      }
      sessionsBySlot
          .putIfAbsent((data['slot'] as num).toInt(), () => [])
          .add(session);
    }

    final rawSchedule = course['schedule'];
    final schedule = rawSchedule is List
        ? rawSchedule.whereType<Map>().map(Map<String, dynamic>.from).toList()
        : <Map<String, dynamic>>[];
    schedule.sort((a, b) => (a['number'] as num).compareTo(b['number'] as num));
    final slots = <CourseSlotOverview>[];
    final recordSnapshots = <int, QuerySnapshot<Map<String, dynamic>>>{};
    final legacySnapshots = <int, QuerySnapshot<Map<String, dynamic>>>{};
    await Future.wait([
      for (final item in schedule)
        (() async {
          final number = (item['number'] as num).toInt();
          final slotReference = _firestore
              .collection('attendance')
              .doc(courseClassId)
              .collection('slots')
              .doc('$number');
          final snapshots = await Future.wait([
            slotReference.collection('records').get(),
            slotReference
                .collection('checkIns')
                .where('ownerUid', isEqualTo: uid)
                .get(),
          ]);
          recordSnapshots[number] = snapshots[0];
          legacySnapshots[number] = snapshots[1];
        })(),
    ]);
    for (final item in schedule) {
      final number = (item['number'] as num).toInt();
      final sessions = sessionsBySlot[number] ?? const [];
      final active = sessions.any((doc) => doc.data()['status'] == 'active');
      slots.add(
        CourseSlotOverview(
          number: number,
          date: item['date'] as String? ?? '',
          daySlot: (item['daySlot'] as num?)?.toInt(),
          state: active
              ? CourseSlotState.active
              : sessions.isEmpty
              ? CourseSlotState.notOpened
              : CourseSlotState.completed,
          sessionIds: sessions.map((doc) => doc.id).toList(),
        ),
      );
    }

    final entries = <String, AttendanceEntry>{};
    for (final slot in slots) {
      final documents = [
        ...?legacySnapshots[slot.number]?.docs,
        ...?recordSnapshots[slot.number]?.docs,
      ];
      for (final document in documents) {
        final data = document.data();
        final studentId = data['studentId'] as String?;
        if (studentId == null) continue;
        final rawStatus = data['attendanceStatus'] as String? ?? 'present';
        final source = data['recordSource'] as String? ?? 'qr';
        final status = switch (rawStatus) {
          'excused' => AttendanceStatus.excused,
          'absent' => AttendanceStatus.absent,
          _ => AttendanceStatus.present,
        };
        entries[attendanceEntryKey(studentId, slot.number)] = AttendanceEntry(
          studentId: studentId,
          slot: slot.number,
          status: status,
          source: source,
          syncStatus: data['syncStatus'] as String? ?? 'pending',
          checkedInAt: (data['checkedInAt'] as Timestamp?)?.toDate(),
          sessionId: data['sessionId'] as String?,
          reason: data['reason'] as String?,
          updatedAt: (data['updatedAt'] as Timestamp?)?.toDate(),
          updatedBy: data['updatedBy'] as String?,
        );
      }
    }
    return CourseOverview(
      courseClassId: courseClassId,
      subject: course['subject'] as String? ?? '',
      classCode: course['classCode'] as String? ?? '',
      students: students,
      slots: slots,
      entries: entries,
    );
  });

  Future<StudentAttendanceDetail> getStudentAttendanceDetail({
    required String courseClassId,
    required String studentId,
  }) => _guard(() async {
    final overview = await getCourseOverview(courseClassId);
    CourseStudent? student;
    for (final item in overview.students) {
      if (item.id == studentId) {
        student = item;
        break;
      }
    }
    if (student == null) {
      throw const AttendanceApiException(
        'Không tìm thấy sinh viên trong danh sách lớp.',
      );
    }
    return StudentAttendanceDetail(
      student: student,
      attendedSlots: overview.attendedCount(student),
      totalSlots: overview.slots.length,
      openedSlots: overview.openedSlotCount,
      excusedSlots: overview.excusedCount(student),
    );
  });

  Future<RosterImportResult> importRoster({
    required String courseClassId,
    required String fileName,
    required List<RosterRow> rows,
    required RosterImportMode mode,
    void Function(int completed, int total)? onProgress,
  }) => _guard(() async {
    final uid = _teacherUid();
    final courseReference = _firestore
        .collection('courseClasses')
        .doc(courseClassId);
    final course = await courseReference.get();
    if (!course.exists || course.data()?['ownerUid'] != uid) {
      throw const AttendanceApiException('Không tìm thấy môn–lớp.');
    }

    final validRows = rows.where((row) => row.isValid).toList();
    final students = courseReference.collection('students');
    final existingSnapshot = await students.get();
    final existing = {
      for (final doc in existingSnapshot.docs) doc.id: doc.data(),
    };
    var completed = 0;
    final totalWrites =
        validRows.length +
        (mode == RosterImportMode.replaceInactive ? existing.length : 0);

    Future<void> commitChunks(
      List<void Function(WriteBatch)> operations,
    ) async {
      for (var start = 0; start < operations.length; start += 400) {
        final batch = _firestore.batch();
        final end = min(start + 400, operations.length);
        for (var index = start; index < end; index++) {
          operations[index](batch);
        }
        await batch.commit();
        completed += end - start;
        onProgress?.call(completed, totalWrites);
      }
    }

    if (mode == RosterImportMode.replaceInactive && existing.isNotEmpty) {
      await commitChunks([
        for (final document in existingSnapshot.docs)
          (batch) => batch.update(document.reference, {
            'active': false,
            'updatedAt': FieldValue.serverTimestamp(),
            'updatedBy': uid,
          }),
      ]);
    }

    await commitChunks([
      for (final row in validRows)
        (batch) {
          final studentId = sha256
              .convert(utf8.encode(row.emailNormalized))
              .toString();
          final previous = existing[studentId];
          batch.set(students.doc(studentId), {
            'emailNormalized': row.emailNormalized,
            'email': row.email.trim(),
            'studentCode': row.studentCode.trim(),
            'fullName': row.fullName.trim(),
            'attendancePolicy': previous?['attendancePolicy'] ?? 'normal',
            'active': true,
            'importedAt': FieldValue.serverTimestamp(),
            'importedBy': uid,
          }, SetOptions(merge: true));
        },
    ]);

    await courseReference.collection('imports').add({
      'fileName': fileName,
      'totalRows': rows.length,
      'validRows': validRows.length,
      'invalidRows': rows.length - validRows.length,
      'mode': mode.name,
      'createdAt': FieldValue.serverTimestamp(),
      'createdBy': uid,
    });
    return RosterImportResult(
      totalRows: rows.length,
      validRows: validRows.length,
      invalidRows: rows.length - validRows.length,
    );
  });

  Future<void> createCourseClass({
    required String subject,
    required String classCode,
    required DateTime startDate,
    required SchedulePreset preset,
    required int daySlot,
  }) => _guard(() async {
    final uid = _teacherUid();
    final normalizedSubject = _requiredCode(subject, 'Mã môn');
    final normalizedClass = _requiredCode(classCode, 'Mã lớp');
    _validateDaySlot(daySlot);
    final schedule = generateSchedule(startDate: startDate, preset: preset);
    final id = '${normalizedSubject}_$normalizedClass';
    final reference = _firestore.collection('courseClasses').doc(id);

    await _firestore.runTransaction((transaction) async {
      if ((await transaction.get(reference)).exists) {
        throw const AttendanceApiException('Môn–lớp này đã tồn tại.');
      }
      transaction.set(reference, {
        'subject': normalizedSubject,
        'classCode': normalizedClass,
        'startDate': _isoDate(startDate),
        'slotCount': preset.slotCount,
        'weekLabel': preset.weekLabel,
        'schedule': schedule
            .map(
              (item) => {
                'number': item.number,
                'date': _isoDate(item.date),
                'daySlot': daySlot,
              },
            )
            .toList(),
        'ownerUid': uid,
        'createdAt': FieldValue.serverTimestamp(),
      });
    });
  });

  Future<void> createTestCourseClassNow() => _guard(() async {
    final uid = _teacherUid();
    final user = _auth.currentUser!;
    final now = DateTime.now();
    final date = _isoDate(now);
    final classCode = 'DEMO_${date.replaceAll('-', '')}';
    final reference = _firestore
        .collection('courseClasses')
        .doc('TEST_$classCode');
    final schedule = generateDebugDaySchedule(now);

    await _firestore.runTransaction((transaction) async {
      final existing = await transaction.get(reference);
      if (existing.exists) {
        if (existing.data()?['ownerUid'] != uid) {
          throw const AttendanceApiException(
            'Lớp demo hôm nay đã thuộc một giảng viên khác.',
          );
        }
        transaction.update(reference, {
          'subject': debugCourseSubject,
          'classCode': classCode,
          'startDate': date,
          'slotCount': schedule.length,
          'weekLabel': 1,
          'schedule': schedule
              .map(
                (item) => {
                  'number': item.number,
                  'date': _isoDate(item.date),
                  'daySlot': item.daySlot,
                },
              )
              .toList(),
          'updatedAt': FieldValue.serverTimestamp(),
        });
        return;
      }
      transaction.set(reference, {
        'subject': debugCourseSubject,
        'classCode': classCode,
        'startDate': date,
        'slotCount': schedule.length,
        'weekLabel': 1,
        'schedule': schedule
            .map(
              (item) => {
                'number': item.number,
                'date': _isoDate(item.date),
                'daySlot': item.daySlot,
              },
            )
            .toList(),
        'ownerUid': uid,
        'createdAt': FieldValue.serverTimestamp(),
      });
    });

    // A generated demo course must be immediately testable. Add the current
    // teacher email to its roster so the same Google account can scan the QR.
    // Production courses still require the normal CSV/XLSX roster import.
    final email = user.email?.trim();
    if (email != null && email.isNotEmpty) {
      final emailNormalized = email.toLowerCase();
      final studentId = sha256.convert(utf8.encode(emailNormalized)).toString();
      await reference.collection('students').doc(studentId).set({
        'emailNormalized': emailNormalized,
        'email': email,
        'studentCode': 'DEMO',
        'fullName': user.displayName?.trim().isNotEmpty == true
            ? user.displayName!.trim()
            : email.split('@').first,
        'attendancePolicy': 'normal',
        'active': true,
        'importedAt': FieldValue.serverTimestamp(),
        'importedBy': uid,
      }, SetOptions(merge: true));
    }
  });

  Future<List<TodaySlot>> getTodaySlots(DateTime date) =>
      getSlotsInRange(date, date);

  Future<List<TodaySlot>> getWeekSlots(DateTime date) =>
      getSlotsInRange(startOfWeek(date), endOfWeek(date));

  Future<List<TodaySlot>> getSlotsInRange(DateTime from, DateTime to) =>
      _guard(() async {
        final uid = _teacherUid();
        final fromDate = _isoDate(from);
        final toDate = _isoDate(to);
        final snapshot = await _firestore
            .collection('courseClasses')
            .where('ownerUid', isEqualTo: uid)
            .get();
        final slots = <TodaySlot>[];

        for (final document in snapshot.docs) {
          final data = document.data();
          final schedule = data['schedule'];
          if (schedule is! List) continue;
          for (final rawItem in schedule) {
            if (rawItem is! Map) continue;
            final item = Map<String, dynamic>.from(rawItem);
            final itemDate = item['date'];
            if (itemDate is! String ||
                itemDate.compareTo(fromDate) < 0 ||
                itemDate.compareTo(toDate) > 0 ||
                item['number'] is! num) {
              continue;
            }
            slots.add(
              TodaySlot(
                courseClassId: document.id,
                subject: data['subject'] as String,
                classCode: data['classCode'] as String,
                slot: (item['number'] as num).toInt(),
                slotCount: (data['slotCount'] as num?)?.toInt() ?? 0,
                daySlot:
                    (item['daySlot'] as num?)?.toInt() ??
                    (data['daySlot'] as num?)?.toInt(),
                date: itemDate,
              ),
            );
          }
        }
        slots.sort((left, right) {
          final date = left.date.compareTo(right.date);
          if (date != 0) return date;
          final subject = left.subject.compareTo(right.subject);
          if (subject != 0) return subject;
          final classCode = left.classCode.compareTo(right.classCode);
          return classCode != 0 ? classCode : left.slot.compareTo(right.slot);
        });
        return slots;
      });

  Future<AttendanceSession?> getActiveAttendance() => _guard(() async {
    final uid = _teacherUid();
    final activeReference = _firestore
        .collection('activeAttendanceSessions')
        .doc(uid);
    final active = await activeReference.get();
    final sessionId = active.data()?['sessionId'];
    if (!active.exists || sessionId is! String) return null;

    final session = await _firestore
        .collection('attendanceSessions')
        .doc(sessionId)
        .get();
    final data = session.data();
    if (!session.exists || data == null || data['status'] != 'active') {
      await activeReference.delete();
      return null;
    }
    var slotCount = 0;
    int? daySlot;
    final courseClassId = data['courseClassId'];
    final courseSlot = data['slot'];
    if (courseClassId is String && courseSlot is num) {
      final course = await _firestore
          .collection('courseClasses')
          .doc(courseClassId)
          .get();
      final courseData = course.data();
      slotCount = (courseData?['slotCount'] as num?)?.toInt() ?? 0;
      final scheduled = _scheduledSlot(
        courseData?['schedule'],
        courseSlot.toInt(),
      );
      daySlot = (scheduled?['daySlot'] as num?)?.toInt();
    }
    return AttendanceSession.fromMap({
      ...data,
      'sessionId': session.id,
      'slotCount': slotCount,
      'daySlot': ?daySlot,
    });
  });

  Future<AttendanceSession> startAttendance({
    required TodaySlot slot,
    required int rotationSeconds,
    required int validitySeconds,
  }) => _guard(() async {
    final uid = _teacherUid();
    if (rotationSeconds < 1 || rotationSeconds > 60) {
      throw const AttendanceApiException(
        'Chu kỳ đổi QR phải từ 1 đến 60 giây.',
      );
    }
    if (validitySeconds < 2 || validitySeconds > 120) {
      throw const AttendanceApiException('Thời hạn QR phải từ 2 đến 120 giây.');
    }
    if (validitySeconds < rotationSeconds) {
      throw const AttendanceApiException(
        'Thời hạn QR phải lớn hơn hoặc bằng chu kỳ đổi QR.',
      );
    }

    final courseReference = _firestore
        .collection('courseClasses')
        .doc(slot.courseClassId);
    final activeReference = _firestore
        .collection('activeAttendanceSessions')
        .doc(uid);
    final sessionReference = _firestore.collection('attendanceSessions').doc();

    final sessionData = await _firestore.runTransaction((transaction) async {
      final course = await transaction.get(courseReference);
      final active = await transaction.get(activeReference);
      final courseData = course.data();
      if (!course.exists ||
          courseData == null ||
          courseData['ownerUid'] != uid) {
        throw const AttendanceApiException('Không tìm thấy môn–lớp.');
      }
      if (active.exists) {
        throw const AttendanceApiException(
          'Bạn đang có một phiên điểm danh khác. Hãy ngừng phiên đó trước.',
        );
      }

      final scheduled = _scheduledSlot(courseData['schedule'], slot.slot);
      if (scheduled == null) {
        throw const AttendanceApiException('Slot không tồn tại.');
      }
      final today = _isoDate(DateTime.now());
      if (scheduled['date'] != today || slot.date != today) {
        throw const AttendanceApiException(
          'Chỉ có thể mở slot được xếp lịch hôm nay.',
        );
      }

      final data = <String, dynamic>{
        'ownerUid': uid,
        'courseClassId': slot.courseClassId,
        'subject': courseData['subject'],
        'classCode': courseData['classCode'],
        'slot': slot.slot,
        'slotKey': slot.slot.toString(),
        'date': today,
        'rotationSeconds': rotationSeconds,
        'validitySeconds': validitySeconds,
        'status': 'active',
        'startedAt': FieldValue.serverTimestamp(),
      };
      transaction.set(sessionReference, data);
      transaction.set(activeReference, {
        'ownerUid': uid,
        'sessionId': sessionReference.id,
        'createdAt': FieldValue.serverTimestamp(),
      });
      return data;
    });

    await _materializeAlwaysExcused(
      sessionId: sessionReference.id,
      courseClassId: slot.courseClassId,
      subject: sessionData['subject'] as String,
      classCode: sessionData['classCode'] as String,
      slot: slot.slot,
      date: sessionData['date'] as String,
      ownerUid: uid,
    );

    return AttendanceSession.fromMap({
      ...sessionData,
      'sessionId': sessionReference.id,
      'slotCount': slot.slotCount,
      if (slot.daySlot != null) 'daySlot': slot.daySlot,
    });
  });

  Future<void> setAttendancePolicy({
    required String courseClassId,
    required String studentId,
    required AttendancePolicy policy,
  }) => _guard(() async {
    final uid = _teacherUid();
    final courseReference = _firestore
        .collection('courseClasses')
        .doc(courseClassId);
    final studentReference = courseReference
        .collection('students')
        .doc(studentId);
    await _firestore.runTransaction((transaction) async {
      final course = await transaction.get(courseReference);
      final student = await transaction.get(studentReference);
      if (!course.exists ||
          course.data()?['ownerUid'] != uid ||
          !student.exists) {
        throw const AttendanceApiException(
          'Không tìm thấy sinh viên trong lớp.',
        );
      }
      transaction.update(studentReference, {
        'attendancePolicy': policy == AttendancePolicy.alwaysExcused
            ? 'alwaysExcused'
            : 'normal',
        'updatedAt': FieldValue.serverTimestamp(),
        'updatedBy': uid,
      });
    });
  });

  Future<void> adjustAttendance({
    required String courseClassId,
    required int slot,
    required String studentId,
    required AttendanceStatus status,
    required String reason,
  }) => _guard(() async {
    if (status == AttendanceStatus.notYetOpen) {
      throw const AttendanceApiException('Không thể ghi trạng thái chưa mở.');
    }
    final normalizedReason = reason.trim();
    if (normalizedReason.length < 3) {
      throw const AttendanceApiException('Lý do phải có ít nhất 3 ký tự.');
    }
    final uid = _teacherUid();
    final courseReference = _firestore
        .collection('courseClasses')
        .doc(courseClassId);
    final studentReference = courseReference
        .collection('students')
        .doc(studentId);
    final sessions = await _firestore
        .collection('attendanceSessions')
        .where('ownerUid', isEqualTo: uid)
        .get();
    final matchingSessions = sessions.docs.where((document) {
      final data = document.data();
      return data['courseClassId'] == courseClassId && data['slot'] == slot;
    }).toList();
    if (matchingSessions.isEmpty) {
      throw const AttendanceApiException(
        'Chỉ có thể điều chỉnh sau khi slot đã được mở.',
      );
    }
    matchingSessions.sort((left, right) {
      final leftTime = left.data()['startedAt'] as Timestamp?;
      final rightTime = right.data()['startedAt'] as Timestamp?;
      return (rightTime?.millisecondsSinceEpoch ?? 0).compareTo(
        leftTime?.millisecondsSinceEpoch ?? 0,
      );
    });
    final session = matchingSessions.first;
    final sessionData = session.data();
    final recordReference = _firestore
        .collection('attendance')
        .doc(courseClassId)
        .collection('slots')
        .doc('$slot')
        .collection('records')
        .doc(studentId);
    final auditReference = recordReference.collection('audit').doc();

    await _firestore.runTransaction((transaction) async {
      final course = await transaction.get(courseReference);
      final student = await transaction.get(studentReference);
      final existing = await transaction.get(recordReference);
      final courseData = course.data();
      final studentData = student.data();
      if (!course.exists ||
          courseData?['ownerUid'] != uid ||
          !student.exists ||
          studentData == null) {
        throw const AttendanceApiException(
          'Không tìm thấy sinh viên trong lớp.',
        );
      }
      final beforeData = existing.data();
      final beforeStatus =
          beforeData?['attendanceStatus'] as String? ?? 'absent';
      final afterStatus = _statusValue(status);
      final record = <String, dynamic>{
        'ownerUid': uid,
        'studentId': studentId,
        'email': studentData['email'],
        'emailNormalized': studentData['emailNormalized'],
        'studentCode': studentData['studentCode'],
        'fullName': studentData['fullName'],
        'sessionId': session.id,
        'courseClassId': courseClassId,
        'subject': courseData?['subject'],
        'classCode': courseData?['classCode'],
        'slot': slot,
        'slotKey': '$slot',
        'date': sessionData['date'],
        'attendanceStatus': afterStatus,
        'recordSource': 'teacher',
        'reason': normalizedReason,
        'updatedAt': FieldValue.serverTimestamp(),
        'updatedBy': uid,
        'syncStatus': 'pending',
        if (status == AttendanceStatus.present)
          'checkedInAt':
              beforeData?['checkedInAt'] ?? FieldValue.serverTimestamp(),
        'createdAt': beforeData?['createdAt'] ?? FieldValue.serverTimestamp(),
      };
      transaction.set(recordReference, record);
      transaction.set(auditReference, {
        'before': {
          'status': beforeStatus,
          'source': beforeData?['recordSource'] ?? 'implicit',
          'reason': beforeData?['reason'],
        },
        'after': {
          'status': afterStatus,
          'source': 'teacher',
          'reason': normalizedReason,
        },
        'reason': normalizedReason,
        'changedAt': FieldValue.serverTimestamp(),
        'changedBy': uid,
      });
    });

    if (!_sheets.isConfigured) {
      throw const AttendanceApiException(
        'Đã lưu trạng thái trên hệ thống nhưng chưa thể cập nhật Google Sheets '
        'vì Apps Script chưa được cấu hình.',
      );
    }
    final updated = await recordReference.get();
    final syncError = await _syncDocument(updated);
    if (syncError != null) {
      throw AttendanceApiException(
        'Đã lưu trạng thái trên hệ thống nhưng chưa thể cập nhật Google Sheets: '
        '$syncError. Bản ghi đã được giữ trong hàng đợi để thử lại.',
      );
    }
  });

  Future<void> adjustAttendanceBulk({
    required String courseClassId,
    required int slot,
    required Iterable<String> studentIds,
    required AttendanceStatus status,
    required String reason,
  }) async {
    for (final studentId in studentIds) {
      await adjustAttendance(
        courseClassId: courseClassId,
        slot: slot,
        studentId: studentId,
        status: status,
        reason: reason,
      );
    }
  }

  Future<IssuedQr> issueQr(String sessionId) => _guard(() async {
    final uid = _teacherUid();
    final sessionReference = _firestore
        .collection('attendanceSessions')
        .doc(sessionId);
    final token = _newToken();
    final tokenReference = _firestore.collection('qrTokens').doc(token);

    await _firestore.runTransaction((transaction) async {
      final session = await transaction.get(sessionReference);
      final data = session.data();
      if (!session.exists || data == null || data['ownerUid'] != uid) {
        throw const AttendanceApiException('Không tìm thấy phiên điểm danh.');
      }
      if (data['status'] != 'active') {
        throw const AttendanceApiException('Phiên điểm danh đã kết thúc.');
      }
      transaction.set(tokenReference, {
        'ownerUid': uid,
        'sessionId': sessionId,
        'issuedAt': FieldValue.serverTimestamp(),
        'validitySeconds': data['validitySeconds'],
      });
    });

    final created = await tokenReference.get(
      const GetOptions(source: Source.server),
    );
    final issuedAt = created.data()?['issuedAt'];
    final validitySeconds = created.data()?['validitySeconds'];
    if (issuedAt is! Timestamp || validitySeconds is! num) {
      throw const AttendanceApiException(
        'Không đọc được thời hạn QR từ máy chủ.',
      );
    }

    final query = Uri.parse('${DesktopFirebaseOptions.publicWebUrl}/check-in')
        .replace(queryParameters: {'t': token});
    return IssuedQr(
      url: query.toString(),
      expiresAt: issuedAt.toDate().add(
        Duration(seconds: validitySeconds.toInt()),
      ),
    );
  });

  Future<void> stopAttendance(String sessionId) => _guard(() async {
    final uid = _teacherUid();
    final sessionReference = _firestore
        .collection('attendanceSessions')
        .doc(sessionId);
    final activeReference = _firestore
        .collection('activeAttendanceSessions')
        .doc(uid);

    final sheetTarget = await _firestore.runTransaction((transaction) async {
      final session = await transaction.get(sessionReference);
      final active = await transaction.get(activeReference);
      final data = session.data();
      if (!session.exists || data == null || data['ownerUid'] != uid) {
        throw const AttendanceApiException('Không tìm thấy phiên điểm danh.');
      }
      if (data['status'] == 'active') {
        transaction.update(sessionReference, {
          'status': 'stopped',
          'stoppedAt': FieldValue.serverTimestamp(),
        });
      }
      if (active.data()?['sessionId'] == sessionId) {
        transaction.delete(activeReference);
      }
      return (
        subject: data['subject'] as String,
        classCode: data['classCode'] as String,
      );
    });

    await _deleteSessionTokens(uid: uid, sessionId: sessionId);
    try {
      await syncPendingCheckIns(sessionId: sessionId);
    } on Object {
      // The session is already stopped. A temporary sync failure must not make
      // the UI report that stopping the session itself failed.
    }
    if (_sheets.isConfigured) {
      try {
        await _sheets.sort(
          subject: sheetTarget.subject,
          classCode: sheetTarget.classCode,
        );
      } on Object {
        // The Firestore attendance remains authoritative and can be synced later.
      }
    }
  });

  Stream<int> watchAttendanceCount(String sessionId) {
    final uid = _teacherUid();
    return _firestore
        .collectionGroup('records')
        .where('ownerUid', isEqualTo: uid)
        .where('sessionId', isEqualTo: sessionId)
        .snapshots()
        .map((snapshot) {
          if (_sheets.isConfigured) {
            unawaited(_syncDocuments(snapshot.docs));
          }
          return snapshot.docs
              .where(
                (document) => document.data()['attendanceStatus'] == 'present',
              )
              .length;
        });
  }

  Stream<List<CheckInRecord>> watchSessionCheckIns(AttendanceSession session) {
    final uid = _teacherUid();
    return _firestore
        .collection('attendance')
        .doc(session.courseClassId)
        .collection('slots')
        .doc('${session.slot}')
        .collection('records')
        .where('ownerUid', isEqualTo: uid)
        .snapshots()
        .map((snapshot) {
          if (_sheets.isConfigured) unawaited(_syncDocuments(snapshot.docs));
          // A student has one immutable check-in document per course slot.
          // When the teacher reopens the same slot, the web client correctly
          // reports a duplicate instead of creating a second document. Show
          // every record in this slot so those earlier valid check-ins do not
          // disappear merely because the active session ID changed.
          final records = snapshot.docs.map((document) {
            final data = document.data();
            return CheckInRecord(
              id: document.id,
              studentId: data['studentId'] as String? ?? '',
              email: data['email'] as String? ?? '',
              studentCode: data['studentCode'] as String? ?? '',
              fullName: data['fullName'] as String? ?? '',
              syncStatus: data['syncStatus'] as String? ?? 'pending',
              syncError: data['syncError'] as String?,
              source: data['recordSource'] as String? ?? 'qr',
              attendanceStatus:
                  data['attendanceStatus'] as String? ?? 'present',
              checkedInAt: (data['checkedInAt'] as Timestamp?)?.toDate(),
            );
          }).toList();
          records.sort(
            (left, right) => (right.checkedInAt ?? DateTime(0)).compareTo(
              left.checkedInAt ?? DateTime(0),
            ),
          );
          return records;
        });
  }

  Future<void> syncPendingCheckIns({String? sessionId}) => _guard(() async {
    if (!_sheets.isConfigured) return;
    final uid = _teacherUid();
    Query<Map<String, dynamic>> recordQuery = _firestore
        .collectionGroup('records')
        .where('ownerUid', isEqualTo: uid)
        .where('syncStatus', whereIn: ['pending', 'error']);
    Query<Map<String, dynamic>> legacyQuery = _firestore
        .collectionGroup('checkIns')
        .where('ownerUid', isEqualTo: uid)
        .where('syncStatus', whereIn: ['pending', 'error']);
    if (sessionId != null) {
      recordQuery = recordQuery.where('sessionId', isEqualTo: sessionId);
      legacyQuery = legacyQuery.where('sessionId', isEqualTo: sessionId);
    }
    final snapshots = await Future.wait([
      recordQuery.limit(100).get(),
      legacyQuery.limit(100).get(),
    ]);
    await _syncDocuments(
      [...snapshots[0].docs, ...snapshots[1].docs],
      retryErrors: true,
      reportErrors: true,
    );
  });

  Future<void> _syncDocuments(
    Iterable<QueryDocumentSnapshot<Map<String, dynamic>>> documents, {
    bool retryErrors = false,
    bool reportErrors = false,
  }) async {
    final errors = <String>[];
    for (final document in documents) {
      final status = document.data()['syncStatus'];
      if (status == 'pending' || (retryErrors && status == 'error')) {
        final error = await _syncDocument(document);
        if (error != null) errors.add(error);
      }
    }
    if (reportErrors && errors.isNotEmpty) {
      throw SheetSyncException(
        'Không thể đồng bộ ${errors.length} bản ghi. ${errors.first}',
      );
    }
  }

  Future<String?> _syncDocument(
    DocumentSnapshot<Map<String, dynamic>> document,
  ) {
    final path = document.reference.path;
    final active = _syncingRecords[path];
    if (active != null) return active;
    late final Future<String?> operation;
    operation = _performSyncDocument(document).whenComplete(() {
      if (identical(_syncingRecords[path], operation)) {
        _syncingRecords.remove(path);
      }
    });
    _syncingRecords[path] = operation;
    return operation;
  }

  Future<String?> _performSyncDocument(
    DocumentSnapshot<Map<String, dynamic>> document,
  ) async {
    try {
      final data = document.data();
      if (data == null) return null;
      final checkedInAt = data['checkedInAt'];
      await _sheets.upsert(
        recordId: document.reference.path.replaceAll('/', '|'),
        subject: data['subject'] as String,
        classCode: data['classCode'] as String,
        slot: (data['slot'] as num).toInt(),
        date: data['date'] as String,
        email: data['email'] as String,
        sessionId: data['sessionId'] as String? ?? '',
        checkedInAt: checkedInAt is Timestamp ? checkedInAt.toDate() : null,
        attendanceStatus: data['attendanceStatus'] as String? ?? 'present',
        recordSource: data['recordSource'] as String? ?? 'qr',
        reason: data['reason'] as String?,
      );
      await document.reference.update({
        'syncStatus': 'synced',
        'syncedAt': FieldValue.serverTimestamp(),
        'syncError': FieldValue.delete(),
      });
      return null;
    } on Object catch (error) {
      final message = error.toString();
      try {
        await document.reference.update({
          'syncStatus': 'error',
          'syncError': message.length > 300
              ? message.substring(0, 300)
              : message,
        });
      } on Object {
        // A failed status update must not crash the live attendance screen.
      }
      return message;
    }
  }

  Future<void> _materializeAlwaysExcused({
    required String sessionId,
    required String courseClassId,
    required String subject,
    required String classCode,
    required int slot,
    required String date,
    required String ownerUid,
  }) async {
    final courseReference = _firestore
        .collection('courseClasses')
        .doc(courseClassId);
    final students = await courseReference
        .collection('students')
        .where('active', isEqualTo: true)
        .where('attendancePolicy', isEqualTo: 'alwaysExcused')
        .get();
    if (students.docs.isEmpty) return;
    final records = _firestore
        .collection('attendance')
        .doc(courseClassId)
        .collection('slots')
        .doc('$slot')
        .collection('records');
    final existing = await records.get();
    final existingIds = existing.docs.map((document) => document.id).toSet();
    final legacy = await _firestore
        .collection('attendance')
        .doc(courseClassId)
        .collection('slots')
        .doc('$slot')
        .collection('checkIns')
        .get();
    existingIds.addAll(
      legacy.docs
          .map((document) => document.data()['studentId'])
          .whereType<String>(),
    );
    final missingStudents = students.docs
        .where((student) => !existingIds.contains(student.id))
        .toList();
    for (var start = 0; start < missingStudents.length; start += 400) {
      final end = min(start + 400, missingStudents.length);
      final batch = _firestore.batch();
      for (final student in missingStudents.sublist(start, end)) {
        final data = student.data();
        batch.set(records.doc(student.id), {
          'ownerUid': ownerUid,
          'studentId': student.id,
          'email': data['email'],
          'emailNormalized': data['emailNormalized'],
          'studentCode': data['studentCode'],
          'fullName': data['fullName'],
          'sessionId': sessionId,
          'courseClassId': courseClassId,
          'subject': subject,
          'classCode': classCode,
          'slot': slot,
          'slotKey': '$slot',
          'date': date,
          'attendanceStatus': 'excused',
          'recordSource': 'policy',
          'reason': 'Miễn điểm danh toàn khóa',
          'createdAt': FieldValue.serverTimestamp(),
          'updatedAt': FieldValue.serverTimestamp(),
          'updatedBy': ownerUid,
          'syncStatus': 'pending',
        });
      }
      await batch.commit();
    }
  }

  String _statusValue(AttendanceStatus status) => switch (status) {
    AttendanceStatus.present => 'present',
    AttendanceStatus.absent => 'absent',
    AttendanceStatus.excused => 'excused',
    AttendanceStatus.notYetOpen => throw const AttendanceApiException(
      'Không thể lưu trạng thái chưa mở.',
    ),
  };

  Future<void> _deleteSessionTokens({
    required String uid,
    required String sessionId,
  }) async {
    try {
      while (true) {
        final snapshot = await _firestore
            .collection('qrTokens')
            .where('ownerUid', isEqualTo: uid)
            .where('sessionId', isEqualTo: sessionId)
            .limit(450)
            .get();
        if (snapshot.docs.isEmpty) break;
        final batch = _firestore.batch();
        for (final document in snapshot.docs) {
          batch.delete(document.reference);
        }
        await batch.commit();
        if (snapshot.docs.length < 450) break;
      }
    } on Object {
      // The stopped session already invalidates every QR even if cleanup fails.
    }
  }

  Map<String, dynamic>? _scheduledSlot(Object? schedule, int slot) {
    if (schedule is! List) return null;
    for (final item in schedule) {
      if (item is Map && item['number'] == slot) {
        return Map<String, dynamic>.from(item);
      }
    }
    return null;
  }

  String _teacherUid() {
    final user = _auth.currentUser;
    if (user == null) {
      throw const AttendanceApiException('Phiên đăng nhập đã hết hạn.');
    }
    return user.uid;
  }

  String _requiredCode(String value, String field) {
    final normalized = value.trim().toUpperCase();
    if (!RegExp(r'^[A-Z0-9_-]{2,20}$').hasMatch(normalized)) {
      throw AttendanceApiException(
        '$field chỉ gồm 2–20 ký tự A–Z, 0–9, gạch dưới hoặc gạch ngang.',
      );
    }
    return normalized;
  }

  void _validateDaySlot(int daySlot) {
    if (daySlot < 1 || daySlot > 7) {
      throw const AttendanceApiException('Slot trong ngày phải từ 1 đến 7.');
    }
  }

  String _newToken() {
    final bytes = List<int>.generate(32, (_) => _secureRandom.nextInt(256));
    return base64UrlEncode(bytes).replaceAll('=', '');
  }

  Future<T> _guard<T>(Future<T> Function() operation) async {
    try {
      return await operation();
    } on AttendanceApiException {
      rethrow;
    } on FirebaseException catch (error) {
      throw AttendanceApiException(_firebaseMessage(error));
    }
  }

  String _firebaseMessage(FirebaseException error) => switch (error.code) {
    'permission-denied' =>
      'Tài khoản chưa có quyền giảng viên hoặc thao tác không hợp lệ.',
    'unavailable' => 'Không thể kết nối Firebase. Hãy kiểm tra mạng.',
    'failed-precondition' =>
      'Firestore cần một index. Hãy deploy firestore.indexes.json.',
    _ => error.message ?? 'Yêu cầu Firebase thất bại (${error.code}).',
  };

  String _isoDate(DateTime value) =>
      '${value.year.toString().padLeft(4, '0')}-'
      '${value.month.toString().padLeft(2, '0')}-'
      '${value.day.toString().padLeft(2, '0')}';
}

class AttendanceApiException implements Exception {
  const AttendanceApiException(this.message);

  final String message;

  @override
  String toString() => message;
}
