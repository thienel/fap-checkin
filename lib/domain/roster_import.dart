import 'dart:convert';
import 'dart:typed_data';

import 'package:csv/csv.dart';
import 'package:excel/excel.dart';

enum RosterField { email, studentCode, fullName }

enum RosterImportMode { merge, replaceInactive }

class RosterFile {
  const RosterFile({
    required this.headers,
    required this.rows,
    this.rowNumbers = const [],
  });

  final List<String> headers;
  final List<List<String>> rows;
  final List<int> rowNumbers;
}

class RosterRow {
  const RosterRow({
    required this.rowNumber,
    required this.email,
    required this.studentCode,
    required this.fullName,
    required this.errors,
  });

  final int rowNumber;
  final String email;
  final String studentCode;
  final String fullName;
  final List<String> errors;

  bool get isValid => errors.isEmpty;
  String get emailNormalized => normalizeEmail(email);

  /// MSSV chuan hoa: trim + toUpperCase. Dung de ghi vao Firestore.
  String get studentCodeNormalized => normalizeStudentCode(studentCode);
}

RosterFile parseRosterFile(String fileName, Uint8List bytes) {
  final lowerName = fileName.toLowerCase();
  final List<List<dynamic>> rawRows;
  if (lowerName.endsWith('.csv')) {
    final source = utf8
        .decode(bytes, allowMalformed: true)
        .replaceFirst('\ufeff', '');
    rawRows = CsvToListConverter(
      shouldParseNumbers: false,
      eol: source.contains('\r\n') ? '\r\n' : '\n',
    ).convert(source);
  } else if (lowerName.endsWith('.xlsx')) {
    final workbook = Excel.decodeBytes(bytes);
    if (workbook.tables.isEmpty) {
      throw const FormatException('File Excel khong co worksheet.');
    }
    final sheet = workbook.tables.values.first;
    rawRows = sheet.rows
        .map((row) => row.map((cell) => cell?.value?.toString() ?? '').toList())
        .toList();
  } else {
    throw const FormatException('Chi ho tro file CSV hoac XLSX.');
  }

  final nonEmpty = [
    for (var index = 0; index < rawRows.length; index++)
      if (rawRows[index].any((cell) => cell.toString().trim().isNotEmpty))
        (line: index + 1, values: rawRows[index]),
  ].toList();
  if (nonEmpty.isEmpty) throw const FormatException('File khong co du lieu.');
  final headers = nonEmpty.first.values
      .map((value) => value.toString().trim())
      .toList();
  final rows = nonEmpty.skip(1).map((entry) {
    final row = entry.values;
    return List<String>.generate(
      headers.length,
      (index) => index < row.length ? row[index].toString().trim() : '',
    );
  }).toList();
  return RosterFile(
    headers: headers,
    rows: rows,
    rowNumbers: nonEmpty.skip(1).map((entry) => entry.line).toList(),
  );
}

Map<RosterField, int?> suggestRosterMapping(List<String> headers) {
  String normalized(String value) => value
      .trim()
      .toLowerCase()
      .replaceAll(RegExp(r'[\s_-]+'), '')
      .replaceAll(RegExp('[àáảãạăằắẳẵặâầấẩẫậ]'), 'a')
      .replaceAll(RegExp('[èéẻẽẹêềếểễệ]'), 'e')
      .replaceAll(RegExp('[ìíỉĩị]'), 'i')
      .replaceAll(RegExp('[òóỏõọôồốổỗộơờớởỡợ]'), 'o')
      .replaceAll(RegExp('[ùúủũụưừứửữự]'), 'u')
      .replaceAll(RegExp('[ỳýỷỹỵ]'), 'y')
      .replaceAll('đ', 'd');

  int? find(Set<String> candidates) {
    for (var index = 0; index < headers.length; index++) {
      if (candidates.contains(normalized(headers[index]))) return index;
    }
    return null;
  }

  return {
    RosterField.email: find({'email', 'emailaddress', 'mail'}),
    RosterField.studentCode: find({
      'masinhvien',
      'mssv',
      'studentcode',
      'studentid',
    }),
    RosterField.fullName: find({'hoten', 'hovaten', 'fullname', 'name'}),
  };
}

/// Chuan hoa MSSV: trim + toUpperCase.
String normalizeStudentCode(String value) => value.trim().toUpperCase();

/// Pattern MSSV hop le: 3-20 ky tu A-Z, 0-9, gach duoi hoac gach ngang.
final _studentCodePattern = RegExp(r'^[A-Z0-9_-]{3,20}$');

List<RosterRow> validateRosterRows(
  RosterFile file,
  Map<RosterField, int?> mapping,
) {
  String fieldValue(List<String> row, RosterField field) {
    final index = mapping[field];
    return index == null || index < 0 || index >= row.length
        ? ''
        : row[index].trim();
  }

  // Pass 1: Collect de detect duplicates tren toan bo file.
  // Tat ca dong trung - ke ca dong dau tien - deu bi bao loi.
  final emailIndices = <String, List<int>>{};
  final codeIndices = <String, List<int>>{};

  for (var i = 0; i < file.rows.length; i++) {
    final row = file.rows[i];
    final email = fieldValue(row, RosterField.email);
    final code = fieldValue(row, RosterField.studentCode);
    final normalizedEmail = normalizeEmail(email);
    final normalizedCode = normalizeStudentCode(code);

    if (RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(normalizedEmail)) {
      emailIndices.putIfAbsent(normalizedEmail, () => []).add(i);
    }
    if (code.isNotEmpty && _studentCodePattern.hasMatch(normalizedCode)) {
      codeIndices.putIfAbsent(normalizedCode, () => []).add(i);
    }
  }

  final duplicateEmailIdx = <int>{
    for (final list in emailIndices.values)
      if (list.length > 1) ...list,
  };
  final duplicateCodeIdx = <int>{
    for (final list in codeIndices.values)
      if (list.length > 1) ...list,
  };

  // Pass 2: Build RosterRow voi day du loi tung dong.
  return [
    for (var index = 0; index < file.rows.length; index++)
      () {
        final row = file.rows[index];
        final email = fieldValue(row, RosterField.email);
        final code = fieldValue(row, RosterField.studentCode);
        final name = fieldValue(row, RosterField.fullName);
        final normalizedEmail = normalizeEmail(email);
        final normalizedCode = normalizeStudentCode(code);
        final errors = <String>[];

        // Validate email.
        if (!RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(normalizedEmail)) {
          errors.add('Email kh\u00f4ng h\u1ee3p l\u1ec7');
        } else if (duplicateEmailIdx.contains(index)) {
          errors.add('Email tr\u00f9ng trong file');
        }

        // Validate MSSV.
        if (code.isEmpty) {
          errors.add('Thi\u1ebfu m\u00e3 sinh vi\u00ean');
        } else if (!_studentCodePattern.hasMatch(normalizedCode)) {
          errors.add(
            'MSSV kh\u00f4ng h\u1ee3p l\u1ec7 (ch\u1ec9 g\u1ed3m 3\u201320 k\u00fd t\u1ef1 A\u2013Z, 0\u20139, _ ho\u1eb7c -)',
          );
        } else if (duplicateCodeIdx.contains(index)) {
          errors.add('MSSV tr\u00f9ng trong file');
        }

        // Validate ho ten.
        if (name.isEmpty) errors.add('Thi\u1ebfu h\u1ecd t\u00ean');

        return RosterRow(
          rowNumber: file.rowNumbers.length == file.rows.length
              ? file.rowNumbers[index]
              : index + 2,
          email: email,
          studentCode: code,
          fullName: name,
          errors: errors,
        );
      }(),
  ];
}

/// Chuan hoa email: trim + toLowerCase.
String normalizeEmail(String value) => value.trim().toLowerCase();
