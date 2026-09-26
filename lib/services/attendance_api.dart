import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:crypto/crypto.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import '../domain/models.dart';
import '../domain/class_overview.dart';
import '../domain/roster_import.dart';
import '../domain/schedule.dart';
import '../firebase_options.dart';
import 'apps_script_sheet_service.dart';

final _studentEmailPattern = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$');
final _studentCodePattern = RegExp(r'^[A-Z0-9_-]{3,20}$');

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
        academicTerm: data['academicTerm'] as String?,
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
        .where('courseClassId', isEqualTo: courseClassId)
        .get();
    final sessionsBySlot =
        <int, List<QueryDocumentSnapshot<Map<String, dynamic>>>>{};
    for (final session in sessionSnapshot.docs) {
      final data = session.data();
      if (data['slot'] is! num) {
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
      for (final item in schedule.where(
        (item) => sessionsBySlot.containsKey((item['number'] as num).toInt()),
      ))
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
    final uid = _teacherUid();
    final courseReference = _firestore
        .collection('courseClasses')
        .doc(courseClassId);
    final courseDocument = await courseReference.get();
    final course = courseDocument.data();
    if (course == null || course['ownerUid'] != uid) {
      throw const AttendanceApiException('Không tìm thấy môn–lớp.');
    }
    final studentDocument = await courseReference
        .collection('students')
        .doc(studentId)
        .get();
    final data = studentDocument.data();
    if (data == null) {
      throw const AttendanceApiException(
        'Không tìm thấy sinh viên trong danh sách lớp.',
      );
    }
    final student = CourseStudent(
      id: studentId,
      email: data['email'] as String? ?? '',
      studentCode: data['studentCode'] as String? ?? '',
      fullName: data['fullName'] as String? ?? '',
      active: data['active'] as bool? ?? true,
      attendancePolicy: data['attendancePolicy'] == 'alwaysExcused'
          ? AttendancePolicy.alwaysExcused
          : AttendancePolicy.normal,
    );
    final sessions = await _firestore
        .collection('attendanceSessions')
        .where('ownerUid', isEqualTo: uid)
        .where('courseClassId', isEqualTo: courseClassId)
        .get();
    final sessionsBySlot =
        <int, List<QueryDocumentSnapshot<Map<String, dynamic>>>>{};
    for (final session in sessions.docs) {
      final slot = (session.data()['slot'] as num?)?.toInt();
      if (slot != null) sessionsBySlot.putIfAbsent(slot, () => []).add(session);
    }
    final rawSchedule = course['schedule'];
    final schedule = rawSchedule is List
        ? rawSchedule.whereType<Map>().map(Map<String, dynamic>.from).toList()
        : <Map<String, dynamic>>[];
    schedule.sort((a, b) => (a['number'] as num).compareTo(b['number'] as num));
    final slots = <CourseSlotOverview>[];
    final entries = <String, AttendanceEntry>{};
    final openedNumbers = <int>[];
    for (final item in schedule) {
      final number = (item['number'] as num).toInt();
      final slotSessions = sessionsBySlot[number] ?? const [];
      final active = slotSessions.any(
        (session) => session.data()['status'] == 'active',
      );
      slots.add(
        CourseSlotOverview(
          number: number,
          date: item['date'] as String? ?? '',
          daySlot: (item['daySlot'] as num?)?.toInt(),
          state: active
              ? CourseSlotState.active
              : slotSessions.isEmpty
              ? CourseSlotState.notOpened
              : CourseSlotState.completed,
          sessionIds: slotSessions.map((session) => session.id).toList(),
        ),
      );
      if (slotSessions.isNotEmpty) openedNumbers.add(number);
    }
    for (var start = 0; start < openedNumbers.length; start += 4) {
      final chunk = openedNumbers.skip(start).take(4);
      await Future.wait(
        chunk.map((number) async {
          final slotReference = _firestore
              .collection('attendance')
              .doc(courseClassId)
              .collection('slots')
              .doc('$number');
          final canonical = await slotReference
              .collection('records')
              .doc(studentId)
              .get();
          Map<String, dynamic>? record = canonical.data();
          if (record == null) {
            final legacy = await slotReference
                .collection('checkIns')
                .where('ownerUid', isEqualTo: uid)
                .where('studentId', isEqualTo: studentId)
                .limit(1)
                .get();
            if (legacy.docs.isNotEmpty) record = legacy.docs.first.data();
          }
          if (record != null) {
            entries[attendanceEntryKey(studentId, number)] = AttendanceEntry(
              studentId: studentId,
              slot: number,
              status: switch (record['attendanceStatus']) {
                'excused' => AttendanceStatus.excused,
                'absent' => AttendanceStatus.absent,
                _ => AttendanceStatus.present,
              },
              source: record['recordSource'] as String? ?? 'qr',
              syncStatus: record['syncStatus'] as String? ?? 'pending',
            );
          }
        }),
      );
    }
    final overview = CourseOverview(
      courseClassId: courseClassId,
      subject: course['subject'] as String? ?? '',
      classCode: course['classCode'] as String? ?? '',
      students: [student],
      slots: slots,
      entries: entries,
    );
    return StudentAttendanceDetail(
      student: student,
      attendedSlots: overview.attendedCount(student),
      totalSlots: overview.slots.length,
      openedSlots: overview.openedSlotCount,
      excusedSlots: overview.excusedCount(student),
    );
  });

  Future<int> countRosterReplacementDeactivations({
    required String courseClassId,
    required List<RosterRow> rows,
  }) => _guard(() async {
    final uid = _teacherUid();
    final courseReference = _firestore
        .collection('courseClasses')
        .doc(courseClassId);
    final course = await courseReference.get();
    if (!course.exists || course.data()?['ownerUid'] != uid) {
      throw const AttendanceApiException('Không tìm thấy môn–lớp.');
    }
    final importedIds = {
      for (final row in rows.where((row) => row.isValid))
        sha256.convert(utf8.encode(row.emailNormalized)).toString(),
    };
    final active = await courseReference
        .collection('students')
        .where('active', isEqualTo: true)
        .get();
    return active.docs
        .where((student) => !importedIds.contains(student.id))
        .length;
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

    // Không thay đổi roster khi file còn dòng lỗi.
    final invalidRows = rows.where((row) => !row.isValid).toList();
    if (invalidRows.isNotEmpty) {
      final count = invalidRows.length;
      final firstError = invalidRows.first.errors.first;
      throw AttendanceApiException(
        'File có $count dòng lỗi. Dòng ${invalidRows.first.rowNumber}: $firstError. '
        'Hãy sửa file rồi import lại.',
      );
    }

    final validRows = rows.where((row) => row.isValid).toList();
    final students = courseReference.collection('students');
    final claims = courseReference.collection('studentCodeClaims');
    final existingSnapshot = await students.get();

    // Task 1.1: Preflight – MSSV đã thuộc email khác trong roster hiện tại → reject.
    // Build map: studentCodeNormalized -> studentId hiện tại trong Firestore.
    final existingCodeToStudentId = <String, String>{
      for (final doc in existingSnapshot.docs)
        if (doc.data()['studentCodeNormalized'] is String)
          doc.data()['studentCodeNormalized'] as String: doc.id,
    };
    for (final row in validRows) {
      final code = row.studentCodeNormalized;
      final newStudentId = sha256
          .convert(utf8.encode(row.emailNormalized))
          .toString();
      final existingStudentId = existingCodeToStudentId[code];
      if (existingStudentId != null && existingStudentId != newStudentId) {
        // Cùng MSSV nhưng email khác → từ chối toàn bộ import.
        throw AttendanceApiException(
          'MSSV ${row.studentCode} (dòng ${row.rowNumber}) đã thuộc một sinh viên khác trong lớp. '
          'Không thể import. Hãy kiểm tra lại file.',
        );
      }
    }

    if (validRows.isEmpty) {
      throw const AttendanceApiException(
        'File không có sinh viên hợp lệ để import.',
      );
    }
    final importedIds = {
      for (final row in validRows)
        sha256.convert(utf8.encode(row.emailNormalized)).toString(),
    };
    final deactivated = mode == RosterImportMode.replaceInactive
        ? existingSnapshot.docs
              .where((doc) => !importedIds.contains(doc.id))
              .toList()
        : <QueryDocumentSnapshot<Map<String, dynamic>>>[];
    // One Firestore transaction includes every roster change and the import receipt.
    // A failed transaction leaves the active roster intact. Larger imports need a
    // versioned roster design before they can be safely supported.
    final totalWrites = validRows.length * 3 + deactivated.length + 1;
    if (totalWrites > 500) {
      throw AttendanceApiException(
        'Import cần tối đa $totalWrites thao tác, vượt giới hạn an toàn 500 của một transaction. '
        'Hãy chia file thành các lần merge nhỏ hơn; chế độ thay thế cần file nhỏ hơn.',
      );
    }
    final receipt = courseReference.collection('imports').doc();
    await _firestore.runTransaction((transaction) async {
      final currentCourse = await transaction.get(courseReference);
      if (!currentCourse.exists || currentCourse.data()?['ownerUid'] != uid) {
        throw const AttendanceApiException('Không tìm thấy môn–lớp.');
      }
      final currentStudents =
          <String, DocumentSnapshot<Map<String, dynamic>>>{};
      for (final row in validRows) {
        final studentId = sha256
            .convert(utf8.encode(row.emailNormalized))
            .toString();
        currentStudents[studentId] = await transaction.get(
          students.doc(studentId),
        );
      }
      final currentDeactivated = <DocumentSnapshot<Map<String, dynamic>>>[];
      for (final document in deactivated) {
        currentDeactivated.add(await transaction.get(document.reference));
      }
      final claimCodes = <String>{
        for (final row in validRows) row.studentCodeNormalized,
      };
      for (final row in validRows) {
        final studentId = sha256
            .convert(utf8.encode(row.emailNormalized))
            .toString();
        final previous = currentStudents[studentId]?.data();
        final oldCode = normalizeStudentCode(
          previous?['studentCodeNormalized'] as String? ??
              previous?['studentCode'] as String? ??
              '',
        );
        if (oldCode.isNotEmpty && oldCode != row.studentCodeNormalized) {
          claimCodes.add(oldCode);
        }
      }
      final currentClaims = <String, DocumentSnapshot<Map<String, dynamic>>>{};
      for (final code in claimCodes) {
        currentClaims[code] = await transaction.get(claims.doc(code));
      }
      for (final row in validRows) {
        final studentId = sha256
            .convert(utf8.encode(row.emailNormalized))
            .toString();
        final claimOwner = currentClaims[row.studentCodeNormalized]
            ?.data()?['studentId'];
        if (claimOwner != null && claimOwner != studentId) {
          throw AttendanceApiException(
            'MSSV ${row.studentCode} (dòng ${row.rowNumber}) đã thuộc sinh viên khác.',
          );
        }
      }

      for (final document in currentDeactivated) {
        if (!document.exists || document.data()?['active'] != true) continue;
        transaction.update(document.reference, {
          'active': false,
          'updatedAt': FieldValue.serverTimestamp(),
          'updatedBy': uid,
        });
      }
      for (final row in validRows) {
        final studentId = sha256
            .convert(utf8.encode(row.emailNormalized))
            .toString();
        final previous = currentStudents[studentId]?.data();
        final code = row.studentCodeNormalized;
        final oldCode = normalizeStudentCode(
          previous?['studentCodeNormalized'] as String? ??
              previous?['studentCode'] as String? ??
              '',
        );
        transaction.set(students.doc(studentId), {
          'emailNormalized': row.emailNormalized,
          'email': row.email.trim(),
          'studentCode': row.studentCode.trim(),
          'studentCodeNormalized': code,
          'fullName': row.fullName.trim(),
          'attendancePolicy': previous?['attendancePolicy'] ?? 'normal',
          'active': true,
          'importedAt': FieldValue.serverTimestamp(),
          'importedBy': uid,
        }, SetOptions(merge: true));
        if (oldCode.isNotEmpty &&
            oldCode != code &&
            currentClaims[oldCode]?.data()?['studentId'] == studentId) {
          transaction.delete(claims.doc(oldCode));
        }
        if (currentClaims[code]?.exists != true) {
          transaction.set(claims.doc(code), {
            'studentId': studentId,
            'ownerUid': uid,
            'createdAt': FieldValue.serverTimestamp(),
          });
        }
      }
      transaction.set(receipt, {
        'fileName': fileName,
        'totalRows': rows.length,
        'validRows': validRows.length,
        'invalidRows': rows.length - validRows.length,
        'mode': mode.name,
        'createdAt': FieldValue.serverTimestamp(),
        'createdBy': uid,
      });
    });
    onProgress?.call(totalWrites, totalWrites);
    return RosterImportResult(
      totalRows: rows.length,
      validRows: validRows.length,
      invalidRows: rows.length - validRows.length,
    );
  });

  Future<void> addCourseStudent({
    required String courseClassId,
    required String email,
    required String studentCode,
    required String fullName,
  }) => _guard(() async {
    final uid = _teacherUid();
    final normalizedEmail = normalizeEmail(email);
    final normalizedCode = normalizeStudentCode(studentCode);
    final normalizedName = fullName.trim();
    _validateCourseStudentFields(
      email: normalizedEmail,
      studentCode: normalizedCode,
      fullName: normalizedName,
    );

    final courseReference = _firestore
        .collection('courseClasses')
        .doc(courseClassId);
    final studentId = sha256.convert(utf8.encode(normalizedEmail)).toString();
    final studentReference = courseReference
        .collection('students')
        .doc(studentId);
    final codeClaimReference = courseReference
        .collection('studentCodeClaims')
        .doc(normalizedCode);

    await _firestore.runTransaction((transaction) async {
      final course = await transaction.get(courseReference);
      final existingStudent = await transaction.get(studentReference);
      final codeClaim = await transaction.get(codeClaimReference);
      if (!course.exists || course.data()?['ownerUid'] != uid) {
        throw const AttendanceApiException('Không tìm thấy môn–lớp.');
      }
      if (existingStudent.exists) {
        throw const AttendanceApiException(
          'Email này đã có trong danh sách lớp. Hãy sửa hoặc khôi phục hồ sơ hiện có.',
        );
      }
      final claimedStudentId = codeClaim.data()?['studentId'] as String?;
      if (codeClaim.exists && claimedStudentId != studentId) {
        throw const AttendanceApiException(
          'Mã sinh viên đã được sử dụng trong lớp.',
        );
      }

      transaction.set(studentReference, {
        'email': email.trim(),
        'emailNormalized': normalizedEmail,
        'studentCode': normalizedCode,
        'studentCodeNormalized': normalizedCode,
        'fullName': normalizedName,
        'active': true,
        'attendancePolicy': 'normal',
        'importedBy': uid,
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
        'updatedBy': uid,
      });
      transaction.set(codeClaimReference, {
        'studentId': studentId,
        'ownerUid': uid,
        'createdAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    });
  });

  Future<void> updateCourseStudent({
    required String courseClassId,
    required String studentId,
    required String studentCode,
    required String fullName,
  }) => _guard(() async {
    final uid = _teacherUid();
    final normalizedCode = normalizeStudentCode(studentCode);
    final normalizedName = fullName.trim();
    if (!_studentCodePattern.hasMatch(normalizedCode)) {
      throw const AttendanceApiException(
        'Mã sinh viên cần có 3–20 ký tự A–Z, 0–9, _ hoặc -.',
      );
    }
    if (normalizedName.isEmpty || normalizedName.length > 120) {
      throw const AttendanceApiException(
        'Họ tên không được để trống và tối đa 120 ký tự.',
      );
    }

    final courseReference = _firestore
        .collection('courseClasses')
        .doc(courseClassId);
    final studentReference = courseReference
        .collection('students')
        .doc(studentId);
    final claims = courseReference.collection('studentCodeClaims');
    final newClaimReference = claims.doc(normalizedCode);

    await _firestore.runTransaction((transaction) async {
      final course = await transaction.get(courseReference);
      final student = await transaction.get(studentReference);
      if (!course.exists ||
          course.data()?['ownerUid'] != uid ||
          !student.exists ||
          student.data() == null) {
        throw const AttendanceApiException(
          'Không tìm thấy sinh viên trong lớp.',
        );
      }

      final studentData = student.data()!;
      final oldCode = normalizeStudentCode(
        studentData['studentCodeNormalized'] as String? ??
            studentData['studentCode'] as String? ??
            '',
      );
      final codeChanged = oldCode != normalizedCode;
      final oldClaimReference = oldCode.isEmpty || !codeChanged
          ? null
          : claims.doc(oldCode);
      final oldClaim = oldClaimReference != null
          ? await transaction.get(oldClaimReference)
          : null;
      final newClaim = await transaction.get(newClaimReference);
      final claimedStudentId = newClaim.data()?['studentId'] as String?;
      if (newClaim.exists && claimedStudentId != studentId) {
        throw const AttendanceApiException(
          'Mã sinh viên đã được sử dụng trong lớp.',
        );
      }

      transaction.update(studentReference, {
        'studentCode': normalizedCode,
        'studentCodeNormalized': normalizedCode,
        'fullName': normalizedName,
        'importedBy': studentData['importedBy'] ?? uid,
        'updatedAt': FieldValue.serverTimestamp(),
        'updatedBy': uid,
      });
      if (codeChanged) {
        if (oldClaim?.exists == true &&
            oldClaim?.data()?['studentId'] == studentId) {
          transaction.delete(oldClaimReference!);
        }
      }
      if (!newClaim.exists) {
        transaction.set(newClaimReference, {
          'studentId': studentId,
          'ownerUid': uid,
          'createdAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
      }
    });
  });

  Future<void> setCourseStudentActive({
    required String courseClassId,
    required String studentId,
    required bool active,
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
          !student.exists ||
          student.data() == null) {
        throw const AttendanceApiException(
          'Không tìm thấy sinh viên trong lớp.',
        );
      }
      transaction.update(studentReference, {
        'active': active,
        'importedBy': student.data()?['importedBy'] ?? uid,
        'updatedAt': FieldValue.serverTimestamp(),
        'updatedBy': uid,
      });
    });
  });

  Future<void> createCourseClass({
    required String subject,
    required String classCode,
    required String academicTerm,
    required DateTime startDate,
    required SchedulePreset preset,
    required int daySlot,
  }) => _guard(() async {
    final uid = _teacherUid();
    final normalizedSubject = _requiredCode(subject, 'Mã môn');
    final normalizedClass = _requiredCode(classCode, 'Mã lớp');
    final normalizedTerm = _requiredCode(academicTerm, 'Học kỳ');
    _validateDaySlot(daySlot);
    final schedule = generateSchedule(startDate: startDate, preset: preset);
    final reference = _firestore.collection('courseClasses').doc();
    final id = reference.id;
    final claimReference = _firestore
        .collection('courseClassClaims')
        .doc('${uid}_${normalizedTerm}_${normalizedSubject}_$normalizedClass');

    // Task 1.2: Sinh toàn bộ lock ID cho mỗi slot trong lịch.
    // Lock ID: {ownerUid}_{date}_{daySlot} để prevent concurrent creation
    // của hai lớp chiếm cùng khung giờ của cùng giảng viên.
    final lockIds = [
      for (final item in schedule) '${uid}_${_isoDate(item.date)}_$daySlot',
    ];
    final lockRefs = [
      for (final lockId in lockIds)
        _firestore.collection('teacherScheduleLocks').doc(lockId),
    ];

    // Firestore transaction limit: 500 reads + writes.
    // Với preset lớn nhất (20 slots): 20 lock reads + 1 course read + 20 lock writes + 1 course write = 42 ops.
    // Luôn trong giới hạn, nhưng validate phòng ngừa.
    if (lockRefs.length > 400) {
      throw const AttendanceApiException(
        'Lịch có quá nhiều slot. Hãy chọn preset ít slot hơn.',
      );
    }

    await _firestore.runTransaction((transaction) async {
      final claim = await transaction.get(claimReference);
      if (claim.exists) {
        throw const AttendanceApiException(
          'Môn–lớp này đã tồn tại trong học kỳ đã chọn.',
        );
      }

      // Đọc tất cả lock trong cùng transaction.
      final lockDocs = await Future.wait(
        lockRefs.map((ref) => transaction.get(ref)),
      );

      // Kiểm tra xung đột: lock tồn tại cho lớp khác.
      for (var i = 0; i < lockDocs.length; i++) {
        final lockDoc = lockDocs[i];
        if (lockDoc.exists) {
          final lockData = lockDoc.data()!;
          final existingCourseId = lockData['courseClassId'] as String?;
          if (existingCourseId != null && existingCourseId != id) {
            final date = lockData['date'] as String? ?? '?';
            final slot = lockData['daySlot'] as int? ?? 0;
            throw AttendanceApiException(
              'Khung giờ Slot $slot ngày $date đã bị chiếm bởi lớp $existingCourseId. '
              'Hãy chọn slot hoặc ngày bắt đầu khác.',
            );
          }
        }
      }

      // Tạo course document.
      transaction.set(reference, {
        'subject': normalizedSubject,
        'classCode': normalizedClass,
        'academicTerm': normalizedTerm,
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
      transaction.set(claimReference, {
        'ownerUid': uid,
        'academicTerm': normalizedTerm,
        'subject': normalizedSubject,
        'classCode': normalizedClass,
        'courseClassId': id,
        'createdAt': FieldValue.serverTimestamp(),
      });

      // Tạo tất cả locks atomically với course.
      for (var i = 0; i < lockRefs.length; i++) {
        final item = schedule[i];
        transaction.set(lockRefs[i], {
          'ownerUid': uid,
          'date': _isoDate(item.date),
          'daySlot': daySlot,
          'courseClassId': id,
          'subject': normalizedSubject,
          'classCode': normalizedClass,
          'slotNumber': item.number,
          'createdAt': FieldValue.serverTimestamp(),
        });
      }
    });
  });

  /// Chỉ dùng cho debug/test thủ công. Không được gọi tự động trong production.
  Future<void> createTestCourseClassNow() => _guard(() async {
    // Task 1.4: Guard bằng kDebugMode để không tự ghi data trong production.
    if (!kDebugMode) {
      throw const AttendanceApiException(
        'Chức năng tạo lớp demo chỉ khả dụng trong chế độ debug.',
      );
    }
    // Phần còn lại của method không thay đổi:
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

  Future<void> moveScheduledSlot({
    required String courseClassId,
    required int slotNumber,
    required DateTime targetDate,
    required int targetDaySlot,
  }) => _guard(() async {
    final uid = _teacherUid();
    _validateDaySlot(targetDaySlot);
    final normalizedTarget = DateTime(
      targetDate.year,
      targetDate.month,
      targetDate.day,
    );
    final targetDateKey = _isoDate(normalizedTarget);
    final todayKey = _isoDate(DateTime.now());
    if (targetDateKey.compareTo(todayKey) <= 0) {
      throw const AttendanceApiException(
        'Chỉ có thể chuyển slot sang ngày mai hoặc ngày trong tương lai.',
      );
    }
    if (normalizedTarget.weekday == DateTime.sunday) {
      throw const AttendanceApiException('Không thể xếp lịch vào Chủ nhật.');
    }

    final coursesReference = _firestore.collection('courseClasses');
    final courseReference = coursesReference.doc(courseClassId);

    // Check the stored schedules as well as the lock below. This catches old
    // courses that were created before schedule locks were introduced.
    final teacherCourses = await coursesReference
        .where('ownerUid', isEqualTo: uid)
        .get();
    for (final course in teacherCourses.docs) {
      final data = course.data();
      final rawSchedule = data['schedule'];
      if (rawSchedule is! List) continue;
      for (final rawSlot in rawSchedule) {
        if (rawSlot is! Map) continue;
        final scheduled = Map<String, dynamic>.from(rawSlot);
        if (course.id == courseClassId &&
            (scheduled['number'] as num?)?.toInt() == slotNumber) {
          continue;
        }
        final scheduledDaySlot =
            (scheduled['daySlot'] as num?)?.toInt() ??
            (data['daySlot'] as num?)?.toInt();
        if (scheduled['date'] == targetDateKey &&
            scheduledDaySlot == targetDaySlot) {
          final occupiedCourse =
              '${data['subject'] ?? course.id} ${data['classCode'] ?? ''}'
                  .trim();
          final occupiedSlot = (scheduled['number'] as num?)?.toInt();
          throw AttendanceApiException(
            'Ô này đã có $occupiedCourse'
            '${occupiedSlot == null ? '' : ' · buổi $occupiedSlot'}. '
            'Hãy chọn một ô trống.',
          );
        }
      }
    }

    final lockCollection = _firestore.collection('teacherScheduleLocks');
    await _firestore.runTransaction((transaction) async {
      final courseSnapshot = await transaction.get(courseReference);
      final courseData = courseSnapshot.data();
      if (!courseSnapshot.exists ||
          courseData == null ||
          courseData['ownerUid'] != uid) {
        throw const AttendanceApiException('Không tìm thấy môn–lớp.');
      }

      final rawSchedule = courseData['schedule'];
      if (rawSchedule is! List) {
        throw const AttendanceApiException('Lịch môn–lớp không hợp lệ.');
      }
      final schedule = rawSchedule
          .whereType<Map>()
          .map(Map<String, dynamic>.from)
          .toList();
      final sourceIndex = schedule.indexWhere(
        (item) => (item['number'] as num?)?.toInt() == slotNumber,
      );
      if (sourceIndex < 0) {
        throw const AttendanceApiException('Không tìm thấy slot cần chuyển.');
      }

      final source = schedule[sourceIndex];
      final sourceDate = source['date'] as String?;
      if (sourceDate == null) {
        throw const AttendanceApiException('Ngày của slot không hợp lệ.');
      }
      if (sourceDate.compareTo(todayKey) <= 0) {
        throw const AttendanceApiException(
          'Slot hôm nay hoặc đã qua không thể thay đổi lịch.',
        );
      }
      final sourceDaySlot =
          (source['daySlot'] as num?)?.toInt() ??
          (courseData['daySlot'] as num?)?.toInt();
      if (sourceDate == targetDateKey && sourceDaySlot == targetDaySlot) {
        return;
      }

      final targetLockReference = lockCollection.doc(
        '${uid}_${targetDateKey}_$targetDaySlot',
      );
      final sourceLockReference = sourceDaySlot == null
          ? null
          : lockCollection.doc('${uid}_${sourceDate}_$sourceDaySlot');
      final sourceLockSnapshot = sourceLockReference == null
          ? null
          : await transaction.get(sourceLockReference);
      final targetLockSnapshot = await transaction.get(targetLockReference);

      if (targetLockSnapshot.exists) {
        final targetLock = targetLockSnapshot.data()!;
        final isThisSlot =
            targetLock['courseClassId'] == courseClassId &&
            (targetLock['slotNumber'] as num?)?.toInt() == slotNumber;
        if (!isThisSlot) {
          throw const AttendanceApiException(
            'Ô lịch vừa được một slot khác chiếm. Hãy chọn ô trống.',
          );
        }
      }

      if (sourceLockSnapshot?.exists == true) {
        final sourceLock = sourceLockSnapshot!.data()!;
        final belongsToThisSlot =
            sourceLock['ownerUid'] == uid &&
            sourceLock['courseClassId'] == courseClassId &&
            (sourceLock['slotNumber'] as num?)?.toInt() == slotNumber;
        if (!belongsToThisSlot) {
          throw const AttendanceApiException(
            'Lịch nguồn đang bị khóa bởi một slot khác. Hãy làm mới lịch.',
          );
        }
      }

      schedule[sourceIndex] = {
        ...source,
        'date': targetDateKey,
        'daySlot': targetDaySlot,
      };
      transaction.update(courseReference, {
        'schedule': schedule,
        'updatedAt': FieldValue.serverTimestamp(),
        'updatedBy': uid,
      });

      if (sourceLockSnapshot?.exists == true) {
        transaction.delete(sourceLockReference!);
      }
      if (!targetLockSnapshot.exists) {
        transaction.set(targetLockReference, {
          'ownerUid': uid,
          'date': targetDateKey,
          'daySlot': targetDaySlot,
          'courseClassId': courseClassId,
          'subject': courseData['subject'],
          'classCode': courseData['classCode'],
          'slotNumber': slotNumber,
          'createdAt': FieldValue.serverTimestamp(),
        });
      }
    });
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
    final checkout = await _firestore
        .collection('attendanceCheckoutCodes')
        .doc(session.id)
        .get();
    final checkoutIssuedAt = checkout.data()?['issuedAt'];
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
      'checkoutCode': checkout.data()?['code'] as String? ?? '',
      'checkoutRotationSeconds':
          (checkout.data()?['rotationSeconds'] as num?)?.toInt() ?? 30,
      'checkoutCodeIssuedAt': checkoutIssuedAt is Timestamp
          ? checkoutIssuedAt.toDate().toIso8601String()
          : null,
      'slotCount': slotCount,
      'daySlot': ?daySlot,
    });
  });

  Future<AttendanceSession?> resumeActiveAttendance() => _guard(() async {
    final session = await getActiveAttendance();
    if (session == null) return null;
    await _materializeAlwaysExcused(
      sessionId: session.id,
      courseClassId: session.courseClassId,
      subject: session.subject,
      classCode: session.classCode,
      slot: session.slot,
      date: session.date,
      ownerUid: _teacherUid(),
    );
    return session;
  });

  Future<AttendanceSession> startAttendance({
    required TodaySlot slot,
    required int rotationSeconds,
    required int validitySeconds,
    required int checkoutRotationSeconds,
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
    if (checkoutRotationSeconds < 10 || checkoutRotationSeconds > 3600) {
      throw const AttendanceApiException(
        'Chu kỳ đổi checkout code phải từ 10 đến 3600 giây.',
      );
    }
    final initialCheckoutCode = _newCheckoutCode();

    final courseReference = _firestore
        .collection('courseClasses')
        .doc(slot.courseClassId);
    final activeReference = _firestore
        .collection('activeAttendanceSessions')
        .doc(uid);
    final sessionReference = _firestore.collection('attendanceSessions').doc();
    final checkoutCodeReference = _firestore
        .collection('attendanceCheckoutCodes')
        .doc(sessionReference.id);

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
      transaction.set(checkoutCodeReference, {
        'ownerUid': uid,
        'sessionId': sessionReference.id,
        'code': initialCheckoutCode,
        'rotationSeconds': checkoutRotationSeconds,
        'generation': 1,
        'issuedAt': FieldValue.serverTimestamp(),
      });
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
    final currentCheckoutCode = await rotateCheckoutCode(sessionReference.id);

    return AttendanceSession.fromMap({
      ...sessionData,
      'sessionId': sessionReference.id,
      'checkoutCode': currentCheckoutCode.code,
      'checkoutRotationSeconds': checkoutRotationSeconds,
      'checkoutCodeIssuedAt': currentCheckoutCode.issuedAt.toIso8601String(),
      'slotCount': slot.slotCount,
      if (slot.daySlot != null) 'daySlot': slot.daySlot,
    });
  });

  Future<RotatedCheckoutCode> rotateCheckoutCode(String sessionId) => _guard(
    () async {
      final uid = _teacherUid();
      final sessionReference = _firestore
          .collection('attendanceSessions')
          .doc(sessionId);
      final checkoutReference = _firestore
          .collection('attendanceCheckoutCodes')
          .doc(sessionId);
      late String nextCode;

      await _firestore.runTransaction((transaction) async {
        final session = await transaction.get(sessionReference);
        final checkout = await transaction.get(checkoutReference);
        final sessionData = session.data();
        final checkoutData = checkout.data();
        if (!session.exists ||
            sessionData == null ||
            sessionData['ownerUid'] != uid ||
            sessionData['status'] != 'active' ||
            !checkout.exists ||
            checkoutData == null ||
            checkoutData['ownerUid'] != uid ||
            checkoutData['sessionId'] != sessionId) {
          throw const AttendanceApiException(
            'Không thể đổi checkout code của phiên này.',
          );
        }

        final generation = (checkoutData['generation'] as num?)?.toInt() ?? 0;
        nextCode = _newCheckoutCode(excluding: checkoutData['code'] as String?);
        transaction.update(checkoutReference, {
          'code': nextCode,
          'generation': generation + 1,
          'issuedAt': FieldValue.serverTimestamp(),
        });
      });

      final updated = await checkoutReference.get(
        const GetOptions(source: Source.server),
      );
      final data = updated.data();
      final code = data?['code'];
      final issuedAt = data?['issuedAt'];
      if (code is! String || issuedAt is! Timestamp) {
        throw const AttendanceApiException(
          'Không đọc được checkout code mới từ Firebase.',
        );
      }
      return RotatedCheckoutCode(code: code, issuedAt: issuedAt.toDate());
    },
  );

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

  Future<AttendanceAdjustmentResult> adjustAttendance({
    required String courseClassId,
    required int slot,
    required String studentId,
    required AttendanceStatus status,
    required String reason,
    bool deferSheetSort = false,
  }) => _guard(() async {
    if (status == AttendanceStatus.notYetOpen ||
        status == AttendanceStatus.pending) {
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
        'revision': ((beforeData?['revision'] as num?)?.toInt() ?? 0) + 1,
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
      return const AttendanceAdjustmentResult(
        synced: false,
        syncError: 'Apps Script chưa được cấu hình.',
      );
    }
    try {
      final updated = await recordReference.get();
      final syncError = await _syncDocument(updated, deferSort: deferSheetSort);
      return AttendanceAdjustmentResult(
        synced: syncError == null,
        syncError: syncError,
      );
    } on Object catch (error) {
      return AttendanceAdjustmentResult(
        synced: false,
        syncError: error.toString(),
      );
    }
  });

  Future<BulkAttendanceResult> adjustAttendanceBulk({
    required String courseClassId,
    required int slot,
    required Iterable<String> studentIds,
    required AttendanceStatus status,
    required String reason,
  }) async {
    final failures = <String, String>{};
    final pendingSync = <String, String>{};
    var syncedCount = 0;
    final ids = studentIds.toList();

    // Giới hạn số transaction và request Apps Script đồng thời.
    for (var start = 0; start < ids.length; start += 4) {
      final end = min(start + 4, ids.length);
      final chunk = ids.sublist(start, end);
      await Future.wait(
        chunk.map((studentId) async {
          try {
            final result = await adjustAttendance(
              courseClassId: courseClassId,
              slot: slot,
              studentId: studentId,
              status: status,
              reason: reason,
              deferSheetSort: true,
            );
            if (result.synced) {
              syncedCount++;
            } else {
              pendingSync[studentId] = result.syncError ?? 'Chưa đồng bộ.';
            }
          } on AttendanceApiException catch (error) {
            failures[studentId] = error.message;
          } on Exception catch (error) {
            failures[studentId] = error.toString();
          }
        }),
      );
    }
    String? sortWarning;
    if (syncedCount > 0 && _sheets.isConfigured) {
      try {
        final course = await _firestore
            .collection('courseClasses')
            .doc(courseClassId)
            .get();
        final data = course.data();
        if (data != null) {
          await _sheets.sort(
            subject: data['subject'] as String,
            classCode: data['classCode'] as String,
            courseClassId: courseClassId,
          );
        }
      } on Object catch (error) {
        sortWarning = error.toString();
      }
    }
    return BulkAttendanceResult(
      syncedCount: syncedCount,
      pendingSync: pendingSync,
      failures: failures,
      sortWarning: sortWarning,
    );
  }

  Future<IssuedQr> issueQr(String sessionId) => _guard(() async {
    final uid = _teacherUid();
    final sessionReference = _firestore
        .collection('attendanceSessions')
        .doc(sessionId);
    final token = _newToken();
    final tokenReference = _firestore.collection('qrTokens').doc(token);

    // Task 1.3: Update currentQrGeneration atomically khi sinh token mới.
    // Generation là timestamp server dưới dạng int. Rules sẽ reject token
    // của generation cũ hơn currentQrGeneration.
    await _firestore.runTransaction((transaction) async {
      final session = await transaction.get(sessionReference);
      final data = session.data();
      if (!session.exists || data == null || data['ownerUid'] != uid) {
        throw const AttendanceApiException('Không tìm thấy phiên điểm danh.');
      }
      if (data['status'] != 'active') {
        throw const AttendanceApiException('Phiên điểm danh đã kết thúc.');
      }
      // Mỗi lần issue QR mới, increment generation để invalidate token cũ.
      final currentGen = (data['currentQrGeneration'] as num?)?.toInt() ?? 0;
      final newGen = currentGen + 1;
      transaction.update(sessionReference, {'currentQrGeneration': newGen});
      transaction.set(tokenReference, {
        'ownerUid': uid,
        'sessionId': sessionId,
        'issuedAt': FieldValue.serverTimestamp(),
        'validitySeconds': data['validitySeconds'],
        'qrGeneration': newGen,
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

  Future<bool> isAttendanceActive(String sessionId) => _guard(() async {
    final session = await _firestore
        .collection('attendanceSessions')
        .doc(sessionId)
        .get(const GetOptions(source: Source.server));
    final data = session.data();
    if (data == null || data['ownerUid'] != _teacherUid()) {
      throw const AttendanceApiException('Không tìm thấy phiên điểm danh.');
    }
    return data['status'] == 'active';
  });

  /// Returns warnings for follow-up tasks. The Firestore stop itself succeeded.
  Future<List<String>> stopAttendance(String sessionId) => _guard(() async {
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
        courseClassId: data['courseClassId'] as String,
        subject: data['subject'] as String,
        classCode: data['classCode'] as String,
      );
    });

    final warnings = <String>[];
    try {
      await _deleteSessionTokens(uid: uid, sessionId: sessionId);
    } on Object catch (error) {
      warnings.add('Không dọn được QR cũ: $error');
    }
    try {
      final sync = await syncPendingCheckIns(sessionId: sessionId);
      if (sync.notConfigured) {
        warnings.add('Google Sheets chưa được cấu hình.');
      } else if (sync.error > 0 || sync.pending > 0) {
        warnings.add(
          'Còn ${sync.error + sync.pending} bản ghi chưa đồng bộ Google Sheets.',
        );
      }
    } on Object catch (error) {
      warnings.add('Chưa đồng bộ xong Google Sheets: $error');
    }
    if (_sheets.isConfigured) {
      try {
        await _sheets.sort(
          subject: sheetTarget.subject,
          classCode: sheetTarget.classCode,
          courseClassId: sheetTarget.courseClassId,
        );
      } on Object catch (error) {
        warnings.add('Chưa sắp xếp được Google Sheets: $error');
      }
    }
    return warnings;
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

  Future<SheetSyncSummary> syncPendingCheckIns({
    String? sessionId,
    bool force = false,
  }) => _guard(() async {
    if (!_sheets.isConfigured) {
      return const SheetSyncSummary(notConfigured: true);
    }
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
    var synced = 0;
    var pending = 0;
    var errors = 0;
    for (final baseQuery in [recordQuery, legacyQuery]) {
      QueryDocumentSnapshot<Map<String, dynamic>>? cursor;
      while (true) {
        Query<Map<String, dynamic>> pageQuery = baseQuery
            .orderBy(FieldPath.documentId)
            .limit(100);
        if (cursor != null) pageQuery = pageQuery.startAfterDocument(cursor);
        final page = await pageQuery.get();
        if (page.docs.isEmpty) break;
        for (final document in page.docs) {
          final data = document.data();
          final retryAt = data['nextSyncAttemptAt'];
          if (!force &&
              data['syncStatus'] == 'error' &&
              retryAt is Timestamp &&
              retryAt.toDate().isAfter(DateTime.now())) {
            pending++;
            continue;
          }
          final error = await _syncDocument(document);
          if (error == null) {
            synced++;
          } else {
            errors++;
          }
        }
        cursor = page.docs.last;
        if (page.docs.length < 100) break;
      }
    }
    return SheetSyncSummary(synced: synced, pending: pending, error: errors);
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
    DocumentSnapshot<Map<String, dynamic>> document, {
    bool deferSort = false,
  }) {
    final path = document.reference.path;
    final active = _syncingRecords[path];
    if (active != null) return active;
    late final Future<String?> operation;
    operation = _performSyncDocument(document, deferSort: deferSort)
        .whenComplete(() {
          if (identical(_syncingRecords[path], operation)) {
            _syncingRecords.remove(path);
          }
        });
    _syncingRecords[path] = operation;
    return operation;
  }

  Future<String?> _performSyncDocument(
    DocumentSnapshot<Map<String, dynamic>> document, {
    bool deferSort = false,
  }) async {
    final reference = document.reference;
    DocumentSnapshot<Map<String, dynamic>> current;
    try {
      current = await reference.get(const GetOptions(source: Source.server));
    } on Object catch (error) {
      return error.toString();
    }
    while (true) {
      final data = current.data();
      if (data == null ||
          (data['syncStatus'] != 'pending' && data['syncStatus'] != 'error')) {
        return null;
      }
      final revision = (data['revision'] as num?)?.toInt() ?? 0;
      final checkedInAt = data['checkedInAt'];
      try {
        await _sheets.upsert(
          recordId: reference.path.replaceAll('/', '|'),
          revision: revision,
          subject: data['subject'] as String,
          classCode: data['classCode'] as String,
          courseClassId: data['courseClassId'] as String?,
          slot: (data['slot'] as num).toInt(),
          date: data['date'] as String,
          email: data['email'] as String,
          sessionId: data['sessionId'] as String? ?? '',
          checkedInAt: checkedInAt is Timestamp ? checkedInAt.toDate() : null,
          attendanceStatus: data['attendanceStatus'] as String? ?? 'present',
          recordSource: data['recordSource'] as String? ?? 'qr',
          reason: data['reason'] as String?,
          deferSort: deferSort,
        );
        final changed = await _firestore.runTransaction((transaction) async {
          final latest = await transaction.get(reference);
          final latestData = latest.data();
          if (latestData == null || latestData['syncStatus'] == 'synced') {
            return false;
          }
          if (((latestData['revision'] as num?)?.toInt() ?? 0) != revision) {
            return true;
          }
          transaction.update(reference, {
            if (reference.parent.id == 'records') 'revision': revision,
            'syncStatus': 'synced',
            'syncedAt': FieldValue.serverTimestamp(),
            'syncError': FieldValue.delete(),
            'syncAttempts': FieldValue.delete(),
            'nextSyncAttemptAt': FieldValue.delete(),
          });
          return false;
        });
        if (!changed) return null;
      } on Object catch (error) {
        final message = error.toString();
        try {
          final outcome = await _firestore.runTransaction((transaction) async {
            final latest = await transaction.get(reference);
            final latestData = latest.data();
            if (latestData == null || latestData['syncStatus'] == 'synced') {
              return 'done';
            }
            if (((latestData['revision'] as num?)?.toInt() ?? 0) != revision) {
              return 'changed';
            }
            final attempts =
                ((latestData['syncAttempts'] as num?)?.toInt() ?? 0) + 1;
            final backoffSeconds =
                5 * (1 << (attempts > 10 ? 10 : attempts - 1));
            transaction.update(reference, {
              if (reference.parent.id == 'records') 'revision': revision,
              'syncStatus': 'error',
              'syncError': message.length > 300
                  ? message.substring(0, 300)
                  : message,
              'syncAttempts': attempts,
              'nextSyncAttemptAt': Timestamp.fromDate(
                DateTime.now().add(
                  Duration(
                    seconds: backoffSeconds > 3600 ? 3600 : backoffSeconds,
                  ),
                ),
              ),
            });
            return 'failed';
          });
          if (outcome == 'done') return null;
          if (outcome == 'failed') return message;
        } on Object {
          // A failed status update must not crash the live attendance screen.
          return message;
        }
      }
      try {
        current = await reference.get(const GetOptions(source: Source.server));
      } on Object catch (error) {
        return error.toString();
      }
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
    for (var start = 0; start < missingStudents.length; start += 20) {
      final end = min(start + 20, missingStudents.length);
      await Future.wait(
        missingStudents.sublist(start, end).map((student) async {
          final reference = records.doc(student.id);
          await _firestore.runTransaction((transaction) async {
            final current = await transaction.get(reference);
            if (current.exists) return;
            final data = student.data();
            transaction.set(reference, {
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
              'revision': 1,
            });
          });
        }),
      );
    }
  }

  String _statusValue(AttendanceStatus status) => switch (status) {
    AttendanceStatus.present => 'present',
    AttendanceStatus.absent => 'absent',
    AttendanceStatus.excused => 'excused',
    AttendanceStatus.notYetOpen => throw const AttendanceApiException(
      'Không thể lưu trạng thái chưa mở.',
    ),
    AttendanceStatus.pending => throw const AttendanceApiException(
      'Không thể lưu trạng thái chưa điểm danh.',
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

  void _validateCourseStudentFields({
    required String email,
    required String studentCode,
    required String fullName,
  }) {
    if (!_studentEmailPattern.hasMatch(email)) {
      throw const AttendanceApiException('Email sinh viên không hợp lệ.');
    }
    if (!_studentCodePattern.hasMatch(studentCode)) {
      throw const AttendanceApiException(
        'Mã sinh viên cần có 3–20 ký tự A–Z, 0–9, _ hoặc -.',
      );
    }
    if (fullName.isEmpty || fullName.length > 120) {
      throw const AttendanceApiException(
        'Họ tên không được để trống và tối đa 120 ký tự.',
      );
    }
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

  String _newCheckoutCode({String? excluding}) {
    const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    String code;
    do {
      code = List.generate(
        5,
        (_) => alphabet[_secureRandom.nextInt(alphabet.length)],
      ).join();
    } while (code == excluding);
    return code;
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

class AttendanceAdjustmentResult {
  const AttendanceAdjustmentResult({required this.synced, this.syncError});

  final bool synced;
  final String? syncError;
}

class SheetSyncSummary {
  const SheetSyncSummary({
    this.synced = 0,
    this.pending = 0,
    this.error = 0,
    this.notConfigured = false,
  });

  final int synced;
  final int pending;
  final int error;
  final bool notConfigured;
}

class BulkAttendanceResult {
  const BulkAttendanceResult({
    required this.syncedCount,
    required this.pendingSync,
    required this.failures,
    this.sortWarning,
  });

  final int syncedCount;
  final Map<String, String> pendingSync;
  final Map<String, String> failures;
  final String? sortWarning;

  int get savedCount => syncedCount + pendingSync.length;
}

class AttendanceApiException implements Exception {
  const AttendanceApiException(this.message);

  final String message;

  @override
  String toString() => message;
}
