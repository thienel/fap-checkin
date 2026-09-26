import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../firebase_options.dart';

class AppsScriptSheetService {
  AppsScriptSheetService({http.Client? client, String? url, String? secret})
    : _client = client ?? http.Client(),
      _url = url ?? DesktopFirebaseOptions.appsScriptUrl,
      _secret = secret ?? DesktopFirebaseOptions.appsScriptSecret;

  final http.Client _client;
  final String _url;
  final String _secret;
  bool _instanceSheetsSupported = false;

  bool get isConfigured => _url.isNotEmpty && _secret.isNotEmpty;

  Future<void> upsert({
    required String recordId,
    required int revision,
    required String subject,
    required String classCode,
    String? courseClassId,
    required int slot,
    required String date,
    required String email,
    required String sessionId,
    required DateTime? checkedInAt,
    required String attendanceStatus,
    required String recordSource,
    String? reason,
  }) async {
    await _requireInstanceSheets(courseClassId, subject, classCode);
    final payload = <String, Object>{
      'action': 'upsert',
      'recordId': recordId,
      'revision': revision,
      'subject': subject,
      'classCode': classCode,
      ...?(courseClassId == null ? null : {'courseClassId': courseClassId}),
      'slot': slot,
      'date': date,
      'email': email,
      'sessionId': sessionId,
      ...?(checkedInAt == null
          ? null
          : {'checkedInAt': checkedInAt.toUtc().toIso8601String()}),
      'attendanceStatus': attendanceStatus,
      'recordSource': recordSource,
      ...?(reason == null ? null : {'reason': reason}),
    };
    final result = await _post(payload);
    if (result['revision'] != revision) {
      throw const SheetSyncException(
        'Apps Script chưa xác nhận phiên bản bản ghi. Hãy deploy Code.gs mới.',
      );
    }
  }

  Future<void> sort({
    required String subject,
    required String classCode,
    String? courseClassId,
  }) async {
    await _requireInstanceSheets(courseClassId, subject, classCode);
    await _post({
      'action': 'sort',
      'subject': subject,
      'classCode': classCode,
      ...?(courseClassId == null ? null : {'courseClassId': courseClassId}),
    });
  }

  Future<void> _requireInstanceSheets(
    String? courseClassId,
    String subject,
    String classCode,
  ) async {
    if (courseClassId == null ||
        courseClassId == '${subject}_$classCode' ||
        _instanceSheetsSupported) {
      return;
    }
    try {
      final result = await _post({'action': 'capabilities'});
      if (result['instanceSheets'] == true) {
        _instanceSheetsSupported = true;
        return;
      }
    } on SheetSyncException catch (error) {
      if (!error.message.contains('Action không được hỗ trợ')) rethrow;
      // An older deployment rejects this action before any attendance row is written.
    }
    throw const SheetSyncException(
      'Apps Script chưa hỗ trợ tab riêng theo ID lớp. Hãy deploy Code.gs mới.',
    );
  }

  Future<Map<String, dynamic>> _post(Map<String, Object> payload) async {
    if (!isConfigured) {
      throw const SheetSyncException('Apps Script chưa được cấu hình.');
    }

    final endpoint = Uri.parse(_url);
    var response = await _client
        .post(
          endpoint,
          headers: const {'Content-Type': 'application/json; charset=utf-8'},
          body: jsonEncode({...payload, 'secret': _secret}),
        )
        .timeout(const Duration(seconds: 20));

    // Google Apps Script web apps answer POST with a 302 whose Location hosts
    // the actual JSON response. package:http intentionally does not follow a
    // POST redirect that changes the method to GET, so handle it explicitly.
    for (var redirects = 0; redirects < 5; redirects++) {
      if (response.statusCode != 301 &&
          response.statusCode != 302 &&
          response.statusCode != 303) {
        break;
      }
      final location = response.headers['location'];
      if (location == null || location.isEmpty) break;
      response = await _client
          .get(endpoint.resolve(location))
          .timeout(const Duration(seconds: 20));
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw SheetSyncException(
        'Apps Script trả về HTTP ${response.statusCode}.',
      );
    }

    Object? decoded;
    try {
      decoded = jsonDecode(response.body);
    } on FormatException {
      final body = response.body.toLowerCase();
      if (body.contains('dopost') &&
          (body.contains('không tìm thấy') || body.contains('not found'))) {
        throw const SheetSyncException(
          'Apps Script deployment chưa có hàm doPost. Hãy deploy Code.gs '
          'thành phiên bản Web app mới và cập nhật URL /exec.',
        );
      }
      if (body.contains('<html') || body.contains('<!doctype html')) {
        throw const SheetSyncException(
          'Apps Script trả về trang HTML thay vì JSON. Hãy kiểm tra Web app '
          'đã deploy bản mới, Execute as Me và cho phép Anyone truy cập.',
        );
      }
      throw const SheetSyncException(
        'Apps Script trả về dữ liệu không hợp lệ.',
      );
    }
    if (decoded is! Map || decoded['ok'] != true) {
      final message = decoded is Map ? decoded['error'] : null;
      throw SheetSyncException(
        message is String ? message : 'Không thể đồng bộ Google Sheets.',
      );
    }
    return Map<String, dynamic>.from(decoded);
  }
}

class SheetSyncException implements Exception {
  const SheetSyncException(this.message);

  final String message;

  @override
  String toString() => message;
}
