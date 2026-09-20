import 'dart:convert';
import 'dart:typed_data';

import 'package:csv/csv.dart';
import 'package:excel/excel.dart';

enum RosterField { email, studentCode, fullName }

enum RosterImportMode { merge, replaceInactive }

class RosterFile {
  const RosterFile({required this.headers, required this.rows});

  final List<String> headers;
  final List<List<String>> rows;
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
      throw const FormatException('File Excel không có worksheet.');
    }
    final sheet = workbook.tables.values.first;
    rawRows = sheet.rows
        .map((row) => row.map((cell) => cell?.value?.toString() ?? '').toList())
        .toList();
  } else {
    throw const FormatException('Chỉ hỗ trợ file CSV hoặc XLSX.');
  }

  final nonEmpty = rawRows
      .where((row) => row.any((cell) => cell.toString().trim().isNotEmpty))
      .toList();
  if (nonEmpty.isEmpty) throw const FormatException('File không có dữ liệu.');
  final headers = nonEmpty.first
      .map((value) => value.toString().trim())
      .toList();
  final rows = nonEmpty.skip(1).map((row) {
    return List<String>.generate(
      headers.length,
      (index) => index < row.length ? row[index].toString().trim() : '',
    );
  }).toList();
  return RosterFile(headers: headers, rows: rows);
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
    RosterField.fullName: find({
      'hoten',
      'họten',
      'hotên',
      'hovaten',
      'fullname',
      'name',
    }),
  };
}

List<RosterRow> validateRosterRows(
  RosterFile file,
  Map<RosterField, int?> mapping,
) {
  final seen = <String>{};
  String value(List<String> row, RosterField field) {
    final index = mapping[field];
    return index == null || index < 0 || index >= row.length
        ? ''
        : row[index].trim();
  }

  return [
    for (var index = 0; index < file.rows.length; index++)
      () {
        final row = file.rows[index];
        final email = value(row, RosterField.email);
        final code = value(row, RosterField.studentCode);
        final name = value(row, RosterField.fullName);
        final normalizedEmail = normalizeEmail(email);
        final errors = <String>[];
        if (!RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(normalizedEmail)) {
          errors.add('Email không hợp lệ');
        } else if (!seen.add(normalizedEmail)) {
          errors.add('Email trùng trong file');
        }
        if (code.isEmpty) errors.add('Thiếu mã sinh viên');
        if (name.isEmpty) errors.add('Thiếu họ tên');
        return RosterRow(
          rowNumber: index + 2,
          email: email,
          studentCode: code,
          fullName: name,
          errors: errors,
        );
      }(),
  ];
}

String normalizeEmail(String value) => value.trim().toLowerCase();
