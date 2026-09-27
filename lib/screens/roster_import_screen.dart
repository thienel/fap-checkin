import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../domain/models.dart';
import '../domain/roster_import.dart';
import '../services/attendance_api.dart';
import '../services/gemini_ocr_service.dart';
import '../theme/app_theme.dart';
import '../widgets/app_ui.dart';

enum OcrScanAction { append, replace }

class RosterImportScreen extends StatefulWidget {
  const RosterImportScreen({super.key, required this.api, this.ocrService});

  final AttendanceApi api;
  final GeminiOcrService? ocrService;

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

  late final GeminiOcrService _ocr;
  bool _scanningOcr = false;
  late final String _activeApiKey;
  late final String _activeModel;

  bool get _isOcrSource =>
      _fileName != null &&
      (_fileName!.toLowerCase().endsWith('.png') ||
          _fileName!.toLowerCase().endsWith('.jpg') ||
          _fileName!.toLowerCase().endsWith('.jpeg') ||
          _fileName!.toLowerCase().endsWith('.webp') ||
          _fileName!.contains(' + '));

  void _clearRoster() {
    setState(() {
      _file = null;
      _fileName = null;
      _rows = [];
      _progress = 0;
    });
  }

  @override
  void initState() {
    super.initState();
    _classes = widget.api.getCourseClasses();
    _activeApiKey = GeminiOcrSettings.apiKey;
    _activeModel = GeminiOcrSettings.model;
    _ocr =
        widget.ocrService ??
        GeminiOcrService(apiKey: _activeApiKey, defaultModel: _activeModel);
  }

  @override
  void dispose() {
    if (widget.ocrService == null) _ocr.close();
    super.dispose();
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
      var bytes = picked.bytes;
      if (bytes == null && picked.path != null) {
        bytes = await File(picked.path!).readAsBytes();
      }
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

  Future<void> _editOcrRow(int index) async {
    if (!_isOcrSource || _file == null || _importing || _scanningOcr) return;
    final row = _rows[index];
    final code = TextEditingController(text: row.studentCode);
    final name = TextEditingController(text: row.fullName);
    final email = TextEditingController(text: row.email);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Kiểm tra dòng ${row.rowNumber}'),
        content: SizedBox(
          width: 440,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: code,
                decoration: const InputDecoration(labelText: 'Mã sinh viên'),
              ),
              const SizedBox(height: AppSpace.md),
              TextField(
                controller: name,
                decoration: const InputDecoration(labelText: 'Họ tên'),
              ),
              const SizedBox(height: AppSpace.md),
              TextField(
                controller: email,
                decoration: const InputDecoration(labelText: 'Email'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Hủy'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Lưu dòng'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      final old = _file!;
      final rows = old.rows.map((values) => List<String>.from(values)).toList();
      final values = {
        RosterField.studentCode: code.text.trim(),
        RosterField.fullName: name.text.trim(),
        RosterField.email: email.text.trim(),
      };
      for (final entry in values.entries) {
        final column = _mapping[entry.key];
        if (column != null && column >= 0 && column < rows[index].length) {
          rows[index][column] = entry.value;
        }
      }
      final updated = RosterFile(
        headers: old.headers,
        rows: rows,
        rowNumbers: old.rowNumbers,
      );
      setState(() {
        _file = updated;
        _rows = validateRosterRows(updated, _mapping);
      });
    }
    code.dispose();
    name.dispose();
    email.dispose();
  }

  Future<OcrScanAction?> _showOcrScanModeDialog() async {
    return showDialog<OcrScanAction>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.panel),
        ),
        title: const Row(
          children: [
            Icon(Icons.add_photo_alternate_rounded, color: AppColors.primary),
            SizedBox(width: AppSpace.sm),
            Text('Quét thêm ảnh'),
          ],
        ),
        content: SizedBox(
          width: 480,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('${_rows.length} sinh viên trong bảng hiện tại.'),
              const SizedBox(height: AppSpace.lg),
              InkWell(
                onTap: () => Navigator.pop(dialogContext, OcrScanAction.append),
                borderRadius: BorderRadius.circular(AppRadii.control),
                child: Container(
                  padding: const EdgeInsets.all(AppSpace.md),
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: AppColors.primary.withValues(alpha: 0.35),
                      width: 1.5,
                    ),
                    borderRadius: BorderRadius.circular(AppRadii.control),
                    color: AppColors.primary.withValues(alpha: 0.05),
                  ),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: AppColors.primary.withValues(alpha: 0.12),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.playlist_add_rounded,
                          color: AppColors.primary,
                          size: 24,
                        ),
                      ),
                      const SizedBox(width: AppSpace.md),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Gộp vào bảng hiện tại',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                color: AppColors.primary,
                                fontSize: 14,
                              ),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              'Thêm sinh viên mới, bỏ qua mã hoặc email trùng.',
                              style: const TextStyle(
                                fontSize: 12,
                                color: AppColors.textMuted,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const Icon(
                        Icons.chevron_right_rounded,
                        color: AppColors.primary,
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: AppSpace.md),
              InkWell(
                onTap: () =>
                    Navigator.pop(dialogContext, OcrScanAction.replace),
                borderRadius: BorderRadius.circular(AppRadii.control),
                child: Container(
                  padding: const EdgeInsets.all(AppSpace.md),
                  decoration: BoxDecoration(
                    border: Border.all(color: AppColors.border),
                    borderRadius: BorderRadius.circular(AppRadii.control),
                  ),
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: const BoxDecoration(
                          color: AppColors.surfaceMuted,
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.refresh_rounded,
                          color: AppColors.textMuted,
                          size: 24,
                        ),
                      ),
                      const SizedBox(width: AppSpace.md),
                      const Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Thay bảng hiện tại',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                color: AppColors.text,
                                fontSize: 14,
                              ),
                            ),
                            SizedBox(height: 3),
                            Text(
                              'Chỉ giữ sinh viên từ ảnh mới.',
                              style: TextStyle(
                                fontSize: 12,
                                color: AppColors.textMuted,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const Icon(
                        Icons.chevron_right_rounded,
                        color: AppColors.textMuted,
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, null),
            child: const Text('Hủy'),
          ),
        ],
      ),
    );
  }

  Future<void> _pickImageForOcr() async {
    if (_activeApiKey.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Chưa có cấu hình quét ảnh. Liên hệ quản trị viên.'),
        ),
      );
      return;
    }

    OcrScanAction scanAction = OcrScanAction.replace;
    if (_rows.isNotEmpty) {
      final selectedAction = await _showOcrScanModeDialog();
      if (selectedAction == null) return;
      scanAction = selectedAction;
    }

    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['png', 'jpg', 'jpeg', 'webp'],
        withData: true,
      );
      if (result == null) return;
      final picked = result.files.single;
      var bytes = picked.bytes;
      if (bytes == null && picked.path != null) {
        bytes = await File(picked.path!).readAsBytes();
      }
      if (bytes == null) {
        throw const FormatException('Không đọc được nội dung tệp ảnh.');
      }

      setState(() => _scanningOcr = true);

      final lowerName = picked.name.toLowerCase();
      final mimeType = lowerName.endsWith('.png')
          ? 'image/png'
          : lowerName.endsWith('.webp')
          ? 'image/webp'
          : 'image/jpeg';

      final scannedItems = await _ocr.scanStudentsFromImage(
        imageBytes: bytes,
        mimeType: mimeType,
        explicitApiKey: _activeApiKey,
        modelName: _activeModel,
      );

      if (scannedItems.isEmpty) {
        throw const FormatException(
          'AI không tìm thấy sinh viên nào trong bức ảnh. Hãy thử ảnh rõ nét hơn.',
        );
      }

      final List<List<String>>? existingData =
          scanAction == OcrScanAction.append
          ? _rows.map((r) => [r.studentCode, r.fullName, r.email]).toList()
          : null;

      final mergedFileName =
          scanAction == OcrScanAction.append && _fileName != null
          ? '$_fileName + ${picked.name}'
          : picked.name;

      final ocrFile = rosterFileFromOcrItems(
        fileName: mergedFileName,
        items: scannedItems.map((e) => e.toMap()).toList(),
        existingRows: existingData,
      );
      final mapping = suggestRosterMapping(ocrFile.headers);

      if (!mounted) return;
      setState(() {
        _fileName = mergedFileName;
        _file = ocrFile;
        _mapping = mapping;
        _rows = validateRosterRows(ocrFile, mapping);
      });

      if (scanAction == OcrScanAction.append && existingData != null) {
        final addedCount = ocrFile.rows.length - existingData.length;
        final duplicateCount = scannedItems.length - addedCount;
        final message = duplicateCount > 0
            ? 'Đã thêm $addedCount sinh viên, bỏ qua $duplicateCount dòng trùng.'
            : 'Đã thêm $addedCount sinh viên.';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(backgroundColor: AppColors.success, content: Text(message)),
        );
      }
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: AppColors.error,
          content: Text('$error'),
          duration: const Duration(seconds: 5),
        ),
      );
    } finally {
      if (mounted) setState(() => _scanningOcr = false);
    }
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
    final invalidCount = _rows.where((row) => !row.isValid).length;
    if (invalidCount > 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Có $invalidCount dòng lỗi. Hãy sửa file trước khi import.',
          ),
        ),
      );
      return;
    }

    setState(() {
      _importing = true;
      _progress = 0;
    });
    try {
      if (_mode == RosterImportMode.replaceInactive) {
        final deactivated = await widget.api
            .countRosterReplacementDeactivations(
              courseClassId: course.id,
              rows: _rows,
            );
        if (!mounted) return;
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('Xác nhận thay thế danh sách'),
            content: Text(
              'Sẽ cập nhật ${_rows.length} sinh viên và vô hiệu hóa $deactivated sinh viên hiện có không nằm trong file. Bạn có muốn tiếp tục?',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('Hủy'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('Tiếp tục'),
              ),
            ],
          ),
        );
        if (confirmed != true) return;
      }
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
        SnackBar(content: Text('Đã import ${result.validRows} sinh viên.')),
      );
    } catch (error, stack) {
      debugPrint('IMPORT ERROR: $error\n$stack');
      if (mounted) {
        final errorText = error.toString().trim();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: AppColors.error,
            duration: const Duration(seconds: 8),
            content: Text(
              errorText.isNotEmpty
                  ? 'Import thất bại: $errorText'
                  : 'Import thất bại: Lỗi giao dịch Firebase ($error)',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final validCount = _rows.where((row) => row.isValid).length;
    return Padding(
      padding: const EdgeInsets.all(AppSpace.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const AppPageHeader(title: 'Danh sách sinh viên'),
          const SizedBox(height: AppSpace.xl),
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
                      onChanged: (_importing || _scanningOcr)
                          ? null
                          : (value) => setState(() => _selectedClass = value),
                    );
                  },
                ),
              ),
              FilledButton.tonalIcon(
                onPressed: (_importing || _scanningOcr) ? null : _pickFile,
                icon: const Icon(Icons.upload_file),
                label: Text(
                  _fileName != null && !_isOcrSource
                      ? _fileName!
                      : 'Chọn CSV/XLSX',
                ),
              ),
              FilledButton.icon(
                onPressed: (_importing || _scanningOcr)
                    ? null
                    : _pickImageForOcr,
                icon: _scanningOcr
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.document_scanner_rounded),
                label: Text(_scanningOcr ? 'Đang đọc ảnh…' : 'Quét ảnh'),
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  foregroundColor: Colors.white,
                ),
              ),
              if (_fileName != null)
                InputChip(
                  avatar: Icon(
                    _isOcrSource
                        ? Icons.image_rounded
                        : Icons.description_rounded,
                    size: 16,
                    color: AppColors.primary,
                  ),
                  label: Text(_fileName!, style: const TextStyle(fontSize: 12)),
                  onDeleted: (_importing || _scanningOcr) ? null : _clearRoster,
                  deleteIconColor: AppColors.textMuted,
                  tooltip: 'Xóa danh sách hiện tại',
                ),
            ],
          ),
          if (_file != null) ...[
            if (_isOcrSource && validCount != _rows.length) ...[
              const SizedBox(height: AppSpace.md),
              AppNotice(
                message:
                    '${_rows.length - validCount} dòng cần sửa trước khi nhập.',
                tone: AppTone.warning,
              ),
            ],
            const SizedBox(height: 20),
            Wrap(
              spacing: 14,
              runSpacing: 12,
              children: [
                if (!_isOcrSource) ...[
                  _mappingDropdown(RosterField.email, 'Email'),
                  _mappingDropdown(RosterField.studentCode, 'Mã sinh viên'),
                  _mappingDropdown(RosterField.fullName, 'Họ tên'),
                ],
                SizedBox(
                  width: 230,
                  child: DropdownButtonFormField<RosterImportMode>(
                    initialValue: _mode,
                    decoration: const InputDecoration(labelText: 'Cách nhập'),
                    items: const [
                      DropdownMenuItem(
                        value: RosterImportMode.merge,
                        child: Text('Gộp vào lớp'),
                      ),
                      DropdownMenuItem(
                        value: RosterImportMode.replaceInactive,
                        child: Text('Thay danh sách lớp'),
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
            Wrap(
              spacing: AppSpace.lg,
              runSpacing: AppSpace.md,
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Wrap(
                  spacing: AppSpace.sm,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    _CountChip(
                      label: 'Tổng',
                      value: _rows.length,
                      tone: AppTone.info,
                    ),
                    _CountChip(
                      label: 'Hợp lệ',
                      value: validCount,
                      tone: AppTone.success,
                    ),
                    _CountChip(
                      label: 'Lỗi',
                      value: _rows.length - validCount,
                      tone: AppTone.error,
                    ),
                    const SizedBox(width: AppSpace.xs),
                    OutlinedButton.icon(
                      onPressed: (_importing || _scanningOcr)
                          ? null
                          : _clearRoster,
                      icon: const Icon(Icons.delete_sweep_outlined, size: 18),
                      label: const Text('Xóa bảng'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.textMuted,
                        visualDensity: VisualDensity.compact,
                      ),
                    ),
                  ],
                ),
                FilledButton.icon(
                  onPressed:
                      _importing ||
                          _selectedClass == null ||
                          validCount != _rows.length
                      ? null
                      : _import,
                  icon: const Icon(Icons.cloud_upload_outlined),
                  label: const Text('Nhập danh sách'),
                ),
              ],
            ),
            if (!_isOcrSource && validCount != _rows.length) ...[
              const SizedBox(height: 8),
              Text(
                'Hãy sửa toàn bộ ${_rows.length - validCount} dòng lỗi trước khi import.',
                style: const TextStyle(color: AppColors.error),
              ),
            ],
            if (_importing) ...[
              const SizedBox(height: 10),
              LinearProgressIndicator(value: _progress),
            ],
            const SizedBox(height: 14),
            Expanded(child: _previewTable()),
          ] else
            const Expanded(
              child: AppEmptyState(
                icon: Icons.upload_file_outlined,
                title: 'Chưa chọn tệp danh sách',
                description: 'Tệp cần có email, mã sinh viên và họ tên.',
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
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadii.panel),
        side: const BorderSide(color: AppColors.border),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          return SingleChildScrollView(
            scrollDirection: Axis.vertical,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: ConstrainedBox(
                constraints: BoxConstraints(minWidth: constraints.maxWidth),
                child: DataTable(
                  horizontalMargin: AppSpace.xl,
                  columnSpacing: 36,
                  headingRowColor: const WidgetStatePropertyAll(
                    AppColors.surfaceMuted,
                  ),
                  columns: const [
                    DataColumn(
                      label: Text(
                        'Dòng',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                    DataColumn(
                      label: Text(
                        'Email',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                    DataColumn(
                      label: Text(
                        'Mã sinh viên',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                    DataColumn(
                      label: Text(
                        'Họ tên',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                    DataColumn(
                      label: Padding(
                        padding: EdgeInsets.only(right: 28),
                        child: Text(
                          'Trạng thái',
                          style: TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ),
                    ),
                  ],
                  rows: [
                    for (
                      var index = 0;
                      index < _rows.length && index < 200;
                      index++
                    )
                      _previewRow(index),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  DataRow _previewRow(int index) {
    final row = _rows[index];
    final edit = _isOcrSource ? () => _editOcrRow(index) : null;
    return DataRow(
      color: row.isValid
          ? null
          : const WidgetStatePropertyAll(AppColors.errorSurface),
      cells: [
        DataCell(Text('${row.rowNumber}')),
        DataCell(Text(row.email), onTap: edit),
        DataCell(Text(row.studentCode), onTap: edit),
        DataCell(Text(row.fullName), onTap: edit),
        DataCell(
          Padding(
            padding: const EdgeInsets.only(right: 28),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  row.isValid
                      ? Icons.check_circle_outline
                      : Icons.error_outline,
                  size: 16,
                  color: row.isValid ? AppColors.success : AppColors.error,
                ),
                const SizedBox(width: AppSpace.sm),
                Text(row.isValid ? 'Hợp lệ' : row.errors.join('; ')),
                if (_isOcrSource) ...[
                  const SizedBox(width: AppSpace.sm),
                  const Tooltip(
                    message: 'Sửa dòng',
                    child: Icon(
                      Icons.edit_outlined,
                      size: 16,
                      color: AppColors.textMuted,
                    ),
                  ),
                ],
              ],
            ),
          ),
          onTap: edit,
        ),
      ],
    );
  }
}

class _CountChip extends StatelessWidget {
  const _CountChip({
    required this.label,
    required this.value,
    required this.tone,
  });

  final String label;
  final int value;
  final AppTone tone;

  @override
  Widget build(BuildContext context) => Chip(
    backgroundColor: tone.background,
    side: BorderSide(color: tone.foreground.withValues(alpha: 0.2)),
    avatar: CircleAvatar(
      backgroundColor: tone.foreground,
      child: Text(
        '$value',
        style: const TextStyle(color: Colors.white, fontSize: 11),
      ),
    ),
    label: Text(label),
  );
}
