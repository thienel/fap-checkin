import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fap_check_attendance/domain/roster_import.dart';
import 'package:fap_check_attendance/services/gemini_ocr_service.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test(
    'OCR request keeps the key out of the URL and reports no raw API body',
    () async {
      final client = MockClient((request) async {
        expect(request.url.query, isEmpty);
        expect(request.headers['x-goog-api-key'], 'private-key');
        return http.Response('server message with private-key', 400);
      });
      final service = GeminiOcrService(client: client);
      await expectLater(
        service.scanStudentsFromImage(
          imageBytes: Uint8List.fromList([1]),
          explicitApiKey: 'private-key',
        ),
        throwsA(
          predicate((error) => !error.toString().contains('private-key')),
        ),
      );
    },
  );

  test(
    'timetable OCR keeps one course and uses its earliest visible session',
    () {
      final raw = jsonEncode([
        {
          'subject': 'PRM393',
          'classCode': 'SE1801',
          'date': '2026-09-30',
          'daySlot': 3,
          'sessionNumber': 2,
          'totalSessions': 20,
        },
        {
          'subject': 'PRM393',
          'classCode': 'SE1801',
          'date': '2026-09-28',
          'daySlot': 2,
          'sessionNumber': 1,
          'totalSessions': 20,
        },
        {
          'subject': 'MAD101',
          'classCode': 'SE1802',
          'date': '2026-02-30',
          'daySlot': 8,
        },
      ]);
      final items = GeminiOcrService.parseTimetableJson(raw);
      expect(items, hasLength(2));
      expect(items.first.sessionNumber, 1);
      expect(items.first.date, DateTime(2026, 9, 28));
      expect(items.last.date, isNull);
      expect(items.last.daySlot, isNull);
    },
  );

  group('GeminiOcrService JSON parsing', () {
    test('parses pure JSON array with fpt.edu.vn and gmail.com emails', () {
      const raw = '''
[
  {
    "studentCode": "SE183571",
    "fullName": "Nguyễn Ngọc Tường Vy",
    "email": "VyNNTSE183571@fpt.edu.vn"
  },
  {
    "studentCode": "SE182046",
    "fullName": "Đặng Đình Khôi",
    "email": "khoina231@gmail.com"
  }
]
''';

      final items = GeminiOcrService.parseOcrJson(raw);
      expect(items, hasLength(2));
      expect(items[0].studentCode, 'SE183571');
      expect(items[0].fullName, 'Nguyễn Ngọc Tường Vy');
      expect(items[0].email, 'VyNNTSE183571@fpt.edu.vn');

      expect(items[1].studentCode, 'SE182046');
      expect(items[1].fullName, 'Đặng Đình Khôi');
      expect(items[1].email, 'khoina231@gmail.com');
    });

    test('extracts JSON from markdown code block fences', () {
      const rawWithFences = '''
```json
[
  {
    "mssv": "SE172145",
    "name": "Nguyễn Mai Hảo Thiện",
    "email": "ThienNMHSE172145@fpt.edu.vn"
  }
]
```
''';

      final items = GeminiOcrService.parseOcrJson(rawWithFences);
      expect(items, hasLength(1));
      expect(items.single.studentCode, 'SE172145');
      expect(items.single.fullName, 'Nguyễn Mai Hảo Thiện');
      expect(items.single.email, 'ThienNMHSE172145@fpt.edu.vn');
    });

    test(
      'extracts JSON when wrapped in an object like {"students": [...]}',
      () {
        const rawObject = '''
{
  "students": [
    {
      "studentCode": "SE182112",
      "fullName": "Trần Phạm Khánh Quốc",
      "email": "QuocTPKSE182112@fpt.edu.vn"
    }
  ]
}
''';

        final items = GeminiOcrService.parseOcrJson(rawObject);
        expect(items, hasLength(1));
        expect(items.single.studentCode, 'SE182112');
        expect(items.single.fullName, 'Trần Phạm Khánh Quốc');
      },
    );

    test('throws FormatException on empty or non-JSON response', () {
      expect(
        () => GeminiOcrService.parseOcrJson(
          'Xin chào, tôi không tìm thấy bảng nào.',
        ),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('rosterFileFromOcrItems integration with validation', () {
    test('converts OCR items to RosterFile and maps fields automatically', () {
      final ocrItems = [
        {
          'studentCode': 'SE183571',
          'fullName': 'Nguyễn Ngọc Tường Vy',
          'email': 'VyNNTSE183571@fpt.edu.vn',
        },
        {
          'studentCode': 'SE182046',
          'fullName': 'Đặng Đình Khôi',
          'email': 'khoina231@gmail.com',
        },
      ];

      final file = rosterFileFromOcrItems(
        fileName: 'fap_screenshot.png',
        items: ocrItems,
      );

      expect(file.headers, ['Mã sinh viên', 'Họ tên', 'Email']);
      expect(file.rows, hasLength(2));

      final mapping = suggestRosterMapping(file.headers);
      expect(mapping[RosterField.studentCode], 0);
      expect(mapping[RosterField.fullName], 1);
      expect(mapping[RosterField.email], 2);

      final rows = validateRosterRows(file, mapping);
      expect(rows, hasLength(2));
      expect(rows[0].isValid, isTrue);
      expect(rows[0].studentCodeNormalized, 'SE183571');
      expect(rows[0].emailNormalized, 'vynntse183571@fpt.edu.vn');

      expect(rows[1].isValid, isTrue);
      expect(rows[1].studentCodeNormalized, 'SE182046');
      expect(rows[1].emailNormalized, 'khoina231@gmail.com');
    });

    test('merges new OCR items with existingRows and skips duplicate studentCode/email', () {
      final existingRows = [
        ['SE183571', 'Nguyễn Ngọc Tường Vy', 'VyNNTSE183571@fpt.edu.vn'],
      ];

      final newScan = [
        // Duplicate student:
        {
          'studentCode': 'SE183571',
          'fullName': 'Nguyễn Ngọc Tường Vy',
          'email': 'VyNNTSE183571@fpt.edu.vn',
        },
        // New student:
        {
          'studentCode': 'SE172145',
          'fullName': 'Nguyễn Mai Hảo Thiện',
          'email': 'ThienNMHSE172145@fpt.edu.vn',
        },
      ];

      final file = rosterFileFromOcrItems(
        fileName: 'screenshot2.png',
        items: newScan,
        existingRows: existingRows,
      );

      // Should contain 2 students, not 3 (duplicate SE183571 skipped)
      expect(file.rows, hasLength(2));
      expect(file.rows[0][0], 'SE183571');
      expect(file.rows[1][0], 'SE172145');
      expect(file.rowNumbers, [1, 2]);
    });
  });
}
