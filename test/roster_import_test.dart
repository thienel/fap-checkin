import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:fap_check_attendance/domain/roster_import.dart';

void main() {
  test('CSV template is mapped and normalized', () {
    final file = parseRosterFile(
      'students.csv',
      Uint8List.fromList(
        utf8.encode(
          'email,mã sinh viên,họ tên\n'
          ' Alice@Example.com ,SE001,Nguyễn Văn An\n',
        ),
      ),
    );
    final mapping = suggestRosterMapping(file.headers);
    final rows = validateRosterRows(file, mapping);

    expect(mapping.values, everyElement(isNotNull));
    expect(rows, hasLength(1));
    expect(rows.single.isValid, isTrue);
    expect(rows.single.emailNormalized, 'alice@example.com');
  });

  test('invalid and duplicate emails are reported per row', () {
    const file = RosterFile(
      headers: ['email', 'studentCode', 'fullName'],
      rows: [
        ['not-an-email', 'SE001', 'A'],
        ['student@example.com', 'SE002', 'B'],
        [' STUDENT@example.com ', 'SE003', 'C'],
        ['khoina231@gmail.com', 'SE004', 'D'],
      ],
    );
    final rows = validateRosterRows(file, const {
      RosterField.email: 0,
      RosterField.studentCode: 1,
      RosterField.fullName: 2,
    });

    expect(rows[0].errors, contains('Email không hợp lệ'));
    expect(rows[1].isValid, isTrue);
    expect(rows[2].errors, contains('Email trùng trong file'));
  });

  test('missing required values are rejected', () {
    const file = RosterFile(
      headers: ['email', 'studentCode', 'fullName'],
      rows: [
        ['student@example.com', '', ''],
      ],
    );
    final row = validateRosterRows(file, const {
      RosterField.email: 0,
      RosterField.studentCode: 1,
      RosterField.fullName: 2,
    }).single;

    expect(row.errors, containsAll(['Thiếu mã sinh viên', 'Thiếu họ tên']));
  });
}
