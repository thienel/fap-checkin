import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../domain/models.dart';
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
  final Set<String> _syncingRecords = {};

  bool get isSheetSyncConfigured => _sheets.isConfigured;

  Future<void> createCourseClass({
    required String subject,
    required String classCode,
    required DateTime startDate,
    required SchedulePreset preset,
  }) => _guard(() async {
    final uid = _teacherUid();
    final normalizedSubject = _requiredCode(subject, 'Mã môn');
    final normalizedClass = _requiredCode(classCode, 'Mã lớp');
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
            .map((item) => {'number': item.number, 'date': _isoDate(item.date)})
            .toList(),
        'ownerUid': uid,
        'createdAt': FieldValue.serverTimestamp(),
      });
    });
  });

  Future<List<TodaySlot>> getTodaySlots(DateTime date) => _guard(() async {
    final uid = _teacherUid();
    final targetDate = _isoDate(date);
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
        if (item['date'] != targetDate || item['number'] is! num) continue;
        slots.add(
          TodaySlot(
            courseClassId: document.id,
            subject: data['subject'] as String,
            classCode: data['classCode'] as String,
            slot: (item['number'] as num).toInt(),
            date: targetDate,
          ),
        );
      }
    }
    slots.sort((left, right) {
      final subject = left.subject.compareTo(right.subject);
      return subject != 0 ? subject : left.classCode.compareTo(right.classCode);
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
    return AttendanceSession.fromMap({...data, 'sessionId': session.id});
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

    return AttendanceSession.fromMap({
      ...sessionData,
      'sessionId': sessionReference.id,
    });
  });

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
        .collectionGroup('checkIns')
        .where('ownerUid', isEqualTo: uid)
        .where('sessionId', isEqualTo: sessionId)
        .snapshots()
        .map((snapshot) {
          if (_sheets.isConfigured) {
            unawaited(_syncDocuments(snapshot.docs));
          }
          return snapshot.size;
        });
  }

  Future<void> syncPendingCheckIns({String? sessionId}) => _guard(() async {
    if (!_sheets.isConfigured) return;
    final uid = _teacherUid();
    Query<Map<String, dynamic>> query = _firestore
        .collectionGroup('checkIns')
        .where('ownerUid', isEqualTo: uid)
        .where('syncStatus', whereIn: ['pending', 'error']);
    if (sessionId != null) {
      query = query.where('sessionId', isEqualTo: sessionId);
    }
    final snapshot = await query.limit(100).get();
    await _syncDocuments(snapshot.docs);
  });

  Future<void> _syncDocuments(
    Iterable<QueryDocumentSnapshot<Map<String, dynamic>>> documents,
  ) async {
    for (final document in documents) {
      final status = document.data()['syncStatus'];
      if (status == 'pending' || status == 'error') {
        await _syncDocument(document);
      }
    }
  }

  Future<void> _syncDocument(
    QueryDocumentSnapshot<Map<String, dynamic>> document,
  ) async {
    if (!_syncingRecords.add(document.reference.path)) return;
    try {
      final data = document.data();
      final checkedInAt = data['checkedInAt'];
      if (checkedInAt is! Timestamp) return;
      await _sheets.append(
        recordId: document.reference.path.replaceAll('/', '|'),
        subject: data['subject'] as String,
        classCode: data['classCode'] as String,
        slot: (data['slot'] as num).toInt(),
        date: data['date'] as String,
        email: data['email'] as String,
        sessionId: data['sessionId'] as String,
        checkedInAt: checkedInAt.toDate(),
      );
      await document.reference.update({
        'syncStatus': 'synced',
        'syncedAt': FieldValue.serverTimestamp(),
        'syncError': FieldValue.delete(),
      });
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
    } finally {
      _syncingRecords.remove(document.reference.path);
    }
  }

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
