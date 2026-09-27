import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../domain/schedule.dart';
import '../services/attendance_api.dart';
import '../services/gemini_ocr_service.dart';
import '../theme/app_theme.dart';
import 'app_ui.dart';

class CreateCourseDialog extends StatefulWidget {
  const CreateCourseDialog({super.key, required this.api});

  final AttendanceApi api;

  @override
  State<CreateCourseDialog> createState() => _CreateCourseDialogState();
}

class _CreateCourseDialogState extends State<CreateCourseDialog> {
  final _formKey = GlobalKey<FormState>();
  final _subjectController = TextEditingController();
  final _classController = TextEditingController();
  final _termController = TextEditingController();
  final _ocr = GeminiOcrService();
  DateTime _startDate = DateTime.now();
  SchedulePreset _preset = SchedulePreset.twentySlotsTenWeeks;
  int _daySlot = 1;
  bool _submitting = false;
  bool _scanning = false;
  bool _createdAny = false;
  bool _reviewStartDate = false;
  bool _reviewPreset = false;
  bool _reviewDaySlot = false;
  int _selectionVersion = 0;
  List<OcrTimetableItem> _ocrItems = [];
  int? _selectedOcrIndex;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (_startDate.weekday == DateTime.sunday) {
      _startDate = _startDate.add(const Duration(days: 1));
    }
    _termController.text = _suggestedTerm(_startDate);
  }

  @override
  void dispose() {
    _subjectController.dispose();
    _classController.dispose();
    _termController.dispose();
    _ocr.close();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final selected = await showDatePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
      initialDate: _startDate,
      selectableDayPredicate: (date) => date.weekday != DateTime.sunday,
    );
    if (selected != null) {
      setState(() {
        final usedSuggestion =
            _termController.text == _suggestedTerm(_startDate);
        _startDate = selected;
        if (usedSuggestion) _termController.text = _suggestedTerm(selected);
        _reviewStartDate = false;
      });
    }
  }

  String _suggestedTerm(DateTime date) {
    final season = date.month <= 4
        ? 'SPRING'
        : date.month <= 8
        ? 'SUMMER'
        : 'FALL';
    return '${date.year}-$season';
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    if (_reviewStartDate || _reviewPreset || _reviewDaySlot) {
      setState(
        () => _error = 'Hãy xác nhận ngày bắt đầu, cấu hình và slot còn thiếu trước khi tạo.',
      );
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      await widget.api.createCourseClass(
        subject: _subjectController.text,
        classCode: _classController.text,
        academicTerm: _termController.text,
        startDate: _startDate,
        preset: _preset,
        daySlot: _daySlot,
      );
      if (!mounted) return;
      _createdAny = true;
      if (_selectedOcrIndex != null) {
        final next = List<OcrTimetableItem>.from(_ocrItems)
          ..removeAt(_selectedOcrIndex!);
        if (next.isNotEmpty) {
          setState(() {
            _ocrItems = next;
            _selectOcrItem(0);
          });
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Đã tạo môn–lớp. Hãy kiểm tra môn tiếp theo.'),
            ),
          );
          return;
        }
      }
      Navigator.of(context).pop(true);
    } catch (error) {
      if (mounted) setState(() => _error = 'Không thể tạo môn–lớp: $error');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  void _selectOcrItem(int index) {
    final item = _ocrItems[index];
    _selectedOcrIndex = index;
    _subjectController.text = item.subject;
    _classController.text = item.classCode;
    if (item.date != null) {
      _startDate = item.date!;
      _termController.text = _suggestedTerm(_startDate);
    }
    _reviewStartDate = item.date == null || item.sessionNumber != 1;
    _reviewPreset = true;
    _reviewDaySlot = item.daySlot == null;
    _preset = item.totalSessions == 10
        ? SchedulePreset.tenSlotsFiveWeeks
        : SchedulePreset.twentySlotsTenWeeks;
    _daySlot = item.daySlot ?? 1;
    _selectionVersion++;
    _error = null;
  }

  Future<void> _scanTimetable() async {
    if (GeminiOcrSettings.apiKey.trim().isEmpty) {
      final controller = TextEditingController();
      final key = await showDialog<String>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Gemini API key'),
          content: TextField(
            controller: controller,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: 'API key lưu trên máy này',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Hủy'),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.pop(dialogContext, controller.text.trim()),
              child: const Text('Tiếp tục'),
            ),
          ],
        ),
      );
      controller.dispose();
      if (key == null || key.isEmpty) return;
      try {
        await GeminiOcrSettings.saveLocalConfig(key, GeminiOcrSettings.model);
      } catch (error) {
        if (mounted) {
          setState(() => _error = 'Không lưu được Gemini API key: $error');
        }
        return;
      }
    }
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['png', 'jpg', 'jpeg', 'webp'],
        withData: true,
      );
      if (result == null) return;
      final picked = result.files.single;
      final bytes =
          picked.bytes ??
          (picked.path == null ? null : await File(picked.path!).readAsBytes());
      if (bytes == null) throw const FormatException('Không đọc được ảnh.');
      if (!mounted) return;
      setState(() {
        _scanning = true;
        _error = null;
      });
      final name = picked.name.toLowerCase();
      final items = await _ocr.scanTimetableFromImage(
        imageBytes: bytes,
        mimeType: name.endsWith('.png')
            ? 'image/png'
            : name.endsWith('.webp')
            ? 'image/webp'
            : 'image/jpeg',
        explicitApiKey: GeminiOcrSettings.apiKey,
        modelName: GeminiOcrSettings.model,
      );
      if (items.isEmpty) {
        throw const FormatException('Không tìm thấy môn–lớp trong ảnh TKB.');
      }
      if (!mounted) return;
      setState(() {
        _ocrItems = items;
        _selectOcrItem(0);
      });
    } catch (error) {
      if (mounted) setState(() => _error = 'Không thể đọc ảnh TKB: $error');
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final preview = generateSchedule(startDate: _startDate, preset: _preset);
    return AlertDialog(
      title: const Text('Tạo môn–lớp'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 620),
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                AppNotice(
                  message: 'Nhập thông tin thủ công hoặc quét ảnh lịch trong tuần. Mỗi môn đọc từ ảnh sẽ được kiểm tra trước khi lưu.',
                  icon: Icons.calendar_month_outlined,
                ),
                const SizedBox(height: AppSpace.md),
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                    onPressed: _scanning || _submitting ? null : _scanTimetable,
                    icon: _scanning
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.document_scanner_outlined),
                    label: Text(_scanning ? 'Đang đọc ảnh…' : 'Quét ảnh TKB'),
                  ),
                ),
                if (_ocrItems.isNotEmpty) ...[
                  const SizedBox(height: AppSpace.md),
                  AppNotice(
                    message:
                        'Đã nhận diện ${_ocrItems.length} môn–lớp. Chọn từng môn, sửa thông tin và bấm tạo để chốt.',
                    tone: AppTone.success,
                  ),
                  const SizedBox(height: AppSpace.sm),
                  for (var index = 0; index < _ocrItems.length; index++)
                    ListTile(
                      selected: index == _selectedOcrIndex,
                      selectedTileColor: AppColors.infoSurface,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(AppRadii.control),
                      ),
                      leading: Icon(
                        index == _selectedOcrIndex
                            ? Icons.radio_button_checked
                            : Icons.radio_button_unchecked,
                        color: AppColors.primary,
                      ),
                      title: Text(
                        '${_ocrItems[index].subject} · ${_ocrItems[index].classCode}',
                      ),
                      subtitle: Text(
                        '${_ocrItems[index].date == null ? 'Chưa rõ ngày' : DateFormat('dd/MM/yyyy').format(_ocrItems[index].date!)} · '
                        '${_ocrItems[index].daySlot == null ? 'Chưa rõ slot' : 'Slot ${_ocrItems[index].daySlot}'} · '
                        '${_ocrItems[index].sessionNumber == null ? 'Chưa rõ buổi' : 'Buổi ${_ocrItems[index].sessionNumber}'}',
                      ),
                      onTap: _submitting
                          ? null
                          : () => setState(() => _selectOcrItem(index)),
                    ),
                  const SizedBox(height: AppSpace.md),
                  if (_reviewStartDate || _reviewPreset || _reviewDaySlot)
                    AppNotice(
                      message: [
                        if (_reviewStartDate) 'Chọn ngày bắt đầu của buổi 1',
                        if (_reviewPreset) 'xác nhận cấu hình số buổi',
                        if (_reviewDaySlot) 'xác nhận slot trong ngày',
                      ].join(' · '),
                      tone: AppTone.warning,
                    ),
                  const SizedBox(height: AppSpace.md),
                ],
                Row(
                  children: [
                    Expanded(
                      child: TextFormField(
                        controller: _subjectController,
                        textCapitalization: TextCapitalization.characters,
                        decoration: const InputDecoration(
                          labelText: 'Mã môn học',
                        ),
                        validator: _validateCode,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextFormField(
                        controller: _classController,
                        textCapitalization: TextCapitalization.characters,
                        decoration: const InputDecoration(labelText: 'Mã lớp'),
                        validator: _validateCode,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _termController,
                  textCapitalization: TextCapitalization.characters,
                  decoration: const InputDecoration(
                    labelText: 'Học kỳ',
                    hintText: 'Ví dụ: 2026-FALL',
                  ),
                  validator: _validateCode,
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: InkWell(
                        onTap: _pickDate,
                        borderRadius: BorderRadius.circular(4),
                        child: InputDecorator(
                          decoration: const InputDecoration(
                            labelText: 'Ngày bắt đầu',
                            suffixIcon: Icon(Icons.calendar_month_outlined),
                          ),
                          child: Text(
                            DateFormat('dd/MM/yyyy').format(_startDate),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: DropdownButtonFormField<SchedulePreset>(
                        key: ValueKey('preset-$_selectionVersion'),
                        initialValue: _preset,
                        decoration: const InputDecoration(
                          labelText: 'Cấu hình',
                        ),
                        items: SchedulePreset.values
                            .map(
                              (preset) => DropdownMenuItem(
                                value: preset,
                                child: Text(preset.label),
                              ),
                            )
                            .toList(),
                        onChanged: (value) => setState(() {
                          _preset = value!;
                          _reviewPreset = false;
                        }),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                DropdownButtonFormField<int>(
                  key: ValueKey('slot-$_selectionVersion'),
                  initialValue: _daySlot,
                  decoration: const InputDecoration(
                    labelText: 'Slot trong ngày',
                    helperText: 'Khác với số thứ tự buổi của môn học (buổi 1/10, 2/10…)',
                  ),
                  items: daySlotDefinitions
                      .map(
                        (slot) => DropdownMenuItem(
                          value: slot.number,
                          child: Text(slot.label),
                        ),
                      )
                      .toList(),
                  onChanged: (value) => setState(() {
                    _daySlot = value!;
                    _reviewDaySlot = false;
                  }),
                ),
                if (_reviewPreset || _reviewDaySlot) ...[
                  const SizedBox(height: AppSpace.sm),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: () => setState(() {
                        _reviewPreset = false;
                        _reviewDaySlot = false;
                      }),
                      icon: const Icon(Icons.check_circle_outline),
                      label: const Text('Xác nhận cấu hình và slot đang chọn'),
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                AppNotice(
                  message:
                      'Lịch dự kiến: ${DateFormat('dd/MM').format(preview.first.date)} – '
                      '${DateFormat('dd/MM/yyyy').format(preview.last.date)} · '
                      '${preview.length} buổi môn học · Slot $_daySlot trong ngày · bỏ Chủ nhật',
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  AppNotice(
                    message: _error!,
                    tone: AppTone.error,
                    icon: Icons.error_outline,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _submitting || _scanning
              ? null
              : () => Navigator.pop(context, _createdAny),
          child: const Text('Hủy'),
        ),
        FilledButton(
          onPressed: _submitting || _scanning ? null : _submit,
          child: Text(_submitting ? 'Đang tạo…' : 'Tạo môn–lớp'),
        ),
      ],
    );
  }

  String? _validateCode(String? value) {
    final code = value?.trim() ?? '';
    if (!RegExp(r'^[A-Za-z0-9_-]{2,20}$').hasMatch(code)) {
      return 'Dùng 2–20 ký tự A–Z, 0–9, _ hoặc -';
    }
    return null;
  }
}
