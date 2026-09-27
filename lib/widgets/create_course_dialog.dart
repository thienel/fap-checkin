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
  GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  final _subjectController = TextEditingController();
  final _classController = TextEditingController();
  final _termController = TextEditingController();
  final _ocr = GeminiOcrService();
  DateTime? _startDate = DateTime.now();
  SchedulePreset? _preset = SchedulePreset.twentySlotsTenWeeks;
  int? _daySlot = 1;
  bool _submitting = false;
  bool _scanning = false;
  bool _createdAny = false;
  bool _attemptedSubmit = false;
  bool _dateManuallyEdited = false;
  int _selectionVersion = 0;
  List<OcrTimetableItem> _ocrItems = [];
  int? _selectedOcrIndex;
  String? _error;
  String? _autofilledTerm;

  @override
  void initState() {
    super.initState();
    if (_startDate!.weekday == DateTime.sunday) {
      _startDate = _startDate!.add(const Duration(days: 1));
    }
    _autofilledTerm = academicTermForDate(_startDate!);
    _termController.text = _autofilledTerm!;
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
    var initialDate = _startDate ?? DateTime.now();
    if (initialDate.weekday == DateTime.sunday) {
      initialDate = initialDate.add(const Duration(days: 1));
    }
    if (_preset == SchedulePreset.thirtySlotsThreeWeeks &&
        initialDate.weekday == DateTime.saturday) {
      initialDate = initialDate.add(const Duration(days: 2));
    }
    if (initialDate.isBefore(DateTime(2020))) {
      initialDate = DateTime(2020, 1, 1);
    }
    if (initialDate.isAfter(DateTime(2100, 12, 31))) {
      initialDate = DateTime(2100, 12, 31);
    }
    final selected = await showDatePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100, 12, 31),
      initialDate: initialDate,
      selectableDayPredicate: (date) =>
          date.weekday != DateTime.sunday &&
          (_preset != SchedulePreset.thirtySlotsThreeWeeks ||
              date.weekday != DateTime.saturday),
    );
    if (selected != null) {
      setState(() {
        final usedSuggestion =
            _termController.text.isEmpty ||
            _termController.text == _autofilledTerm;
        _startDate = selected;
        _autofilledTerm = academicTermForDate(selected);
        if (usedSuggestion) _termController.text = _autofilledTerm!;
        _dateManuallyEdited = true;
        _error = null;
      });
    }
  }

  Future<void> _submit() async {
    setState(() => _attemptedSubmit = true);
    if (!_formKey.currentState!.validate()) return;
    final startDate = _startDate;
    final preset = _preset;
    final daySlot = _daySlot;
    if (startDate == null || preset == null || daySlot == null) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      await widget.api.createCourseClass(
        subject: _subjectController.text,
        classCode: _classController.text,
        academicTerm: _termController.text,
        startDate: startDate,
        preset: preset,
        daySlot: daySlot,
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
              content: Text('Đã tạo lớp. Kiểm tra lớp tiếp theo.'),
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
    _formKey = GlobalKey<FormState>();
    _selectedOcrIndex = index;
    _subjectController.text = item.subject;
    _classController.text = item.classCode;
    _preset = switch (item.totalSessions) {
      10 => SchedulePreset.tenSlotsTenWeeks,
      20 => SchedulePreset.twentySlotsTenWeeks,
      30 => SchedulePreset.thirtySlotsThreeWeeks,
      _ => SchedulePreset.twentySlotsTenWeeks,
    };
    _startDate = _suggestedStartDate(item, _preset);
    _autofilledTerm = item.date == null
        ? null
        : academicTermForDate(item.date!);
    _termController.text = _autofilledTerm ?? '';
    final suggestedSlot = item.daySlot;
    _daySlot =
        _preset == SchedulePreset.thirtySlotsThreeWeeks &&
            suggestedSlot != null &&
            item.sessionNumber != null &&
            item.sessionNumber!.isEven
        ? suggestedSlot - 1
        : suggestedSlot;
    if (_daySlot != null &&
        (_daySlot! < 1 ||
            (_preset == SchedulePreset.thirtySlotsThreeWeeks &&
                _daySlot! > 6))) {
      _daySlot = null;
    }
    _attemptedSubmit = false;
    _dateManuallyEdited = false;
    _selectionVersion++;
    _error = null;
  }

  DateTime? _suggestedStartDate(OcrTimetableItem item, SchedulePreset? preset) {
    final observedDate = item.date;
    if (observedDate == null) return null;
    if (preset == SchedulePreset.thirtySlotsThreeWeeks &&
        observedDate.weekday == DateTime.saturday) {
      return null;
    }
    if (preset == null) return observedDate;
    final sessionNumber = item.sessionNumber;
    if (sessionNumber == null ||
        sessionNumber < 1 ||
        sessionNumber > preset.slotCount) {
      return suggestScheduleStartDateFromObserved(
            observedDate: observedDate,
            preset: preset,
          ) ??
          observedDate;
    }
    final inferred = inferScheduleStartDate(
      observedDate: observedDate,
      sessionNumber: sessionNumber,
      preset: preset,
    );
    return inferred.isBefore(DateTime(2020))
        ? (suggestScheduleStartDateFromObserved(
                observedDate: observedDate,
                preset: preset,
              ) ??
              observedDate)
        : inferred;
  }

  Future<void> _scanTimetable() async {
    if (GeminiOcrSettings.apiKey.trim().isEmpty) {
      final controller = TextEditingController();
      final key = await showDialog<String>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Cài đặt quét ảnh'),
          content: TextField(
            controller: controller,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: 'Gemini API key',
              helperText: 'Lưu trên máy này',
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
    final validStartDate =
        _startDate != null &&
        !(_preset == SchedulePreset.thirtySlotsThreeWeeks &&
            _startDate!.weekday == DateTime.saturday);
    final preview = validStartDate && _preset != null
        ? generateSchedule(startDate: _startDate!, preset: _preset!)
        : null;
    return AlertDialog(
      title: const Text('Thêm lớp môn'),
      content: SizedBox(
        width: appDialogWidth(context, 620),
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: AppSpace.sm,
                  runSpacing: AppSpace.sm,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      'Thông tin lớp',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    OutlinedButton.icon(
                      onPressed: _scanning || _submitting
                          ? null
                          : _scanTimetable,
                      icon: _scanning
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.document_scanner_outlined),
                      label: Text(_scanning ? 'Đang đọc ảnh…' : 'Quét ảnh TKB'),
                    ),
                  ],
                ),
                if (_ocrItems.isNotEmpty) ...[
                  const SizedBox(height: AppSpace.md),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(AppSpace.md),
                    decoration: BoxDecoration(
                      color: AppColors.surfaceMuted,
                      borderRadius: BorderRadius.circular(AppRadii.panel),
                      border: Border.all(color: AppColors.border),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Từ ảnh · ${_ocrItems.length} lớp',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: AppSpace.sm),
                        for (var index = 0; index < _ocrItems.length; index++)
                          Padding(
                            padding: const EdgeInsets.only(bottom: AppSpace.xs),
                            child: ListTile(
                              dense: true,
                              selected: index == _selectedOcrIndex,
                              selectedTileColor: AppColors.infoSurface,
                              tileColor: AppColors.surface,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(
                                  AppRadii.control,
                                ),
                                side: const BorderSide(color: AppColors.border),
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
                              subtitle:
                                  _ocrItems[index].sessionNumber == null &&
                                      _ocrItems[index].date == null &&
                                      _ocrItems[index].daySlot == null
                                  ? null
                                  : Text(
                                      [
                                        if (_ocrItems[index].sessionNumber !=
                                            null)
                                          'Buổi ${_ocrItems[index].sessionNumber}',
                                        if (_ocrItems[index].date != null)
                                          DateFormat('dd/MM/yyyy')
                                              .format(_ocrItems[index].date!),
                                        if (_ocrItems[index].daySlot != null)
                                          'Slot ${_ocrItems[index].daySlot}',
                                      ].join(' · '),
                                    ),
                              onTap: _submitting || _scanning
                                  ? null
                                  : () => setState(() => _selectOcrItem(index)),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: AppSpace.lg),
                LayoutBuilder(
                  builder: (context, constraints) {
                    final fieldWidth = constraints.maxWidth < 480
                        ? constraints.maxWidth
                        : (constraints.maxWidth - 12) / 2;
                    return Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      children: [
                        SizedBox(
                          width: fieldWidth,
                          child: TextFormField(
                            controller: _subjectController,
                            textCapitalization: TextCapitalization.characters,
                            decoration: const InputDecoration(
                              labelText: 'Mã môn học',
                            ),
                            validator: _validateCode,
                          ),
                        ),
                        SizedBox(
                          width: fieldWidth,
                          child: TextFormField(
                            controller: _classController,
                            textCapitalization: TextCapitalization.characters,
                            decoration: const InputDecoration(
                              labelText: 'Mã lớp',
                            ),
                            validator: _validateCode,
                          ),
                        ),
                      ],
                    );
                  },
                ),
                const SizedBox(height: AppSpace.md),
                TextFormField(
                  controller: _termController,
                  textCapitalization: TextCapitalization.characters,
                  decoration: const InputDecoration(labelText: 'Học kỳ'),
                  validator: _validateCode,
                ),
                const SizedBox(height: AppSpace.xl),
                Text(
                  'Lịch học',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: AppSpace.md),
                LayoutBuilder(
                  builder: (context, constraints) {
                    final fieldWidth = constraints.maxWidth < 480
                        ? constraints.maxWidth
                        : (constraints.maxWidth - 12) / 2;
                    return Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      children: [
                        SizedBox(
                          width: fieldWidth,
                          child: InkWell(
                            onTap: _submitting || _scanning ? null : _pickDate,
                            borderRadius: BorderRadius.circular(
                              AppRadii.control,
                            ),
                            child: InputDecorator(
                              decoration: InputDecoration(
                                labelText: 'Ngày buổi 1',
                                suffixIcon: const Icon(
                                  Icons.calendar_month_outlined,
                                ),
                                errorText:
                                    _attemptedSubmit && _startDate == null
                                    ? 'Chọn ngày buổi 1'
                                    : null,
                              ),
                              child: Text(
                                _startDate == null
                                    ? 'Chọn ngày'
                                    : DateFormat('dd/MM/yyyy')
                                          .format(_startDate!),
                                style: _startDate == null
                                    ? const TextStyle(
                                        color: AppColors.textMuted,
                                      )
                                    : null,
                              ),
                            ),
                          ),
                        ),
                        SizedBox(
                          width: fieldWidth,
                          child: DropdownButtonFormField<SchedulePreset>(
                            key: ValueKey('preset-$_selectionVersion'),
                            initialValue: _preset,
                            isExpanded: true,
                            decoration: InputDecoration(
                              labelText: 'Số buổi · nhịp học',
                              hintText: 'Chọn lịch học',
                              errorText: _attemptedSubmit && _preset == null
                                  ? 'Chọn lịch học'
                                  : null,
                            ),
                            items:
                                const [
                                      SchedulePreset.twentySlotsTenWeeks,
                                      SchedulePreset.thirtySlotsThreeWeeks,
                                      SchedulePreset.tenSlotsTenWeeks,
                                    ]
                                    .map(
                                      (preset) => DropdownMenuItem(
                                        value: preset,
                                        child: Text(preset.label),
                                      ),
                                    )
                                    .toList(),
                            onChanged: (value) => setState(() {
                              _preset = value;
                              if (!_dateManuallyEdited &&
                                  _selectedOcrIndex != null) {
                                _startDate = _suggestedStartDate(
                                  _ocrItems[_selectedOcrIndex!],
                                  value,
                                );
                              } else if (value ==
                                      SchedulePreset.thirtySlotsThreeWeeks &&
                                  _startDate?.weekday == DateTime.saturday) {
                                _startDate = null;
                              }
                              if (value ==
                                      SchedulePreset.thirtySlotsThreeWeeks &&
                                  _daySlot != null &&
                                  _daySlot! > 6) {
                                _daySlot = null;
                              }
                              _selectionVersion++;
                              _error = null;
                            }),
                          ),
                        ),
                      ],
                    );
                  },
                ),
                const SizedBox(height: AppSpace.md),
                DropdownButtonFormField<int>(
                  key: ValueKey('slot-$_selectionVersion'),
                  initialValue: _daySlot,
                  decoration: InputDecoration(
                    labelText: _preset == SchedulePreset.thirtySlotsThreeWeeks
                        ? 'Slot bắt đầu mỗi ngày'
                        : 'Giờ học (slot)',
                    hintText: 'Chọn slot',
                    errorText: _attemptedSubmit && _daySlot == null
                        ? 'Chọn slot trong ngày'
                        : null,
                  ),
                  items: daySlotDefinitions
                      .where(
                        (slot) =>
                            _preset != SchedulePreset.thirtySlotsThreeWeeks ||
                            slot.number <= 6,
                      )
                      .map(
                        (slot) => DropdownMenuItem(
                          value: slot.number,
                          child: Text(
                            _preset == SchedulePreset.thirtySlotsThreeWeeks
                                ? 'Slot ${slot.number}'
                                : slot.label,
                          ),
                        ),
                      )
                      .toList(),
                  onChanged: (value) => setState(() {
                    _daySlot = value;
                    _error = null;
                  }),
                ),
                if (preview != null) ...[
                  const SizedBox(height: AppSpace.lg),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(AppSpace.lg),
                    decoration: BoxDecoration(
                      color: AppColors.infoSurface,
                      borderRadius: BorderRadius.circular(AppRadii.control),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Lịch dự kiến',
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            color: AppColors.info,
                          ),
                        ),
                        const SizedBox(height: AppSpace.xs),
                        Text(
                          '${DateFormat('dd/MM/yyyy').format(preview.first.date)} – ${DateFormat('dd/MM/yyyy').format(preview.last.date)}',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        Text(
                          _preset == SchedulePreset.thirtySlotsThreeWeeks
                              ? '${preview.length} buổi · 2 slot/ngày Thứ 2–6 · ${_daySlot == null ? 'Chưa chọn slot' : 'Slot $_daySlot–${_daySlot! + 1}'}'
                              : '${preview.length} buổi · ${_daySlot == null ? 'Chưa chọn slot' : 'Slot $_daySlot'}',
                          style: const TextStyle(color: AppColors.textMuted),
                        ),
                        if (_preset == SchedulePreset.thirtySlotsThreeWeeks ||
                            _preset == SchedulePreset.twentySlotsTenWeeks)
                          const Text(
                            'Tổng 45 giờ học',
                            style: TextStyle(color: AppColors.textMuted),
                          ),
                      ],
                    ),
                  ),
                ],
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
          child: Text(_createdAny ? 'Đóng' : 'Hủy'),
        ),
        FilledButton(
          onPressed: _submitting || _scanning ? null : _submit,
          child: Text(_submitting ? 'Đang tạo…' : 'Tạo lớp môn'),
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
