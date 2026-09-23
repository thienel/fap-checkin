import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:fap_check_attendance/domain/roster_import.dart';

void main() {
  // ---------------------------------------------------------------------------
  // Cac test goc (giu nguyen de khong pha vo coverage cu)
  // ---------------------------------------------------------------------------

  test('CSV template is mapped and normalized', () {
    final file = parseRosterFile(
      'students.csv',
      Uint8List.fromList(
        utf8.encode(
          'email,m\u00e3 sinh vi\u00ean,h\u1ecd t\u00ean\n'
          ' Alice@Example.com ,SE001,Nguy\u1ec5n V\u0103n An\n',
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

    expect(rows[0].errors, contains('Email kh\u00f4ng h\u1ee3p l\u1ec7'));
    expect(rows[1].isValid, isFalse); // dong 1 cung bi loi vi trung voi dong 2
    // Ca hai dong student@example.com va STUDENT@example.com deu co loi trung
    expect(rows[1].errors, contains('Email tr\u00f9ng trong file'));
    expect(rows[2].errors, contains('Email tr\u00f9ng trong file'));
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

    expect(row.errors, containsAll(['Thi\u1ebfu m\u00e3 sinh vi\u00ean', 'Thi\u1ebfu h\u1ecd t\u00ean']));
  });

  // ---------------------------------------------------------------------------
  // Task 1.1 - Cac test MSSV bat buoc
  // ---------------------------------------------------------------------------

  group('normalizeStudentCode', () {
    test('trim va uppercase', () {
      expect(normalizeStudentCode(' se123 '), 'SE123');
      expect(normalizeStudentCode('se001'), 'SE001');
    });

    test('chuoi rong van tra ve rong sau trim', () {
      expect(normalizeStudentCode('   '), '');
      expect(normalizeStudentCode(''), '');
    });
  });

  group('studentCodeNormalized getter', () {
    test('RosterRow tra ve normalized code', () {
      const row = RosterRow(
        rowNumber: 2,
        email: 'a@b.com',
        studentCode: ' se001 ',
        fullName: 'A',
        errors: [],
      );
      expect(row.studentCodeNormalized, 'SE001');
    });
  });

  group('validate format MSSV', () {
    const mapping = {
      RosterField.email: 0,
      RosterField.studentCode: 1,
      RosterField.fullName: 2,
    };

    test('MSSV hop le khong bao loi', () {
      const file = RosterFile(
        headers: ['email', 'studentCode', 'fullName'],
        rows: [
          ['a@b.com', 'SE001', 'Nguyen Van A'],
          ['c@d.com', 'SS_123-X', 'Nguyen Van B'],
        ],
      );
      final rows = validateRosterRows(file, mapping);
      expect(rows[0].isValid, isTrue);
      expect(rows[1].isValid, isTrue);
    });

    test('MSSV chua du 3 ky tu bi tu choi', () {
      const file = RosterFile(
        headers: ['email', 'studentCode', 'fullName'],
        rows: [
          ['a@b.com', 'SE', 'Nguyen Van A'],
        ],
      );
      final rows = validateRosterRows(file, mapping);
      expect(rows[0].errors.any((e) => e.contains('MSSV kh\u00f4ng h\u1ee3p l\u1ec7')), isTrue);
    });

    test('MSSV qua 20 ky tu bi tu choi', () {
      const file = RosterFile(
        headers: ['email', 'studentCode', 'fullName'],
        rows: [
          ['a@b.com', 'ABCDEFGHIJ1234567890X', 'Nguyen Van A'],
        ],
      );
      final rows = validateRosterRows(file, mapping);
      expect(rows[0].errors.any((e) => e.contains('MSSV kh\u00f4ng h\u1ee3p l\u1ec7')), isTrue);
    });

    test('MSSV chua ky tu dac biet khong hop le', () {
      const file = RosterFile(
        headers: ['email', 'studentCode', 'fullName'],
        rows: [
          ['a@b.com', 'SE@001', 'Nguyen Van A'],
          ['c@d.com', 'SE 001', 'Nguyen Van B'],
          ['e@f.com', 'SE.001', 'Nguyen Van C'],
        ],
      );
      final rows = validateRosterRows(file, mapping);
      for (final row in rows) {
        expect(row.errors.any((e) => e.contains('MSSV kh\u00f4ng h\u1ee3p l\u1ec7')), isTrue,
            reason: 'Row ${row.rowNumber} MSSV=${row.studentCode} phai bao loi');
      }
    });

    test('MSSV khac hoa/thuong van bi detect la trung', () {
      // 'se001' va 'SE001' sau normalize deu la 'SE001' => trung
      const file = RosterFile(
        headers: ['email', 'studentCode', 'fullName'],
        rows: [
          ['a@b.com', 'se001', 'Nguyen Van A'],
          ['c@d.com', 'SE001', 'Nguyen Van B'],
        ],
      );
      final rows = validateRosterRows(file, mapping);
      // Ca hai dong deu phai bao loi MSSV trung
      expect(rows[0].errors, contains('MSSV tr\u00f9ng trong file'));
      expect(rows[1].errors, contains('MSSV tr\u00f9ng trong file'));
    });

    test('MSSV co khoang trang xung quanh van detect trung sau trim', () {
      const file = RosterFile(
        headers: ['email', 'studentCode', 'fullName'],
        rows: [
          ['a@b.com', ' SE001 ', 'Nguyen Van A'],
          ['c@d.com', 'SE001', 'Nguyen Van B'],
        ],
      );
      final rows = validateRosterRows(file, mapping);
      expect(rows[0].errors, contains('MSSV tr\u00f9ng trong file'));
      expect(rows[1].errors, contains('MSSV tr\u00f9ng trong file'));
    });
  });

  group('duplicate MSSV - tat ca dong trung deu co loi', () {
    const mapping = {
      RosterField.email: 0,
      RosterField.studentCode: 1,
      RosterField.fullName: 2,
    };

    test('ba dong trung MSSV - ca ba deu co loi', () {
      const file = RosterFile(
        headers: ['email', 'studentCode', 'fullName'],
        rows: [
          ['a@b.com', 'SE001', 'Nguyen Van A'],
          ['c@d.com', 'SE001', 'Nguyen Van B'],
          ['e@f.com', 'SE001', 'Nguyen Van C'],
        ],
      );
      final rows = validateRosterRows(file, mapping);
      for (final row in rows) {
        expect(
          row.errors,
          contains('MSSV tr\u00f9ng trong file'),
          reason: 'Dong ${row.rowNumber} phai co loi MSSV trung',
        );
      }
    });

    test('dong dau tien cung bi bao loi (khong chi dong thu hai)', () {
      const file = RosterFile(
        headers: ['email', 'studentCode', 'fullName'],
        rows: [
          ['first@b.com', 'SE001', 'A'],
          ['second@b.com', 'SE001', 'B'],
        ],
      );
      final rows = validateRosterRows(file, mapping);
      // Dong dau tien (index 0) phai co loi, khong chi dong thu hai
      expect(rows[0].errors, contains('MSSV tr\u00f9ng trong file'));
      expect(rows[1].errors, contains('MSSV tr\u00f9ng trong file'));
    });

    test('MSSV khong trung thi khong bao loi', () {
      const file = RosterFile(
        headers: ['email', 'studentCode', 'fullName'],
        rows: [
          ['a@b.com', 'SE001', 'A'],
          ['c@d.com', 'SE002', 'B'],
          ['e@f.com', 'SE003', 'C'],
        ],
      );
      final rows = validateRosterRows(file, mapping);
      for (final row in rows) {
        expect(row.errors.where((e) => e.contains('MSSV')), isEmpty,
            reason: 'Dong ${row.rowNumber} khong nen co loi MSSV');
      }
    });
  });
}