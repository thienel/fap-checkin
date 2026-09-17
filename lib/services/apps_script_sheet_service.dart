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

  bool get isConfigured => _url.isNotEmpty && _secret.isNotEmpty;

  Future<void> append({
    required String recordId,
    required String subject,
    required String classCode,
    required int slot,
    required String date,
    required String email,
    required String sessionId,
    required DateTime checkedInAt,
  }) async {
    await _post({
      'action': 'append',
      'recordId': recordId,
      'subject': subject,
      'classCode': classCode,
      'slot': slot,
      'date': date,
      'email': email,
      'sessionId': sessionId,
      'checkedInAt': checkedInAt.toUtc().toIso8601String(),
    });
  }

  Future<void> sort({
    required String subject,
    required String classCode,
  }) async {
    await _post({'action': 'sort', 'subject': subject, 'classCode': classCode});
  }

  Future<void> _post(Map<String, Object> payload) async {
    if (!isConfigured) return;

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
  }
}

class SheetSyncException implements Exception {
  const SheetSyncException(this.message);

  final String message;

  @override
  String toString() => message;
}
