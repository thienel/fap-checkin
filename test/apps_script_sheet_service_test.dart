import 'dart:convert';

import 'package:fap_check_attendance/services/apps_script_sheet_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('upsert sends canonical attendance status and source', () async {
    Map<String, dynamic>? payload;
    final client = MockClient((request) async {
      payload = jsonDecode(request.body) as Map<String, dynamic>;
      if (payload?['action'] == 'capabilities') {
        return http.Response('{"ok":true,"instanceSheets":true}', 200);
      }
      return http.Response('{"ok":true,"revision":1}', 200);
    });
    final service = AppsScriptSheetService(
      client: client,
      url: 'https://script.google.com/macros/s/deployment/exec',
      secret: 'test-secret',
    );

    await service.upsert(
      recordId: 'attendance|class|slots|1|records|student',
      revision: 1,
      subject: 'PRM393',
      classCode: 'SE1917',
      courseClassId: 'instance-a',
      slot: 1,
      date: '2026-09-20',
      email: 'student@fpt.edu.vn',
      sessionId: 'session-1',
      checkedInAt: null,
      attendanceStatus: 'excused',
      recordSource: 'teacher',
      reason: 'Có giấy xác nhận',
    );

    expect(payload?['action'], 'upsert');
    expect(payload?['revision'], 1);
    expect(payload?['attendanceStatus'], 'excused');
    expect(payload?['recordSource'], 'teacher');
    expect(payload?['courseClassId'], 'instance-a');
    expect(payload?['reason'], 'Có giấy xác nhận');
    expect(payload?.containsKey('checkedInAt'), isFalse);
  });

  test('old Apps Script rejects new instance before writing a row', () async {
    final actions = <String>[];
    final service = AppsScriptSheetService(
      client: MockClient((request) async {
        final payload = jsonDecode(request.body) as Map<String, dynamic>;
        actions.add(payload['action'] as String);
        return http.Response(
          '{"ok":false,"error":"Action không được hỗ trợ."}',
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
      url: 'https://script.google.com/macros/s/deployment/exec',
      secret: 'test-secret',
    );
    await expectLater(
      service.upsert(
        recordId: 'attendance|instance-a|slots|1|records|student',
        revision: 1,
        subject: 'PRM393',
        classCode: 'SE1917',
        courseClassId: 'instance-a',
        slot: 1,
        date: '2026-09-20',
        email: 'student@fpt.edu.vn',
        sessionId: 'session-1',
        checkedInAt: null,
        attendanceStatus: 'present',
        recordSource: 'qr',
      ),
      throwsA(isA<SheetSyncException>()),
    );
    expect(actions, ['capabilities']);
  });

  test('old Apps Script cannot acknowledge a revision', () async {
    final actions = <String>[];
    final client = MockClient((request) async {
      final payload = jsonDecode(request.body) as Map<String, dynamic>;
      actions.add(payload['action'] as String);
      return http.Response('{"ok":true}', 200);
    });
    final service = AppsScriptSheetService(
      client: client,
      url: 'https://script.google.com/macros/s/deployment/exec',
      secret: 'test-secret',
    );

    await expectLater(
      service.upsert(
        recordId: 'attendance|class|slots|1|records|student',
        revision: 1,
        subject: 'PRM393',
        classCode: 'SE1917',
        slot: 1,
        date: '2026-09-20',
        email: 'student@fpt.edu.vn',
        sessionId: 'session-1',
        checkedInAt: DateTime.utc(2026, 9, 20, 9),
        attendanceStatus: 'present',
        recordSource: 'qr',
      ),
      throwsA(isA<SheetSyncException>()),
    );

    expect(actions, ['upsert']);
  });

  test('manual attendance never falls back to a legacy append', () async {
    final actions = <String>[];
    final client = MockClient((request) async {
      final payload = jsonDecode(request.body) as Map<String, dynamic>;
      actions.add(payload['action'] as String);
      return http.Response.bytes(
        utf8.encode('{"ok":false,"error":"Action không được hỗ trợ."}'),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    });
    final service = AppsScriptSheetService(
      client: client,
      url: 'https://script.google.com/macros/s/deployment/exec',
      secret: 'test-secret',
    );

    await expectLater(
      service.upsert(
        recordId: 'attendance|class|slots|1|records|student',
        revision: 1,
        subject: 'PRM393',
        classCode: 'SE1917',
        slot: 1,
        date: '2026-09-20',
        email: 'student@fpt.edu.vn',
        sessionId: 'session-1',
        checkedInAt: null,
        attendanceStatus: 'excused',
        recordSource: 'teacher',
        reason: 'Có giấy xác nhận',
      ),
      throwsA(isA<SheetSyncException>()),
    );
    expect(actions, ['upsert']);
  });

  test('follows the Google Apps Script POST redirect as GET', () async {
    final methods = <String>[];
    final client = MockClient((request) async {
      methods.add(request.method);
      if (request.method == 'POST') {
        return http.Response(
          '',
          302,
          headers: {'location': 'https://script.googleusercontent.com/result'},
        );
      }
      expect(request.url.host, 'script.googleusercontent.com');
      return http.Response('{"ok":true}', 200);
    });
    final service = AppsScriptSheetService(
      client: client,
      url: 'https://script.google.com/macros/s/deployment/exec',
      secret: 'test-secret',
    );

    await service.sort(subject: 'PRM393', classCode: 'SE1917');

    expect(methods, ['POST', 'GET']);
  });

  test('reports a missing doPost deployment clearly', () async {
    final client = MockClient(
      (_) async => http.Response(
        '<!DOCTYPE html><div>Không tìm thấy hàm tập lệnh: doPost</div>',
        200,
        headers: {'content-type': 'text/html; charset=utf-8'},
      ),
    );
    final service = AppsScriptSheetService(
      client: client,
      url: 'https://script.google.com/macros/s/deployment/exec',
      secret: 'test-secret',
    );

    expect(
      () => service.sort(subject: 'PRM393', classCode: 'SE1917'),
      throwsA(
        isA<SheetSyncException>().having(
          (error) => error.message,
          'message',
          contains('doPost'),
        ),
      ),
    );
  });
}
