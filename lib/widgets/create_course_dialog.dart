import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../domain/schedule.dart';
import '../services/attendance_api.dart';
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
  DateTime _startDate = DateTime.now();
  SchedulePreset _preset = SchedulePreset.twentySlotsTenWeeks;
  int _daySlot = 1;
  bool _submitting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (_startDate.weekday == DateTime.sunday) {
      _startDate = _startDate.add(const Duration(days: 1));
    }
  }

  @override
  void dispose() {
    _subjectController.dispose();
    _classController.dispose();
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
    if (selected != null) setState(() => _startDate = selected);
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      await widget.api.createCourseClass(
        subject: _subjectController.text,
        classCode: _classController.text,
        startDate: _startDate,
        preset: _preset,
        daySlot: _daySlot,
      );
      if (mounted) Navigator.of(context).pop(true);
    } catch (error) {
      setState(() => _error = 'Không thể tạo môn–lớp: $error');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final preview = generateSchedule(startDate: _startDate, preset: _preset);
    return AlertDialog(
      title: const Text('Tạo môn–lớp'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
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
                        onChanged: (value) => setState(() => _preset = value!),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                DropdownButtonFormField<int>(
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
                  onChanged: (value) => setState(() => _daySlot = value!),
                ),
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
          onPressed: _submitting ? null : () => Navigator.pop(context),
          child: const Text('Hủy'),
        ),
        FilledButton(
          onPressed: _submitting ? null : _submit,
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
