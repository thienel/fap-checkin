import 'package:fap_check_attendance/services/apps_script_sheet_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
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
}
