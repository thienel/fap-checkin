import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../domain/models.dart';
import '../domain/roster_import.dart';
import '../services/attendance_api.dart';

class RosterImportScreen extends StatefulWidget {
  const RosterImportScreen({super.key, required this.api});

  final AttendanceApi api;

  @override
  State<RosterImportScreen> createState() => _RosterImportScreenState();
}

class _RosterImportScreenState extends State<RosterImportScreen> {
  late Future<List<CourseClassSummary>> _classes;
  CourseClassSummary? _selectedClass;
  RosterFile? _file;
  String? _fileName;
  Map<RosterField, int?> _mapping = {};
  List<RosterRow> _rows = [];
  RosterImportMode _mode = RosterImportMode.merge;
  bool _importing = false;
  double _progress = 0;

  @override
  void initState() {
    super.initState();
    _classes = widget.api.getCourseClasses();
  }

  Future<void> _pickFile() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['csv', 'xlsx'],
        withData: true,
      );
      if (result == null) return;
      final picked = result.files.single;
      final bytes = picked.bytes;
      if (bytes == null) {
        throw const FormatException('Không đọc được nội dung file.');
      }
      _loadFile(picked.name, bytes);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Không thể mở file: $error')));
    }
  }

  void _loadFile(String name, Uint8List bytes) {
    final parsed = parseRosterFile(name, bytes);
    final mapping = suggestRosterMapping(parsed.headers);
    setState(() {
      _fileName = name;
      _file = parsed;
      _mapping = mapping;
      _rows = validateRosterRows(parsed, mapping);
    });
  }

  void _setMapping(RosterField field, int? index) {
    setState(() {
      _mapping = {..._mapping, field: index};
      if (_file != null) _rows = validateRosterRows(_file!, _mapping);
    });
  }

  Future<void> _import() async {
    final course = _selectedClass;
    if (course == null || _fileName == null || _rows.isEmpty) return;
    final mapped = _mapping.values.whereType<int>().toSet();
    if (_mapping.values.any((value) => value == null) || mapped.length != 3) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Hãy map ba trường vào ba cột khác nhau.'),
        ),
      );
      return;
    }
    if (_rows.every((row) => !row.isValid)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('File không có dòng hợp lệ để import.')),
      );
      return;
    }

    setState(() {
      _importing = true;
      _progress = 0;
    });
    try {
      final result = await widget.api.importRoster(
        courseClassId: course.id,
        fileName: _fileName!,
        rows: _rows,
        mode: _mode,
        onProgress: (done, total) {
          if (mounted) {
            setState(() => _progress = total == 0 ? 1 : done / total);
          }
        },
      );
      if (!mounted) return;
      setState(() => _progress = 1);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Đã import ${result.validRows} sinh viên; '
            'bỏ qua ${result.invalidRows} dòng không hợp lệ.',
          ),
        ),
      );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Import thất bại: $error')));
      }
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final validCount = _rows.where((row) => row.isValid).length;
    return Padding(
      padding: const EdgeInsets.all(36),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Danh sách sinh viên',
            style: Theme.of(context).textTheme.headlineMedium
                ?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 4),
          const Text(
            'Import CSV/XLSX, xem trước lỗi dữ liệu rồi ghi roster vào Firestore.',
          ),
          const SizedBox(height: 24),
          Wrap(
            spacing: 16,
            runSpacing: 12,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SizedBox(
                width: 300,
                child: FutureBuilder<List<CourseClassSummary>>(
                  future: _classes,
                  builder: (context, snapshot) {
                    return DropdownButtonFormField<CourseClassSummary>(
                      initialValue: _selectedClass,
                      decoration: const InputDecoration(labelText: 'Môn–lớp'),
                      items: [
                        for (final course
                            in snapshot.data ?? const <CourseClassSummary>[])
                          DropdownMenuItem(
                            value: course,
                            child: Text(course.label),
                          ),
                      ],
                      onChanged: _importing
                          ? null
                          : (value) => setState(() => _selectedClass = value),
                    );
                  },
                ),
              ),
              FilledButton.tonalIcon(
                onPressed: _importing ? null : _pickFile,
                icon: const Icon(Icons.upload_file),
                label: Text(_fileName ?? 'Chọn file CSV/XLSX'),
              ),
            ],
          ),
          if (_file != null) ...[
            const SizedBox(height: 20),
            Wrap(
              spacing: 14,
              runSpacing: 12,
              children: [
                _mappingDropdown(RosterField.email, 'Email'),
                _mappingDropdown(RosterField.studentCode, 'Mã sinh viên'),
                _mappingDropdown(RosterField.fullName, 'Họ tên'),
                SizedBox(
                  width: 230,
                  child: DropdownButtonFormField<RosterImportMode>(
                    initialValue: _mode,
                    decoration: const InputDecoration(
                      labelText: 'Chế độ import',
                    ),
                    items: const [
                      DropdownMenuItem(
                        value: RosterImportMode.merge,
                        child: Text('Merge'),
                      ),
                      DropdownMenuItem(
                        value: RosterImportMode.replaceInactive,
                        child: Text('Replace inactive'),
                      ),
                    ],
                    onChanged: _importing
                        ? null
                        : (value) => setState(() => _mode = value!),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                _CountChip(
                  label: 'Tổng',
                  value: _rows.length,
                  color: const Color(0xFF245F82),
                ),
                const SizedBox(width: 10),
                _CountChip(
                  label: 'Hợp lệ',
                  value: validCount,
                  color: const Color(0xFF167052),
                ),
                const SizedBox(width: 10),
                _CountChip(
                  label: 'Lỗi',
                  value: _rows.length - validCount,
                  color: const Color(0xFFB5473C),
                ),
                const Spacer(),
                FilledButton.icon(
                  onPressed: _importing || _selectedClass == null
                      ? null
                      : _import,
                  icon: const Icon(Icons.cloud_upload_outlined),
                  label: const Text('Import roster'),
                ),
              ],
            ),
            if (_importing) ...[
              const SizedBox(height: 10),
              LinearProgressIndicator(value: _progress),
            ],
            const SizedBox(height: 14),
            Expanded(child: _previewTable()),
          ] else
            const Expanded(
              child: Center(
                child: Text(
                  'Chọn file theo template: email, mã sinh viên, họ tên.',
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _mappingDropdown(RosterField field, String label) {
    return SizedBox(
      width: 220,
      child: DropdownButtonFormField<int>(
        initialValue: _mapping[field],
        decoration: InputDecoration(labelText: label),
        items: [
          for (var index = 0; index < _file!.headers.length; index++)
            DropdownMenuItem(value: index, child: Text(_file!.headers[index])),
        ],
        onChanged: _importing ? null : (value) => _setMapping(field, value),
      ),
    );
  }

  Widget _previewTable() {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: SingleChildScrollView(
        child: SizedBox(
          width: double.infinity,
          child: DataTable(
            columns: const [
              DataColumn(label: Text('Dòng')),
              DataColumn(label: Text('Email')),
              DataColumn(label: Text('Mã sinh viên')),
              DataColumn(label: Text('Họ tên')),
              DataColumn(label: Text('Kết quả')),
            ],
            rows: [
              for (final row in _rows.take(200))
                DataRow(
                  color: row.isValid
                      ? null
                      : WidgetStateProperty.all(const Color(0xFFFFEEEE)),
                  cells: [
                    DataCell(Text('${row.rowNumber}')),
                    DataCell(Text(row.email)),
                    DataCell(Text(row.studentCode)),
                    DataCell(Text(row.fullName)),
                    DataCell(
                      Text(row.isValid ? 'Hợp lệ' : row.errors.join('; ')),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CountChip extends StatelessWidget {
  const _CountChip({
    required this.label,
    required this.value,
    required this.color,
  });

  final String label;
  final int value;
  final Color color;

  @override
  Widget build(BuildContext context) => Chip(
    avatar: CircleAvatar(
      backgroundColor: color,
      child: Text(
        '$value',
        style: const TextStyle(color: Colors.white, fontSize: 11),
      ),
    ),
    label: Text(label),
  );
}
