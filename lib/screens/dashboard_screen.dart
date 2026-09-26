import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../domain/class_overview.dart';
import '../domain/models.dart';
import '../domain/schedule.dart';
import '../services/attendance_api.dart';
import '../theme/app_theme.dart';
import '../widgets/app_ui.dart';
import '../widgets/create_course_dialog.dart';
import 'session_screen.dart';
import 'roster_import_screen.dart';
import 'class_overview_screen.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key, required this.api, required this.user});

  final AttendanceApi api;
  final User user;

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  late Future<List<TodaySlot>> _slots;
  late Future<AttendanceSession?> _activeSession;
  bool _showWeek = false;
  bool _showRoster = false;
  bool _showOverview = false;
  bool _movingScheduleSlot = false;
  late DateTime _weekStart;

  @override
  void initState() {
    super.initState();
    _weekStart = startOfWeek(DateTime.now());
    _refresh();
    unawaited(widget.api.syncPendingCheckIns().catchError((_) {}));
    if (kDebugMode) {
      unawaited(
        widget.api
            .createTestCourseClassNow()
            .then((_) {
              if (mounted) _refresh();
            })
            .catchError((_) {}),
      );
    }
  }

  void _refresh() {
    setState(() {
      _slots = _showWeek
          ? widget.api.getWeekSlots(_weekStart)
          : widget.api.getTodaySlots(DateTime.now());
      _activeSession = widget.api.getActiveAttendance();
    });
  }

  void _selectScheduleView(bool showWeek) {
    if (!_showRoster && !_showOverview && _showWeek == showWeek) return;
    _showRoster = false;
    _showOverview = false;
    _showWeek = showWeek;
    if (showWeek) _weekStart = startOfWeek(DateTime.now());
    _refresh();
  }

  void _openWeekSchedule() {
    _showRoster = false;
    _showOverview = false;
    _showWeek = true;
    _weekStart = startOfWeek(DateTime.now());
    _refresh();
  }

  void _changeWeek(int offset) {
    _weekStart = _weekStart.add(Duration(days: offset * 7));
    _refresh();
  }

  Future<void> _createCourse() async {
    final created = await showDialog<bool>(
      context: context,
      builder: (_) => CreateCourseDialog(api: widget.api),
    );
    if (created == true) _refresh();
  }

  Future<void> _createTestScheduleNow() async {
    try {
      await widget.api.createTestCourseClassNow();
      if (!mounted) return;
      _weekStart = startOfWeek(DateTime.now());
      _refresh();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Đã đồng bộ PRM393 với 5 slot hôm nay. Bạn có thể bắt đầu điểm danh ngay.',
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Không thể tạo lịch thử: $error')));
    }
  }

  Future<void> _start(TodaySlot slot) async {
    final config =
        await showDialog<({int rotation, int validity, int checkoutRotation})>(
          context: context,
          builder: (_) => const _SessionConfigDialog(),
        );
    if (config == null || !mounted) return;

    try {
      final session = await widget.api.startAttendance(
        slot: slot,
        rotationSeconds: config.rotation,
        validitySeconds: config.validity,
        checkoutRotationSeconds: config.checkoutRotation,
      );
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => SessionScreen(api: widget.api, session: session),
        ),
      );
      if (mounted) _refresh();
    } catch (error) {
      if (!mounted) return;
      AttendanceSession? active;
      Object? verificationError;
      try {
        active = await widget.api.getActiveAttendance();
      } catch (readError) {
        verificationError = readError;
      }
      if (!mounted) return;
      _refresh();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            active != null
                ? 'Phiên đã được tạo nhưng chưa hoàn tất thiết lập. '
                      'Nhấn "Mở lại phiên" để tiếp tục: $error'
                : verificationError != null
                ? 'Chưa xác minh được phiên đã mở hay chưa. '
                      'Hãy làm mới và kiểm tra phiên đang hoạt động: $verificationError'
                : 'Không thể bắt đầu điểm danh: $error',
          ),
        ),
      );
    }
  }

  Future<void> _resumeActiveSession() async {
    try {
      final session = await widget.api.resumeActiveAttendance();
      if (!mounted) return;
      if (session == null) {
        _refresh();
        return;
      }
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => SessionScreen(api: widget.api, session: session),
        ),
      );
      if (mounted) _refresh();
    } catch (error) {
      if (!mounted) return;
      _refresh();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Chưa thể hoàn tất thiết lập phiên: $error')),
      );
    }
  }

  Widget _buildScheduleList(List<TodaySlot> slots) {
    if (!_showWeek) {
      return ListView.separated(
        itemCount: slots.length,
        separatorBuilder: (_, _) => const SizedBox(height: 12),
        itemBuilder: (context, index) => Align(
          alignment: Alignment.topLeft,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1200),
            child: _buildSlotCard(slots[index]),
          ),
        ),
      );
    }

    return _buildWeekGrid(slots);
  }

  Widget _buildWeekGrid(List<TodaySlot> slots) {
    final dates = List.generate(
      7,
      (index) => _weekStart.add(Duration(days: index)),
    );
    final includeUnassigned = slots.any((slot) => slot.daySlot == null);
    final rowSlots = <int?>[
      ...daySlotDefinitions.map((slot) => slot.number),
      if (includeUnassigned) null,
    ];
    final columnWidths = <int, TableColumnWidth>{
      0: const FixedColumnWidth(132),
      for (var index = 1; index <= 7; index++)
        index: const FixedColumnWidth(168),
    };

    return Column(
      children: [
        Container(
          width: double.infinity,
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: AppColors.successSurface,
            borderRadius: BorderRadius.circular(10),
          ),
          child: const Row(
            children: [
              Icon(Icons.drag_indicator, color: AppColors.success, size: 20),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Kéo slot tương lai vào ô trống để đổi ngày/giờ. Slot hôm nay và đã qua bị khóa; nhấn slot đã qua để xem điểm danh.',
                  style: TextStyle(color: AppColors.success, fontSize: 13),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Table(
                columnWidths: columnWidths,
                border: TableBorder.all(color: AppColors.border),
                defaultVerticalAlignment: TableCellVerticalAlignment.top,
                children: [
                  TableRow(
                    decoration: const BoxDecoration(color: AppColors.primary),
                    children: [
                      _weekHeaderCell('Slot trong ngày', null),
                      for (final date in dates)
                        _weekHeaderCell(_weekdayLabel(date.weekday), date),
                    ],
                  ),
                  for (final daySlot in rowSlots)
                    TableRow(
                      decoration: BoxDecoration(
                        color: daySlot == null
                            ? AppColors.warningSurface
                            : Colors.white,
                      ),
                      children: [
                        _daySlotCell(daySlot),
                        for (final date in dates)
                          _weekScheduleCell(
                            slots
                                .where(
                                  (slot) =>
                                      slot.daySlot == daySlot &&
                                      slot.date == _isoDate(date),
                                )
                                .toList(),
                            date,
                            daySlot,
                          ),
                      ],
                    ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _weekHeaderCell(String label, DateTime? date) {
    final isToday = date != null && isSameDate(date, DateTime.now());
    return Container(
      constraints: const BoxConstraints(minHeight: 70),
      color: isToday ? AppColors.primary : null,
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w700,
            ),
          ),
          if (date != null) ...[
            const SizedBox(height: 3),
            Text(
              DateFormat('dd/MM').format(date),
              style: const TextStyle(color: AppColors.infoSurface),
            ),
          ],
        ],
      ),
    );
  }

  Widget _daySlotCell(int? daySlot) {
    final definition = daySlot == null
        ? null
        : daySlotDefinitions.firstWhere((item) => item.number == daySlot);
    return Container(
      constraints: const BoxConstraints(minHeight: 112),
      padding: const EdgeInsets.all(12),
      color: AppColors.surfaceMuted,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            daySlot == null ? 'Chưa xếp slot' : 'Slot $daySlot',
            style: const TextStyle(fontWeight: FontWeight.w800),
          ),
          if (definition?.timeRange != null) ...[
            const SizedBox(height: 4),
            Text(
              definition!.timeRange!,
              style: const TextStyle(fontSize: 12, color: AppColors.textMuted),
            ),
          ],
          if (daySlot == null) ...[
            const SizedBox(height: 4),
            const Text(
              'Dữ liệu cũ',
              style: TextStyle(fontSize: 12, color: AppColors.warning),
            ),
          ],
        ],
      ),
    );
  }

  Widget _weekScheduleCell(List<TodaySlot> slots, DateTime date, int? daySlot) {
    final targetDate = _isoDate(date);
    final today = _isoDate(DateTime.now());
    final canReceive =
        daySlot != null &&
        targetDate.compareTo(today) > 0 &&
        date.weekday != DateTime.sunday &&
        !_movingScheduleSlot;
    return DragTarget<TodaySlot>(
      onWillAcceptWithDetails: (details) {
        if (!canReceive) return false;
        return !slots.any(
          (occupied) =>
              occupied.courseClassId != details.data.courseClassId ||
              occupied.slot != details.data.slot,
        );
      },
      onAcceptWithDetails: (details) =>
          unawaited(_moveScheduleSlot(details.data, date, daySlot)),
      builder: (context, candidateData, rejectedData) {
        final isValidHover = candidateData.isNotEmpty;
        final isRejectedHover = rejectedData.isNotEmpty;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          constraints: const BoxConstraints(minHeight: 112),
          decoration: BoxDecoration(
            color: isValidHover
                ? AppColors.successSurface
                : isRejectedHover
                ? AppColors.errorSurface
                : isSameDate(date, DateTime.now())
                ? AppColors.successSurface
                : null,
            border: Border.all(
              color: isValidHover
                  ? AppColors.success
                  : isRejectedHover
                  ? AppColors.error
                  : Colors.transparent,
              width: isValidHover || isRejectedHover ? 2 : 0,
            ),
          ),
          padding: const EdgeInsets.all(8),
          child: slots.isEmpty
              ? Text(
                  isValidHover ? 'Thả để chuyển slot' : '–',
                  style: TextStyle(
                    color: isValidHover
                        ? AppColors.success
                        : AppColors.textMuted,
                    fontWeight: isValidHover ? FontWeight.w700 : null,
                  ),
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (var index = 0; index < slots.length; index++) ...[
                      if (index > 0) const SizedBox(height: 8),
                      _weekCourseCard(slots[index], date),
                    ],
                  ],
                ),
        );
      },
    );
  }

  Widget _weekCourseCard(TodaySlot slot, DateTime date) {
    final canStart = isSameDate(date, DateTime.now());
    final today = DateTime.now();
    final normalizedToday = DateTime(today.year, today.month, today.day);
    final normalizedDate = DateTime(date.year, date.month, date.day);
    final isPast = normalizedDate.isBefore(normalizedToday);
    final canMove = !canStart && !isPast && !_movingScheduleSlot;
    final total = slot.slotCount > 0 ? '/${slot.slotCount}' : '';
    final card = Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: isPast ? () => _showPastSlotAttendance(slot) : null,
        borderRadius: BorderRadius.circular(8),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.white,
            border: Border.all(
              color: canStart ? AppColors.success : AppColors.border,
            ),
            borderRadius: BorderRadius.circular(8),
            boxShadow: const [
              BoxShadow(
                color: Color(0x11000000),
                blurRadius: 4,
                offset: Offset(0, 2),
              ),
            ],
          ),
          child: Padding(
            padding: const EdgeInsets.all(9),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        slot.subject,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: AppColors.info,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    if (canMove)
                      const Icon(
                        Icons.drag_indicator,
                        size: 17,
                        color: AppColors.textMuted,
                      )
                    else if (isPast)
                      const Icon(
                        Icons.insights_outlined,
                        size: 16,
                        color: AppColors.success,
                      ),
                  ],
                ),
                Text(
                  slot.classCode,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12),
                ),
                const SizedBox(height: 5),
                Text(
                  'Buổi ${slot.slot}$total',
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.textMuted,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (canStart) ...[
                  const SizedBox(height: 7),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        visualDensity: VisualDensity.compact,
                      ),
                      onPressed: () => _start(slot),
                      icon: const Icon(Icons.play_arrow, size: 17),
                      label: const Text('Điểm danh'),
                    ),
                  ),
                ] else if (isPast) ...[
                  const SizedBox(height: 6),
                  const Text(
                    'Nhấn để xem điểm danh',
                    style: TextStyle(
                      fontSize: 10,
                      color: AppColors.success,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ] else ...[
                  const SizedBox(height: 6),
                  const Text(
                    'Kéo để đổi lịch',
                    style: TextStyle(fontSize: 10, color: AppColors.textMuted),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
    if (!canMove) return card;
    return Draggable<TodaySlot>(
      data: slot,
      maxSimultaneousDrags: _movingScheduleSlot ? 0 : 1,
      feedback: Material(
        color: Colors.transparent,
        child: SizedBox(width: 150, child: card),
      ),
      childWhenDragging: Opacity(opacity: 0.28, child: card),
      child: card,
    );
  }

  Future<void> _moveScheduleSlot(
    TodaySlot slot,
    DateTime targetDate,
    int? targetDaySlot,
  ) async {
    if (_movingScheduleSlot || targetDaySlot == null) return;
    setState(() => _movingScheduleSlot = true);
    try {
      await widget.api.moveScheduledSlot(
        courseClassId: slot.courseClassId,
        slotNumber: slot.slot,
        targetDate: targetDate,
        targetDaySlot: targetDaySlot,
      );
      if (!mounted) return;
      _refresh();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Đã chuyển buổi ${slot.slot} sang ${DateFormat('dd/MM/yyyy').format(targetDate)} · Slot $targetDaySlot.',
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Không thể đổi lịch: $error')));
    } finally {
      if (mounted) setState(() => _movingScheduleSlot = false);
    }
  }

  void _showPastSlotAttendance(TodaySlot scheduledSlot) {
    final overviewFuture = widget.api.getCourseOverview(
      scheduledSlot.courseClassId,
    );
    showDialog<void>(
      context: context,
      builder: (dialogContext) => FutureBuilder<CourseOverview>(
        future: overviewFuture,
        builder: (context, snapshot) {
          final title = Text(
            '${scheduledSlot.subject} · ${scheduledSlot.classCode} · Buổi ${scheduledSlot.slot}',
          );
          if (snapshot.connectionState == ConnectionState.waiting) {
            return AlertDialog(
              title: title,
              content: const SizedBox(
                width: 540,
                height: 220,
                child: Center(child: CircularProgressIndicator()),
              ),
            );
          }
          if (snapshot.hasError) {
            return AlertDialog(
              title: title,
              content: Text('Không tải được điểm danh: ${snapshot.error}'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: const Text('Đóng'),
                ),
              ],
            );
          }

          final overview = snapshot.requireData;
          CourseSlotOverview? selectedSlot;
          for (final item in overview.slots) {
            if (item.number == scheduledSlot.slot) {
              selectedSlot = item;
              break;
            }
          }
          if (selectedSlot == null) {
            return AlertDialog(
              title: title,
              content: const Text('Không tìm thấy dữ liệu của buổi học này.'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: const Text('Đóng'),
                ),
              ],
            );
          }
          final reportSlot = selectedSlot;

          final students = overview.students
              .where((student) => student.active)
              .toList();
          final presentCount = students
              .where(
                (student) =>
                    overview.statusFor(student.id, reportSlot) ==
                    AttendanceStatus.present,
              )
              .length;
          final absentCount = students
              .where(
                (student) =>
                    overview.statusFor(student.id, reportSlot) ==
                    AttendanceStatus.absent,
              )
              .length;
          final excusedCount = students
              .where(
                (student) =>
                    overview.statusFor(student.id, reportSlot) ==
                    AttendanceStatus.excused,
              )
              .length;

          return AlertDialog(
            title: title,
            content: SizedBox(
              width: 620,
              height: 520,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Ngày học ${DateFormat('dd/MM/yyyy').format(DateTime.parse(scheduledSlot.date))}',
                    style: const TextStyle(color: AppColors.textMuted),
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      Expanded(
                        child: _AttendanceSummaryCard(
                          label: 'Tổng SV',
                          count: students.length,
                          color: AppColors.info,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _AttendanceSummaryCard(
                          label: 'Có mặt',
                          count: presentCount,
                          color: AppColors.success,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _AttendanceSummaryCard(
                          label: 'Vắng',
                          count: absentCount,
                          color: AppColors.error,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _AttendanceSummaryCard(
                          label: 'Có phép',
                          count: excusedCount,
                          color: AppColors.info,
                        ),
                      ),
                    ],
                  ),
                  if (!reportSlot.hasOpened) ...[
                    const SizedBox(height: 12),
                    const Text(
                      'Buổi này chưa mở điểm danh nên chưa có thống kê vắng mặt.',
                      style: TextStyle(color: AppColors.warning),
                    ),
                  ],
                  const SizedBox(height: 12),
                  const Text(
                    'Chi tiết sinh viên',
                    style: TextStyle(fontWeight: FontWeight.w800),
                  ),
                  const Divider(height: 16),
                  Expanded(
                    child: students.isEmpty
                        ? const Center(
                            child: Text('Lớp chưa có sinh viên hoạt động.'),
                          )
                        : ListView.separated(
                            itemCount: students.length,
                            separatorBuilder: (_, _) =>
                                const Divider(height: 1),
                            itemBuilder: (context, index) {
                              final student = students[index];
                              final status = overview.statusFor(
                                student.id,
                                reportSlot,
                              );
                              final entry = overview.entryFor(
                                student.id,
                                reportSlot.number,
                              );
                              final detail = <String>[
                                if (student.studentCode.isNotEmpty)
                                  student.studentCode,
                                student.email,
                                if (entry?.checkedInAt != null)
                                  'Lúc ${DateFormat('HH:mm:ss').format(entry!.checkedInAt!)}',
                                if (entry?.source == 'teacher')
                                  'Cập nhật bởi giảng viên',
                              ].join(' · ');
                              return ListTile(
                                dense: true,
                                contentPadding: EdgeInsets.zero,
                                leading: AppAttendanceBadge(
                                  status: status,
                                  iconOnly: true,
                                  source: entry?.source,
                                ),
                                title: Text(
                                  student.displayName,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                subtitle: Text(
                                  detail,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                trailing: AppAttendanceBadge(status: status),
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Đóng'),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildSlotCard(TodaySlot slot) {
    final slotDate = DateTime.tryParse(slot.date);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final canStart = slotDate != null && isSameDate(slotDate, today);
    final isPast = slotDate != null && slotDate.isBefore(today);
    final total = slot.slotCount > 0 ? '/${slot.slotCount}' : '';
    final daySlot = slot.daySlot == null ? '?' : '${slot.daySlot}';
    final action = FilledButton.icon(
      onPressed: canStart ? () => _start(slot) : null,
      icon: Icon(canStart ? Icons.play_arrow : Icons.schedule),
      label: Text(
        canStart
            ? 'Bắt đầu điểm danh'
            : isPast
            ? 'Đã qua ngày học'
            : 'Chưa đến ngày học',
      ),
    );
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpace.lg),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final information = Row(
              children: [
                Container(
                  width: 76,
                  height: 62,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: AppColors.infoSurface,
                    borderRadius: BorderRadius.circular(AppRadii.control),
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        'SLOT $daySlot',
                        style: const TextStyle(
                          color: AppColors.primary,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const Text(
                        'trong ngày',
                        style: TextStyle(
                          fontSize: 11,
                          color: AppColors.textMuted,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: AppSpace.lg),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${slot.subject} · ${slot.classCode}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: AppSpace.xs),
                      Text(
                        'Buổi ${slot.slot}$total · ${slot.date}',
                        style: const TextStyle(color: AppColors.textMuted),
                      ),
                    ],
                  ),
                ),
              ],
            );
            if (constraints.maxWidth < 620) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  information,
                  const SizedBox(height: AppSpace.md),
                  action,
                ],
              );
            }
            return Row(
              children: [
                Expanded(child: information),
                const SizedBox(width: AppSpace.lg),
                action,
              ],
            );
          },
        ),
      ),
    );
  }

  String _weekdayLabel(int weekday) => switch (weekday) {
    DateTime.monday => 'Thứ Hai',
    DateTime.tuesday => 'Thứ Ba',
    DateTime.wednesday => 'Thứ Tư',
    DateTime.thursday => 'Thứ Năm',
    DateTime.friday => 'Thứ Sáu',
    DateTime.saturday => 'Thứ Bảy',
    DateTime.sunday => 'Chủ nhật',
    _ => '',
  };

  String _isoDate(DateTime value) =>
      '${value.year.toString().padLeft(4, '0')}-'
      '${value.month.toString().padLeft(2, '0')}-'
      '${value.day.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: LayoutBuilder(
        builder: (context, constraints) {
          final compactNavigation = constraints.maxWidth < 1080;
          return Row(
            children: [
              Container(
                width: compactNavigation ? 76 : 228,
                decoration: const BoxDecoration(
                  color: AppColors.surface,
                  border: Border(right: BorderSide(color: AppColors.border)),
                ),
                padding: EdgeInsets.fromLTRB(
                  compactNavigation ? 10 : 16,
                  24,
                  compactNavigation ? 10 : 16,
                  16,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(
                          Icons.qr_code_2,
                          color: AppColors.primary,
                          size: 30,
                        ),
                        if (!compactNavigation) ...[
                          const SizedBox(width: 10),
                          const Expanded(
                            child: Text(
                              'FAP Attendance',
                              style: TextStyle(
                                color: AppColors.text,
                                fontWeight: FontWeight.w700,
                                fontSize: 16,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: AppSpace.xxl),
                    _SideItem(
                      icon: Icons.today_outlined,
                      label: 'Lịch hôm nay',
                      compact: compactNavigation,
                      selected: !_showRoster && !_showOverview && !_showWeek,
                      onTap: () => _selectScheduleView(false),
                    ),
                    const SizedBox(height: 8),
                    _SideItem(
                      icon: Icons.date_range_outlined,
                      label: 'Lịch trong tuần',
                      compact: compactNavigation,
                      selected: !_showRoster && !_showOverview && _showWeek,
                      onTap: () => _selectScheduleView(true),
                    ),
                    const SizedBox(height: 8),
                    _SideItem(
                      icon: Icons.analytics_outlined,
                      label: 'Tổng quan lớp',
                      compact: compactNavigation,
                      selected: _showOverview,
                      onTap: () => setState(() {
                        _showOverview = true;
                        _showRoster = false;
                      }),
                    ),
                    const SizedBox(height: 8),
                    _SideItem(
                      icon: Icons.groups_outlined,
                      label: 'Danh sách sinh viên',
                      compact: compactNavigation,
                      selected: _showRoster,
                      onTap: () => setState(() {
                        _showRoster = true;
                        _showOverview = false;
                      }),
                    ),
                    const Spacer(),
                    const Divider(),
                    if (compactNavigation)
                      IconButton(
                        tooltip:
                            '${widget.user.email ?? 'Giảng viên'} · Đăng xuất',
                        onPressed: () => FirebaseAuth.instance.signOut(),
                        icon: const Icon(Icons.logout_outlined),
                      )
                    else ...[
                      Text(
                        widget.user.email ?? 'Giảng viên',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: AppColors.textMuted),
                      ),
                      const SizedBox(height: AppSpace.sm),
                      OutlinedButton.icon(
                        onPressed: () => FirebaseAuth.instance.signOut(),
                        icon: const Icon(Icons.logout_outlined, size: 18),
                        label: const Text('Đăng xuất'),
                      ),
                    ],
                  ],
                ),
              ),
              Expanded(
                child: _showOverview
                    ? ClassOverviewScreen(
                        api: widget.api,
                        onOpenSchedule: _openWeekSchedule,
                      )
                    : _showRoster
                    ? RosterImportScreen(api: widget.api)
                    : Padding(
                        padding: const EdgeInsets.all(AppSpace.xl),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            AppPageHeader(
                              title: _showWeek
                                  ? 'Lịch trong tuần'
                                  : 'Lịch hôm nay',
                              subtitle: _showWeek
                                  ? '${DateFormat('dd/MM/yyyy').format(_weekStart)} – '
                                        '${DateFormat('dd/MM/yyyy').format(endOfWeek(_weekStart))}'
                                  : 'Hôm nay, ${DateFormat('dd/MM/yyyy').format(DateTime.now())}',
                              actions: [
                                if (_showWeek) ...[
                                  IconButton(
                                    tooltip: 'Tuần trước',
                                    onPressed: () => _changeWeek(-1),
                                    icon: const Icon(Icons.chevron_left),
                                  ),
                                  TextButton(
                                    onPressed: () {
                                      _weekStart = startOfWeek(DateTime.now());
                                      _refresh();
                                    },
                                    child: const Text('Tuần này'),
                                  ),
                                  IconButton(
                                    tooltip: 'Tuần sau',
                                    onPressed: () => _changeWeek(1),
                                    icon: const Icon(Icons.chevron_right),
                                  ),
                                ],
                                IconButton(
                                  tooltip: 'Làm mới',
                                  onPressed: _refresh,
                                  icon: const Icon(Icons.refresh),
                                ),
                                IconButton.filledTonal(
                                  tooltip: 'Đồng bộ lịch test PRM393 hôm nay',
                                  onPressed: _createTestScheduleNow,
                                  icon: const Icon(Icons.science_outlined),
                                ),
                                FilledButton.icon(
                                  onPressed: _createCourse,
                                  icon: const Icon(Icons.add),
                                  label: const Text('Tạo môn–lớp'),
                                ),
                              ],
                            ),
                            const SizedBox(height: AppSpace.xl),
                            if (!widget.api.isSheetSyncConfigured) ...[
                              const AppNotice(
                                message:
                                    'Chưa cấu hình Apps Script: lượt điểm danh vẫn lưu '
                                    'trong Firestore nhưng chưa được chép sang Google Sheets.',
                                tone: AppTone.warning,
                              ),
                              const SizedBox(height: AppSpace.lg),
                            ],
                            FutureBuilder<AttendanceSession?>(
                              future: _activeSession,
                              builder: (context, snapshot) {
                                if (snapshot.hasError) {
                                  return Padding(
                                    padding: const EdgeInsets.only(
                                      bottom: AppSpace.lg,
                                    ),
                                    child: AppNotice(
                                      tone: AppTone.warning,
                                      message:
                                          'Chưa tải được trạng thái phiên: ${snapshot.error}',
                                      action: TextButton(
                                        onPressed: _refresh,
                                        child: const Text('Thử lại'),
                                      ),
                                    ),
                                  );
                                }
                                final session = snapshot.data;
                                if (session == null) {
                                  return const SizedBox.shrink();
                                }
                                return Padding(
                                  padding: const EdgeInsets.only(
                                    bottom: AppSpace.lg,
                                  ),
                                  child: AppNotice(
                                    tone: AppTone.success,
                                    icon: Icons.radio_button_checked,
                                    message:
                                        'Phiên đang hoạt động · '
                                        '${session.subject} · ${session.classCode} · '
                                        'Buổi ${session.slot}${session.slotCount > 0 ? '/${session.slotCount}' : ''}'
                                        '${session.daySlot == null ? '' : ' · Slot ${session.daySlot} trong ngày'}',
                                    action: TextButton.icon(
                                      onPressed: _resumeActiveSession,
                                      icon: const Icon(Icons.open_in_new),
                                      label: const Text('Mở lại phiên'),
                                    ),
                                  ),
                                );
                              },
                            ),
                            Expanded(
                              child: FutureBuilder<List<TodaySlot>>(
                                future: _slots,
                                builder: (context, snapshot) {
                                  if (snapshot.connectionState ==
                                      ConnectionState.waiting) {
                                    return const Center(
                                      child: CircularProgressIndicator(),
                                    );
                                  }
                                  if (snapshot.hasError) {
                                    return AppEmptyState(
                                      icon: Icons.cloud_off_outlined,
                                      title: 'Không tải được lịch',
                                      description: '${snapshot.error}',
                                      action: TextButton.icon(
                                        onPressed: _refresh,
                                        icon: const Icon(Icons.refresh),
                                        label: const Text('Thử lại'),
                                      ),
                                    );
                                  }
                                  final slots = snapshot.data ?? [];
                                  if (slots.isEmpty) {
                                    return AppEmptyState(
                                      icon: Icons.event_available_outlined,
                                      title: _showWeek
                                          ? 'Tuần này chưa có slot nào'
                                          : 'Hôm nay chưa có slot nào',
                                      description: 'Tạo môn–lớp mới hoặc kiểm tra lại ngày bắt đầu.',
                                      action: FilledButton.icon(
                                        onPressed: _createCourse,
                                        icon: const Icon(Icons.add),
                                        label: const Text('Tạo môn–lớp'),
                                      ),
                                    );
                                  }
                                  return _buildScheduleList(slots);
                                },
                              ),
                            ),
                          ],
                        ),
                      ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _SessionConfigDialog extends StatefulWidget {
  const _SessionConfigDialog();

  @override
  State<_SessionConfigDialog> createState() => _SessionConfigDialogState();
}

class _SessionConfigDialogState extends State<_SessionConfigDialog> {
  final _formKey = GlobalKey<FormState>();
  final _rotation = TextEditingController(text: '5');
  final _validity = TextEditingController(text: '60');
  final _checkoutRotation = TextEditingController(text: '30');

  @override
  void dispose() {
    _rotation.dispose();
    _validity.dispose();
    _checkoutRotation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Cấu hình điểm danh'),
      content: SizedBox(
        width: 430,
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: _rotation,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Đổi QR sau mỗi',
                  suffixText: 'giây',
                ),
                validator: (value) => _validateSeconds(value, 1, 60),
              ),
              const SizedBox(height: 14),
              TextFormField(
                controller: _validity,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Mỗi QR có hiệu lực',
                  suffixText: 'giây',
                ),
                validator: (value) => _validateSeconds(value, 2, 120),
              ),
              const SizedBox(height: 14),
              TextFormField(
                controller: _checkoutRotation,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Đổi checkout code sau mỗi',
                  suffixText: 'giây',
                  helperText:
                      'Code 5 ký tự được tạo mới tự động theo chu kỳ này.',
                  prefixIcon: Icon(Icons.key_rounded),
                ),
                validator: (value) => _validateSeconds(value, 10, 3600),
              ),
              const SizedBox(height: 12),
              const Text(
                'Sinh viên cần đăng nhập và nhập checkout code trước khi QR hết hạn.',
                style: TextStyle(color: AppColors.textMuted),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Hủy'),
        ),
        FilledButton(
          onPressed: () {
            if (!_formKey.currentState!.validate()) return;
            final rotation = int.parse(_rotation.text);
            final validity = int.parse(_validity.text);
            if (validity < rotation) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text(
                    'Thời hạn QR phải lớn hơn hoặc bằng chu kỳ đổi QR.',
                  ),
                ),
              );
              return;
            }
            Navigator.pop(context, (
              rotation: rotation,
              validity: validity,
              checkoutRotation: int.parse(_checkoutRotation.text),
            ));
          },
          child: const Text('Bắt đầu'),
        ),
      ],
    );
  }

  String? _validateSeconds(String? value, int min, int max) {
    final number = int.tryParse(value ?? '');
    return number == null || number < min || number > max
        ? 'Nhập số từ $min đến $max'
        : null;
  }
}

class _SideItem extends StatelessWidget {
  const _SideItem({
    required this.icon,
    required this.label,
    required this.onTap,
    required this.compact,
    this.selected = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool compact;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final foreground = selected ? AppColors.primary : AppColors.textMuted;
    return Tooltip(
      message: label,
      child: Material(
        color: selected ? AppColors.infoSurface : Colors.transparent,
        borderRadius: BorderRadius.circular(AppRadii.control),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(AppRadii.control),
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: compact ? 0 : 12,
              vertical: 11,
            ),
            child: Row(
              mainAxisAlignment: compact
                  ? MainAxisAlignment.center
                  : MainAxisAlignment.start,
              children: [
                Icon(icon, color: foreground, size: 20),
                if (!compact) ...[
                  const SizedBox(width: 12),
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: foreground,
                        fontWeight: selected
                            ? FontWeight.w700
                            : FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _AttendanceSummaryCard extends StatelessWidget {
  const _AttendanceSummaryCard({
    required this.label,
    required this.count,
    required this.color,
  });

  final String label;
  final int count;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.18)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$count',
            style: TextStyle(
              color: color,
              fontSize: 22,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: color, fontSize: 11),
          ),
        ],
      ),
    );
  }
}
