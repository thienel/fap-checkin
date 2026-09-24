import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../domain/class_overview.dart';
import '../domain/models.dart';
import '../domain/schedule.dart';
import '../services/attendance_api.dart';
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
    final config = await showDialog<
      ({int rotation, int validity, int checkoutRotation})
    >(
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Không thể bắt đầu điểm danh: $error')),
      );
    }
  }

  Widget _buildScheduleList(List<TodaySlot> slots) {
    if (!_showWeek) {
      return ListView.separated(
        itemCount: slots.length,
        separatorBuilder: (_, _) => const SizedBox(height: 12),
        itemBuilder: (context, index) => _buildSlotCard(slots[index]),
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
            color: const Color(0xFFEAF5F2),
            borderRadius: BorderRadius.circular(10),
          ),
          child: const Row(
            children: [
              Icon(Icons.drag_indicator, color: Color(0xFF167052), size: 20),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Kéo slot tương lai vào ô trống để đổi ngày/giờ. Slot hôm nay và đã qua bị khóa; nhấn slot đã qua để xem điểm danh.',
                  style: TextStyle(color: Color(0xFF245F58), fontSize: 13),
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
                border: TableBorder.all(color: const Color(0xFFD8E2E5)),
                defaultVerticalAlignment: TableCellVerticalAlignment.top,
                children: [
                  TableRow(
                    decoration: const BoxDecoration(color: Color(0xFF245F82)),
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
                            ? const Color(0xFFFFF7E3)
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
      color: isToday ? const Color(0xFF177B72) : null,
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
              style: const TextStyle(color: Color(0xFFD8EAF2)),
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
      color: const Color(0xFFF2F6F7),
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
              style: const TextStyle(fontSize: 12, color: Color(0xFF5C7077)),
            ),
          ],
          if (daySlot == null) ...[
            const SizedBox(height: 4),
            const Text(
              'Dữ liệu cũ',
              style: TextStyle(fontSize: 12, color: Color(0xFF8A6814)),
            ),
          ],
        ],
      ),
    );
  }

  Widget _weekScheduleCell(
    List<TodaySlot> slots,
    DateTime date,
    int? daySlot,
  ) {
    final targetDate = _isoDate(date);
    final today = _isoDate(DateTime.now());
    final canReceive = daySlot != null &&
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
      onAcceptWithDetails: (details) => unawaited(
        _moveScheduleSlot(details.data, date, daySlot),
      ),
      builder: (context, candidateData, rejectedData) {
        final isValidHover = candidateData.isNotEmpty;
        final isRejectedHover = rejectedData.isNotEmpty;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          constraints: const BoxConstraints(minHeight: 112),
          decoration: BoxDecoration(
            color: isValidHover
                ? const Color(0xFFD9F3E8)
                : isRejectedHover
                ? const Color(0xFFFFE8E8)
                : isSameDate(date, DateTime.now())
                ? const Color(0xFFF1FBF8)
                : null,
            border: Border.all(
              color: isValidHover
                  ? const Color(0xFF329C72)
                  : isRejectedHover
                  ? const Color(0xFFD66A6A)
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
                        ? const Color(0xFF167052)
                        : const Color(0xFF9AABAF),
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
              color: canStart
                  ? const Color(0xFF79C9B3)
                  : const Color(0xFFC9D6DA),
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
                          color: Color(0xFF17658C),
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    if (canMove)
                      const Icon(
                        Icons.drag_indicator,
                        size: 17,
                        color: Color(0xFF779099),
                      )
                    else if (isPast)
                      const Icon(
                        Icons.insights_outlined,
                        size: 16,
                        color: Color(0xFF167052),
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
                    color: Color(0xFF52666D),
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
                      color: Color(0xFF167052),
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ] else ...[
                  const SizedBox(height: 6),
                  const Text(
                    'Kéo để đổi lịch',
                    style: TextStyle(fontSize: 10, color: Color(0xFF71858B)),
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Không thể đổi lịch: $error')),
      );
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
                    style: const TextStyle(color: Color(0xFF64748B)),
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      Expanded(
                        child: _AttendanceSummaryCard(
                          label: 'Tổng SV',
                          count: students.length,
                          color: const Color(0xFF1C6A85),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _AttendanceSummaryCard(
                          label: 'Có mặt',
                          count: presentCount,
                          color: const Color(0xFF167052),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _AttendanceSummaryCard(
                          label: 'Vắng',
                          count: absentCount,
                          color: const Color(0xFFB5473C),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _AttendanceSummaryCard(
                          label: 'Có phép',
                          count: excusedCount,
                          color: const Color(0xFF7C3AED),
                        ),
                      ),
                    ],
                  ),
                  if (!reportSlot.hasOpened) ...[
                    const SizedBox(height: 12),
                    const Text(
                      'Buổi này chưa mở điểm danh nên chưa có thống kê vắng mặt.',
                      style: TextStyle(color: Color(0xFF805D00)),
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
                                leading: Icon(
                                  _attendanceStatusIcon(status),
                                  color: _attendanceStatusColor(status),
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
                                trailing: Text(
                                  _attendanceStatusLabel(status),
                                  style: TextStyle(
                                    color: _attendanceStatusColor(status),
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
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
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Row(
          children: [
            Container(
              width: 88,
              height: 70,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: const Color(0xFFE3F2F4),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    'SLOT $daySlot',
                    style: const TextStyle(
                      color: Color(0xFF14566A),
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const Text(
                    'trong ngày',
                    style: TextStyle(fontSize: 11, color: Color(0xFF58747D)),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 18),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${slot.subject} · ${slot.classCode}',
                    style: Theme.of(context).textTheme.titleLarge
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 5),
                  Text('Buổi môn học ${slot.slot}$total · ${slot.date}'),
                ],
              ),
            ),
            FilledButton.icon(
              onPressed: canStart ? () => _start(slot) : null,
              icon: Icon(canStart ? Icons.play_arrow : Icons.schedule),
              label: Text(
                canStart
                    ? 'Bắt đầu điểm danh'
                    : isPast
                    ? 'Đã qua ngày học'
                    : 'Chưa đến ngày học',
              ),
            ),
          ],
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
      body: Row(
        children: [
          Container(
            width: 250,
            color: const Color(0xFF103E4E),
            padding: const EdgeInsets.fromLTRB(22, 32, 22, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(
                  children: [
                    Icon(Icons.qr_code_2, color: Colors.white, size: 34),
                    SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'FAP Attendance',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                          fontSize: 18,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 42),
                _SideItem(
                  icon: Icons.today_outlined,
                  label: 'Lịch hôm nay',
                  selected: !_showRoster && !_showOverview && !_showWeek,
                  onTap: () => _selectScheduleView(false),
                ),
                const SizedBox(height: 8),
                _SideItem(
                  icon: Icons.date_range_outlined,
                  label: 'Lịch trong tuần',
                  selected: !_showRoster && !_showOverview && _showWeek,
                  onTap: () => _selectScheduleView(true),
                ),
                const SizedBox(height: 8),
                _SideItem(
                  icon: Icons.analytics_outlined,
                  label: 'Tổng quan lớp',
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
                  selected: _showRoster,
                  onTap: () => setState(() {
                    _showRoster = true;
                    _showOverview = false;
                  }),
                ),
                const Spacer(),
                Text(
                  widget.user.email ?? 'Giảng viên',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Color(0xFFD4E5EA)),
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    side: const BorderSide(color: Color(0xFF5F8591)),
                  ),
                  onPressed: FirebaseAuth.instance.signOut,
                  icon: const Icon(Icons.logout, size: 18),
                  label: const Text('Đăng xuất'),
                ),
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
                    padding: const EdgeInsets.all(36),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    _showWeek
                                        ? 'Lịch trong tuần'
                                        : 'Lịch hôm nay',
                                    style: Theme.of(context)
                                        .textTheme
                                        .headlineMedium
                                        ?.copyWith(fontWeight: FontWeight.w700),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    _showWeek
                                        ? '${DateFormat('dd/MM/yyyy').format(_weekStart)} – '
                                              '${DateFormat('dd/MM/yyyy').format(endOfWeek(_weekStart))}'
                                        : 'Hôm nay, ${DateFormat('dd/MM/yyyy').format(DateTime.now())}',
                                  ),
                                ],
                              ),
                            ),
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
                              const SizedBox(width: 8),
                            ],
                            IconButton(
                              tooltip: 'Làm mới',
                              onPressed: _refresh,
                              icon: const Icon(Icons.refresh),
                            ),
                            const SizedBox(width: 8),
                            IconButton.filledTonal(
                              tooltip: 'Đồng bộ lịch test PRM393 hôm nay',
                              onPressed: _createTestScheduleNow,
                              icon: const Icon(Icons.science_outlined),
                            ),
                            const SizedBox(width: 8),
                            FilledButton.icon(
                              onPressed: _createCourse,
                              icon: const Icon(Icons.add),
                              label: const Padding(
                                padding: EdgeInsets.symmetric(vertical: 12),
                                child: Text('Tạo môn–lớp'),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 28),
                        if (!widget.api.isSheetSyncConfigured) ...[
                          Container(
                            width: double.infinity,
                            margin: const EdgeInsets.only(bottom: 18),
                            padding: const EdgeInsets.all(14),
                            decoration: BoxDecoration(
                              color: const Color(0xFFFFF4D6),
                              border: Border.all(
                                color: const Color(0xFFE8C66A),
                              ),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: const Row(
                              children: [
                                Icon(
                                  Icons.info_outline,
                                  color: Color(0xFF805D00),
                                ),
                                SizedBox(width: 12),
                                Expanded(
                                  child: Text(
                                    'Chưa cấu hình Apps Script: lượt điểm danh vẫn lưu '
                                    'trong Firestore nhưng chưa được chép sang Google Sheets.',
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                        FutureBuilder<AttendanceSession?>(
                          future: _activeSession,
                          builder: (context, snapshot) {
                            final session = snapshot.data;
                            if (session == null) return const SizedBox.shrink();
                            return Padding(
                              padding: const EdgeInsets.only(bottom: 18),
                              child: Container(
                                padding: const EdgeInsets.all(18),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFE4F4EE),
                                  border: Border.all(
                                    color: const Color(0xFF94CEB8),
                                  ),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Row(
                                  children: [
                                    const Icon(
                                      Icons.radio_button_checked,
                                      color: Color(0xFF167052),
                                    ),
                                    const SizedBox(width: 14),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          const Text(
                                            'Phiên điểm danh đang hoạt động',
                                            style: TextStyle(
                                              fontWeight: FontWeight.w700,
                                            ),
                                          ),
                                          Text(
                                            '${session.subject} · ${session.classCode} · '
                                            'Buổi ${session.slot}${session.slotCount > 0 ? '/${session.slotCount}' : ''}'
                                            '${session.daySlot == null ? '' : ' · Slot ${session.daySlot} trong ngày'}',
                                          ),
                                        ],
                                      ),
                                    ),
                                    FilledButton.tonalIcon(
                                      onPressed: () async {
                                        await Navigator.of(context).push(
                                          MaterialPageRoute<void>(
                                            builder: (_) => SessionScreen(
                                              api: widget.api,
                                              session: session,
                                            ),
                                          ),
                                        );
                                        if (mounted) _refresh();
                                      },
                                      icon: const Icon(Icons.open_in_new),
                                      label: const Text('Mở lại phiên'),
                                    ),
                                  ],
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
                                return _EmptyState(
                                  icon: Icons.cloud_off_outlined,
                                  title: 'Không tải được lịch',
                                  subtitle: '${snapshot.error}',
                                  action: TextButton.icon(
                                    onPressed: _refresh,
                                    icon: const Icon(Icons.refresh),
                                    label: const Text('Thử lại'),
                                  ),
                                );
                              }
                              final slots = snapshot.data ?? [];
                              if (slots.isEmpty) {
                                return _EmptyState(
                                  icon: Icons.event_available_outlined,
                                  title: _showWeek
                                      ? 'Tuần này chưa có slot nào'
                                      : 'Hôm nay chưa có slot nào',
                                  subtitle: 'Tạo môn–lớp mới hoặc kiểm tra lại ngày bắt đầu.',
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
                  helperText: 'Code 5 ký tự được tạo mới tự động theo chu kỳ này.',
                  prefixIcon: Icon(Icons.key_rounded),
                ),
                validator: (value) => _validateSeconds(value, 10, 3600),
              ),
              const SizedBox(height: 12),
              const Text(
                'Sinh viên cần đăng nhập và nhập checkout code trước khi QR hết hạn.',
                style: TextStyle(color: Color(0xFF52656B)),
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
            Navigator.pop(
              context,
              (
                rotation: rotation,
                validity: validity,
                checkoutRotation: int.parse(_checkoutRotation.text),
              ),
            );
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
    this.selected = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? const Color(0xFF286A7E) : Colors.transparent,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              Icon(icon, color: Colors.white),
              const SizedBox(width: 12),
              Text(label, style: const TextStyle(color: Colors.white)),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.action,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Widget action;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 64, color: const Color(0xFF86A2AB)),
          const SizedBox(height: 16),
          Text(title, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 6),
          Text(subtitle, textAlign: TextAlign.center),
          const SizedBox(height: 18),
          action,
        ],
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

String _attendanceStatusLabel(AttendanceStatus status) => switch (status) {
  AttendanceStatus.present => 'Có mặt',
  AttendanceStatus.absent => 'Vắng',
  AttendanceStatus.excused => 'Có phép',
  AttendanceStatus.notYetOpen => 'Chưa mở',
};

IconData _attendanceStatusIcon(AttendanceStatus status) => switch (status) {
  AttendanceStatus.present => Icons.check_circle_outline,
  AttendanceStatus.absent => Icons.cancel_outlined,
  AttendanceStatus.excused => Icons.verified_user_outlined,
  AttendanceStatus.notYetOpen => Icons.schedule_outlined,
};

Color _attendanceStatusColor(AttendanceStatus status) => switch (status) {
  AttendanceStatus.present => const Color(0xFF167052),
  AttendanceStatus.absent => const Color(0xFFB5473C),
  AttendanceStatus.excused => const Color(0xFF7C3AED),
  AttendanceStatus.notYetOpen => const Color(0xFF7B898D),
};
