import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;

import '../domain/models.dart';
import '../domain/schedule.dart';
import '../firebase_options.dart';

class AttendanceApi {
  AttendanceApi({http.Client? client, FirebaseFirestore? firestore})
    : _client = client ?? http.Client(),
      _firestore = firestore ?? FirebaseFirestore.instance;

  static const _region = 'asia-southeast1';
  final http.Client _client;
  final FirebaseFirestore _firestore;

  Future<void> createCourseClass({
    required String subject,
    required String classCode,
    required DateTime startDate,
    required SchedulePreset preset,
  }) async {
    await _call('createCourseClass', {
      'subject': subject.trim().toUpperCase(),
      'classCode': classCode.trim().toUpperCase(),
      'startDate': _isoDate(startDate),
      'slotCount': preset.slotCount,
      'weekLabel': preset.weekLabel,
    });
  }

  Future<List<TodaySlot>> getTodaySlots(DateTime date) async {
    final data = await _call('getTodaySlots', {'date': _isoDate(date)});
    return (data['slots'] as List)
        .map(
          (value) => TodaySlot.fromMap(Map<String, dynamic>.from(value as Map)),
        )
        .toList();
  }

  Future<AttendanceSession?> getActiveAttendance() async {
    final data = await _call('getActiveAttendance');
    final session = data['session'];
    if (session == null) return null;
    return AttendanceSession.fromMap(Map<String, dynamic>.from(session as Map));
  }

  Future<AttendanceSession> startAttendance({
    required TodaySlot slot,
    required int rotationSeconds,
    required int validitySeconds,
  }) async {
    final data = await _call('startAttendance', {
      'courseClassId': slot.courseClassId,
      'slot': slot.slot,
      'rotationSeconds': rotationSeconds,
      'validitySeconds': validitySeconds,
    });
    return AttendanceSession.fromMap(data);
  }

  Future<IssuedQr> issueQr(String sessionId) async {
    final data = await _call('issueQrToken', {'sessionId': sessionId});
    return IssuedQr.fromMap(data);
  }

  Future<void> stopAttendance(String sessionId) async {
    await _call('stopAttendance', {'sessionId': sessionId});
  }

  Stream<int> watchAttendanceCount(String sessionId) => _firestore
      .collection('attendanceSessions')
      .doc(sessionId)
      .snapshots()
      .map(
        (snapshot) =>
            (snapshot.data()?['attendanceCount'] as num?)?.toInt() ?? 0,
      );

  /// Implements the Firebase callable HTTPS protocol directly. This keeps the
  /// desktop client cross-platform because the Flutter Functions plugin does
  /// not currently expose a Windows implementation.
  Future<Map<String, dynamic>> _call(
    String functionName, [
    Map<String, dynamic> data = const {},
  ]) async {
    final user = FirebaseAuth.instance.currentUser;
    final idToken = await user?.getIdToken();
    if (idToken == null) {
      throw const AttendanceApiException('Phiên đăng nhập đã hết hạn.');
    }

    final uri = Uri.parse(
      'https://$_region-${DesktopFirebaseOptions.projectId}'
      '.cloudfunctions.net/$functionName',
    );
    final response = await _client.post(
      uri,
      headers: {
        'Content-Type': 'application/json; charset=utf-8',
        'Authorization': 'Bearer $idToken',
      },
      body: jsonEncode({'data': data}),
    );

    Object? decoded;
    try {
      decoded = jsonDecode(response.body);
    } on FormatException {
      throw AttendanceApiException(
        'Backend trả về dữ liệu không hợp lệ (${response.statusCode}).',
      );
    }
    if (decoded is! Map) {
      throw const AttendanceApiException(
        'Backend trả về dữ liệu không hợp lệ.',
      );
    }

    final body = Map<String, dynamic>.from(decoded);
    if (response.statusCode < 200 ||
        response.statusCode >= 300 ||
        body['error'] != null) {
      final error = body['error'];
      final message = error is Map ? error['message'] : null;
      throw AttendanceApiException(
        message is String
            ? message
            : 'Yêu cầu thất bại (${response.statusCode}).',
      );
    }

    final result = body['data'] ?? body['result'];
    return result is Map
        ? Map<String, dynamic>.from(result)
        : <String, dynamic>{};
  }

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
