import 'dart:convert';
import 'dart:io';

import 'package:csv/csv.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../domain/class_overview.dart';
import '../domain/models.dart';
import '../services/attendance_api.dart';
import '../theme/app_theme.dart';
import '../widgets/app_ui.dart';
import 'session_screen.dart';

class ClassOverviewScreen extends StatefulWidget {
  const ClassOverviewScreen({
    super.key,
    required this.api,
    this.onOpenSchedule,
  });

  final AttendanceApi api;
  final VoidCallback? onOpenSchedule;

  @override
  State<ClassOverviewScreen> createState() => _ClassOverviewScreenState();
}

class _ClassOverviewScreenState extends State<ClassOverviewScreen> {
  late Future<List<CourseClassSummary>> _classes;
  Future<CourseOverview>? _overview;
  CourseClassSummary? _selectedClass;
  final _searchController = TextEditingController();
  final _matrixVerticalController = ScrollController();
  AttendanceStatus? _statusFilter;
  bool _bulkAdjusting = false;

  @override
  void initState() {
    super.initState();
    _classes = widget.api.getCourseClasses();
  }

  @override
  void dispose() {
    _searchController.dispose();
    _matrixVerticalController.dispose();
    super.dispose();
  }

  void _selectClass(CourseClassSummary? course) {
    setState(() {
      _selectedClass = course;
      _overview = course == null
          ? null
          : widget.api.getCourseOverview(course.id);
    });
  }

  void _refresh() {
    final course = _selectedClass;
    if (course != null) {
      setState(() {
        _overview = widget.api.getCourseOverview(course.id);
      });
    }
  }

  Future<void> _refreshAndSync() async {
    try {
      final result = await widget.api.syncPendingCheckIns(force: true);
      if (!mounted) return;
      _refresh();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            result.notConfigured
                ? 'Google Sheets chưa được cấu hình.'
                : 'Đã đồng bộ ${result.synced} bản ghi; còn chờ ${result.pending}, lỗi ${result.error}.',
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      _refresh();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Đồng bộ Google Sheets thất bại: $error')),
      );
    }
  }

  Future<({AttendanceStatus status, String reason})?> _changeDialog({
    required String title,
    required AttendanceStatus initialStatus,
  }) async {
    var reason = '';
    var selected = initialStatus == AttendanceStatus.notYetOpen
        ? AttendanceStatus.absent
        : initialStatus;
    final result = await showDialog<({AttendanceStatus status, String reason})>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(title),
          content: SizedBox(
            width: 440,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<AttendanceStatus>(
                  initialValue: selected,
                  decoration: const InputDecoration(
                    labelText: 'Trạng thái mới',
                  ),
                  items: const [
                    DropdownMenuItem(
                      value: AttendanceStatus.present,
                      child: Text('Có mặt'),
                    ),
                    DropdownMenuItem(
                      value: AttendanceStatus.absent,
                      child: Text('Vắng'),
                    ),
                    DropdownMenuItem(
                      value: AttendanceStatus.excused,
                      child: Text('Có phép'),
                    ),
                  ],
                  onChanged: (value) {
                    if (value != null) setDialogState(() => selected = value);
                  },
                ),
                const SizedBox(height: 16),
                TextField(
                  autofocus: true,
                  maxLength: 300,
                  onChanged: (value) => reason = value,
                  decoration: const InputDecoration(
                    labelText: 'Lý do bắt buộc',
                    hintText: 'Ví dụ: Giảng viên xác nhận có mặt',
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Hủy'),
            ),
            FilledButton(
              onPressed: () {
                final trimmedReason = reason.trim();
                if (trimmedReason.length < 3) return;
                Navigator.pop(context, (
                  status: selected,
                  reason: trimmedReason,
                ));
              },
              child: const Text('Lưu thay đổi'),
            ),
          ],
        ),
      ),
    );
    return result;
  }

  Future<void> _editAttendance(
    CourseOverview overview,
    CourseStudent student,
    CourseSlotOverview slot,
  ) async {
    if (!slot.hasOpened) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Slot chưa mở nên chưa thể điều chỉnh.')),
      );
      return;
    }
    final change = await _changeDialog(
      title: '${student.displayName} · Buổi ${slot.number}',
      initialStatus: overview.statusFor(student.id, slot),
    );
    if (change == null) return;
    try {
      final result = await widget.api.adjustAttendance(
        courseClassId: overview.courseClassId,
        slot: slot.number,
        studentId: student.id,
        status: change.status,
        reason: change.reason,
      );
      if (!mounted) return;
      _refresh();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            result.synced
                ? 'Đã cập nhật hệ thống và Google Sheets.'
                : 'Đã lưu trên hệ thống; chờ đồng bộ Google Sheets: ${result.syncError}',
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      _refresh();
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Cập nhật chưa hoàn tất: $error')));
    }
  }

  Future<void> _editAttendanceBulk(
    CourseOverview overview,
    CourseSlotOverview slot,
  ) async {
    if (!slot.hasOpened || _bulkAdjusting) return;
    final students = _filteredStudents(overview)
        .where((item) => item.active)
        .toList();
    if (students.isEmpty) return;
    final change = await _changeDialog(
      title: 'Điều chỉnh ${students.length} sinh viên · Buổi ${slot.number}',
      initialStatus: AttendanceStatus.excused,
    );
    if (change == null) return;
    await _runBulkAdjustment(
      overview: overview,
      slot: slot,
      students: students,
      studentIds: students.map((student) => student.id).toList(),
      status: change.status,
      reason: change.reason,
    );
  }

  Future<void> _runBulkAdjustment({
    required CourseOverview overview,
    required CourseSlotOverview slot,
    required List<CourseStudent> students,
    required List<String> studentIds,
    required AttendanceStatus status,
    required String reason,
  }) async {
    if (_bulkAdjusting) return;
    setState(() => _bulkAdjusting = true);
    List<String>? retryIds;
    try {
      final result = await widget.api.adjustAttendanceBulk(
        courseClassId: overview.courseClassId,
        slot: slot.number,
        studentIds: studentIds,
        status: status,
        reason: reason,
      );
      if (!mounted) return;
      _refresh();
      final names = {
        for (final student in students) student.id: student.displayName,
      };
      final retry = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(
            'Đã lưu ${result.savedCount}/${studentIds.length} sinh viên',
          ),
          content: SizedBox(
            width: 500,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Đã đồng bộ Sheets: ${result.syncedCount}'),
                  Text('Đã lưu, chờ Sheets: ${result.pendingSync.length}'),
                  Text('Chưa lưu: ${result.failures.length}'),
                  if (result.failures.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    for (final entry in result.failures.entries)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text(
                          '${names[entry.key] ?? entry.key}: ${entry.value}',
                        ),
                      ),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Đóng'),
            ),
            if (result.failures.isNotEmpty)
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: Text('Thử lại ${result.failures.length} trường hợp'),
              ),
          ],
        ),
      );
      if (retry == true) retryIds = result.failures.keys.toList();
    } catch (error) {
      if (!mounted) return;
      _refresh();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Không thể điều chỉnh hàng loạt: $error')),
      );
    } finally {
      if (mounted) setState(() => _bulkAdjusting = false);
    }
    if (retryIds != null && mounted) {
      await _runBulkAdjustment(
        overview: overview,
        slot: slot,
        students: students,
        studentIds: retryIds,
        status: status,
        reason: reason,
      );
    }
  }

  Future<void> _togglePolicy(
    CourseOverview overview,
    CourseStudent student,
  ) async {
    final enable = !student.isAlwaysExcused;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          enable ? 'Miễn điểm danh toàn khóa?' : 'Tắt miễn toàn khóa?',
        ),
        content: Text(
          enable
              ? 'Các slot mở từ thời điểm này sẽ tự ghi nhận ${student.displayName} là có phép.'
              : 'Lịch sử có phép đã tạo trước đây sẽ được giữ nguyên.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Hủy'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Xác nhận'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await widget.api.setAttendancePolicy(
        courseClassId: overview.courseClassId,
        studentId: student.id,
        policy: enable
            ? AttendancePolicy.alwaysExcused
            : AttendancePolicy.normal,
      );
      if (mounted) _refresh();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Không thể cập nhật chính sách: $error')),
      );
    }
  }

  Future<void> _openActiveSession(CourseOverview overview) async {
    try {
      final session = await widget.api.getActiveAttendance();
      if (!mounted) return;
      if (session == null || session.courseClassId != overview.courseClassId) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Phiên điểm danh không còn hoạt động.')),
        );
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Không thể mở phiên điểm danh: $error')),
      );
    }
  }

  List<CourseStudent> _filteredStudents(CourseOverview overview) {
    final query = _searchController.text.trim().toLowerCase();
    return overview.students.where((student) {
      final matchesText =
          query.isEmpty ||
          student.fullName.toLowerCase().contains(query) ||
          student.email.toLowerCase().contains(query) ||
          student.studentCode.toLowerCase().contains(query);
      final filter = _statusFilter;
      final matchesStatus =
          filter == null ||
          overview.slots.any(
            (slot) => overview.statusFor(student.id, slot) == filter,
          );
      return matchesText && matchesStatus;
    }).toList();
  }

  Future<({String email, String studentCode, String fullName})?> _studentEditor(
    CourseStudent? student,
  ) async {
    final emailController = TextEditingController(text: student?.email ?? '');
    final codeController = TextEditingController(
      text: student?.studentCode ?? '',
    );
    final nameController = TextEditingController(text: student?.fullName ?? '');
    final formKey = GlobalKey<FormState>();
    final result =
        await showDialog<({String email, String studentCode, String fullName})>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: Text(
              student == null ? 'Thêm sinh viên' : 'Sửa thông tin sinh viên',
            ),
            content: SizedBox(
              width: 440,
              child: Form(
                key: formKey,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextFormField(
                      controller: emailController,
                      readOnly: student != null,
                      keyboardType: TextInputType.emailAddress,
                      decoration: InputDecoration(
                        labelText: 'Email đăng nhập',
                        helperText: student == null
                            ? 'Dùng email này để sinh viên đăng nhập điểm danh.'
                            : 'Email tạo định danh và lịch sử điểm danh nên không thể đổi.',
                      ),
                      validator: (value) {
                        final email = value?.trim().toLowerCase() ?? '';
                        return RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$')
                                .hasMatch(email)
                            ? null
                            : 'Email không hợp lệ.';
                      },
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: codeController,
                      textCapitalization: TextCapitalization.characters,
                      maxLength: 20,
                      decoration: const InputDecoration(
                        labelText: 'Mã sinh viên',
                      ),
                      validator: (value) {
                        final code = value?.trim().toUpperCase() ?? '';
                        return RegExp(r'^[A-Z0-9_-]{3,20}$').hasMatch(code)
                            ? null
                            : 'Mã gồm 3–20 ký tự A–Z, 0–9, _ hoặc -.';
                      },
                    ),
                    const SizedBox(height: 4),
                    TextFormField(
                      controller: nameController,
                      maxLength: 120,
                      textCapitalization: TextCapitalization.words,
                      decoration: const InputDecoration(labelText: 'Họ và tên'),
                      validator: (value) {
                        final name = value?.trim() ?? '';
                        if (name.isEmpty) return 'Hãy nhập họ và tên.';
                        if (name.length > 120) {
                          return 'Họ tên tối đa 120 ký tự.';
                        }
                        return null;
                      },
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Hủy'),
              ),
              FilledButton.icon(
                onPressed: () {
                  if (!formKey.currentState!.validate()) return;
                  Navigator.pop(dialogContext, (
                    email: emailController.text.trim(),
                    studentCode: codeController.text.trim(),
                    fullName: nameController.text.trim(),
                  ));
                },
                icon: const Icon(Icons.save_outlined),
                label: const Text('Lưu'),
              ),
            ],
          ),
        );
    emailController.dispose();
    codeController.dispose();
    nameController.dispose();
    return result;
  }

  Future<void> _saveStudent(
    CourseOverview overview, {
    CourseStudent? student,
  }) async {
    final profile = await _studentEditor(student);
    if (profile == null) return;
    try {
      if (student == null) {
        await widget.api.addCourseStudent(
          courseClassId: overview.courseClassId,
          email: profile.email,
          studentCode: profile.studentCode,
          fullName: profile.fullName,
        );
      } else {
        await widget.api.updateCourseStudent(
          courseClassId: overview.courseClassId,
          studentId: student.id,
          studentCode: profile.studentCode,
          fullName: profile.fullName,
        );
      }
      if (!mounted) return;
      _refresh();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            student == null
                ? 'Đã thêm sinh viên vào lớp.'
                : 'Đã cập nhật hồ sơ sinh viên.',
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Không thể lưu hồ sơ sinh viên: $error')),
      );
    }
  }

  Future<void> _setStudentActive(
    CourseOverview overview,
    CourseStudent student,
  ) async {
    final active = !student.active;
    if (!active) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Xóa sinh viên khỏi lớp?'),
          content: Text(
            'Sinh viên ${student.displayName} sẽ không thể điểm danh trong lớp này. '
            'Lịch sử điểm danh sẽ được giữ lại; bạn có thể khôi phục hồ sơ sau.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Hủy'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Xóa khỏi lớp'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    }

    try {
      await widget.api.setCourseStudentActive(
        courseClassId: overview.courseClassId,
        studentId: student.id,
        active: active,
      );
      if (!mounted) return;
      _refresh();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            active
                ? 'Đã khôi phục sinh viên vào lớp.'
                : 'Đã xóa sinh viên khỏi lớp; lịch sử điểm danh được giữ lại.',
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Không thể cập nhật sinh viên: $error')),
      );
    }
  }

  Future<void> _exportMatrix(CourseOverview overview) async {
    final rows = <List<dynamic>>[
      [
        'Báo cáo ma trận điểm danh',
        '${overview.subject} · ${overview.classCode}',
      ],
      ['Timezone', 'Asia/Ho_Chi_Minh'],
      ['Ngày tạo', DateFormat('dd/MM/yyyy HH:mm').format(DateTime.now())],
      [],
      [
        'Mã sinh viên',
        'Họ tên',
        'Email',
        for (final slot in overview.slots) 'Buổi ${slot.number} (${slot.date})',
        'Đã tham dự',
      ],
      for (final student in _filteredStudents(overview))
        [
          student.studentCode,
          student.fullName,
          student.email,
          for (final slot in overview.slots)
            _statusLabel(overview.statusFor(student.id, slot)),
          '${overview.attendedCount(student)}/${overview.openedSlotCount}',
        ],
      [],
      ['Chú giải', 'Có mặt; Vắng; Có phép; Nhập tay; Chưa mở'],
    ];
    await _saveCsv(
      '${overview.subject}_${overview.classCode}_attendance_matrix.csv',
      rows,
    );
  }

  Future<void> _exportSlot(
    CourseOverview overview,
    CourseSlotOverview slot,
  ) async {
    final rows = <List<dynamic>>[
      [
        'Chi tiết buổi ${slot.number}',
        '${overview.subject} · ${overview.classCode}',
      ],
      ['Ngày học', slot.date],
      ['Timezone', 'Asia/Ho_Chi_Minh'],
      ['Ngày tạo', DateFormat('dd/MM/yyyy HH:mm').format(DateTime.now())],
      [],
      [
        'Mã sinh viên',
        'Họ tên',
        'Email',
        'Trạng thái',
        'Thời gian',
        'Nguồn',
        'Đồng bộ',
      ],
      for (final student in overview.students)
        [
          student.studentCode,
          student.fullName,
          student.email,
          _statusLabel(overview.statusFor(student.id, slot)),
          overview.entryFor(student.id, slot.number)?.checkedInAt == null
              ? ''
              : DateFormat('dd/MM/yyyy HH:mm:ss').format(
                  overview.entryFor(student.id, slot.number)!.checkedInAt!,
                ),
          overview.entryFor(student.id, slot.number)?.source ?? '',
          overview.entryFor(student.id, slot.number)?.syncStatus ?? '',
        ],
    ];
    await _saveCsv(
      '${overview.subject}_${overview.classCode}_slot_${slot.number}.csv',
      rows,
    );
  }

  Future<void> _saveCsv(String fileName, List<List<dynamic>> rows) async {
    try {
      final path = await FilePicker.platform.saveFile(
        dialogTitle: 'Lưu báo cáo điểm danh',
        fileName: fileName,
        type: FileType.custom,
        allowedExtensions: const ['csv'],
      );
      if (path == null) return;
      final csv = const ListToCsvConverter().convert(rows);
      await File(path).writeAsBytes([0xEF, 0xBB, 0xBF, ...utf8.encode(csv)]);
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Đã xuất báo cáo: $path')));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Không thể xuất báo cáo: $error')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(AppSpace.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppPageHeader(
            title: 'Tổng quan lớp học',
            subtitle: 'Theo dõi buổi học, chuyên cần và phiên điểm danh.',
            actions: [
              SizedBox(
                width: 310,
                child: FutureBuilder<List<CourseClassSummary>>(
                  future: _classes,
                  builder: (context, snapshot) => DropdownButtonFormField(
                    initialValue: _selectedClass,
                    decoration: const InputDecoration(
                      labelText: 'Môn–lớp',
                      prefixIcon: Icon(Icons.school_outlined),
                    ),
                    items: [
                      for (final course
                          in snapshot.data ?? const <CourseClassSummary>[])
                        DropdownMenuItem(
                          value: course,
                          child: Text(course.label),
                        ),
                    ],
                    onChanged: _selectClass,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              if (widget.onOpenSchedule != null) ...[
                FilledButton.tonalIcon(
                  onPressed: widget.onOpenSchedule,
                  icon: const Icon(Icons.drag_indicator),
                  label: const Text('Điều chỉnh lịch'),
                ),
                const SizedBox(width: 8),
              ],
              IconButton.filledTonal(
                tooltip: 'Đồng bộ Google Sheets và làm mới dữ liệu',
                onPressed: _selectedClass == null ? null : _refreshAndSync,
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
          const SizedBox(height: AppSpace.xl),
          Expanded(
            child: _overview == null
                ? const AppEmptyState(
                    icon: Icons.analytics_outlined,
                    title: 'Chọn một môn–lớp',
                    description: 'Xem thống kê và chỉnh sửa điểm danh của lớp.',
                  )
                : FutureBuilder<CourseOverview>(
                    future: _overview,
                    builder: (context, snapshot) {
                      if (snapshot.connectionState == ConnectionState.waiting) {
                        return const Center(child: CircularProgressIndicator());
                      }
                      if (snapshot.hasError) {
                        return AppEmptyState(
                          icon: Icons.cloud_off_outlined,
                          title: 'Không tải được tổng quan',
                          description: '${snapshot.error}',
                          action: TextButton.icon(
                            onPressed: _refresh,
                            icon: const Icon(Icons.refresh),
                            label: const Text('Thử lại'),
                          ),
                        );
                      }
                      return _buildOverview(snapshot.requireData);
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildOverview(CourseOverview overview) {
    final students = _filteredStudents(overview);
    final absenceAlertStudentCount = overview.absenceAlertStudentCount;
    return Column(
      children: [
        if (overview.activeSlot != null) ...[
          AppNotice(
            tone: AppTone.success,
            icon: Icons.radio_button_checked,
            message:
                'Đang điểm danh buổi ${overview.activeSlot!.number} · '
                '${overview.activeSlot!.date}',
            action: TextButton.icon(
              onPressed: () => _openActiveSession(overview),
              icon: const Icon(Icons.open_in_new),
              label: const Text('Mở phiên'),
            ),
          ),
          const SizedBox(height: AppSpace.md),
        ],
        LayoutBuilder(
          builder: (context, constraints) {
            final columns = constraints.maxWidth >= 1050
                ? 4
                : constraints.maxWidth >= 520
                ? 2
                : 1;
            final width =
                (constraints.maxWidth - (columns - 1) * AppSpace.md) / columns;
            return Wrap(
              spacing: AppSpace.md,
              runSpacing: AppSpace.md,
              children: [
                SizedBox(
                  width: width,
                  child: AppMetricTile(
                    label: 'Sĩ số',
                    value: '${overview.activeStudentCount}',
                    icon: Icons.groups_outlined,
                  ),
                ),
                SizedBox(
                  width: width,
                  child: AppMetricTile(
                    label: 'Buổi đã mở',
                    value:
                        '${overview.openedSlotCount}/${overview.slots.length}',
                    icon: Icons.event_available_outlined,
                  ),
                ),
                SizedBox(
                  width: width,
                  child: AppMetricTile(
                    label: 'Tỷ lệ tham dự',
                    value:
                        '${(overview.attendanceRate * 100).toStringAsFixed(1)}%',
                    icon: Icons.trending_up,
                  ),
                ),
                SizedBox(
                  width: width,
                  child: AppMetricTile(
                    label: 'Cần chú ý',
                    value:
                        '${overview.atRiskStudentCount + overview.syncErrorCount}',
                    icon: Icons.warning_amber_rounded,
                    tone:
                        overview.atRiskStudentCount + overview.syncErrorCount >
                            0
                        ? AppTone.warning
                        : AppTone.info,
                  ),
                ),
              ],
            );
          },
        ),
        if (absenceAlertStudentCount > 0) ...[
          const SizedBox(height: AppSpace.md),
          AppNotice(
            tone: AppTone.warning,
            icon: Icons.warning_amber_rounded,
            message:
                '$absenceAlertStudentCount sinh viên đã vắng không phép '
                'từ 10% tổng số buổi trong kế hoạch. '
                '${overview.examRiskStudentCount} sinh viên vượt 20% '
                '(ngưỡng cấm thi).',
          ),
        ],
        const SizedBox(height: AppSpace.lg),
        LayoutBuilder(
          builder: (context, constraints) => Wrap(
            spacing: AppSpace.md,
            runSpacing: AppSpace.sm,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SizedBox(
                width: constraints.maxWidth >= 960
                    ? constraints.maxWidth - 640
                    : constraints.maxWidth,
                child: TextField(
                  controller: _searchController,
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(
                    isDense: true,
                    prefixIcon: Icon(Icons.search),
                    hintText: 'Tìm tên, email hoặc mã sinh viên',
                  ),
                ),
              ),
              SizedBox(
                width: 190,
                child: DropdownButtonFormField<AttendanceStatus?>(
                  initialValue: _statusFilter,
                  decoration: const InputDecoration(
                    labelText: 'Lọc trạng thái',
                    isDense: true,
                  ),
                  items: [
                    const DropdownMenuItem(value: null, child: Text('Tất cả')),
                    for (final status in AttendanceStatus.values)
                      DropdownMenuItem(
                        value: status,
                        child: Text(_statusLabel(status)),
                      ),
                  ],
                  onChanged: (value) => setState(() => _statusFilter = value),
                ),
              ),
              FilledButton.tonalIcon(
                onPressed: () => _exportMatrix(overview),
                icon: const Icon(Icons.download_outlined),
                label: const Text('Xuất ma trận CSV'),
              ),
              FilledButton.icon(
                onPressed: () => _saveStudent(overview),
                icon: const Icon(Icons.person_add_alt_1),
                label: const Text('Thêm sinh viên'),
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpace.md),
        Expanded(
          child: Card(
            clipBehavior: Clip.antiAlias,
            child: students.isEmpty
                ? const AppEmptyState(
                    icon: Icons.filter_alt_off_outlined,
                    title: 'Không tìm thấy sinh viên',
                    description: 'Thử từ khóa hoặc trạng thái khác.',
                  )
                : Scrollbar(
                    controller: _matrixVerticalController,
                    thumbVisibility: true,
                    child: SingleChildScrollView(
                      controller: _matrixVerticalController,
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: DataTable(
                          columns: [
                            const DataColumn(label: Text('Sinh viên')),
                            const DataColumn(label: Text('Tham dự')),
                            const DataColumn(label: Text('Vắng / tổng')),
                            const DataColumn(label: Text('Trạng thái')),
                            for (final slot in overview.slots)
                              DataColumn(
                                label: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    InkWell(
                                      onTap: () =>
                                          _showSlotDetail(overview, slot),
                                      child: Tooltip(
                                        message:
                                            'Xem chi tiết buổi ${slot.number}',
                                        child: Column(
                                          mainAxisAlignment:
                                              MainAxisAlignment.center,
                                          children: [
                                            Text('Buổi ${slot.number}'),
                                            Text(
                                              slot.date,
                                              style: const TextStyle(
                                                fontSize: 11,
                                                fontWeight: FontWeight.normal,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                    if (slot.hasOpened)
                                      IconButton(
                                        tooltip: 'Điều chỉnh tất cả sinh viên đang lọc',
                                        onPressed: _bulkAdjusting
                                            ? null
                                            : () => _editAttendanceBulk(
                                                overview,
                                                slot,
                                              ),
                                        icon: const Icon(
                                          Icons.playlist_add_check,
                                          size: 18,
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            const DataColumn(label: Text('Thao tác')),
                          ],
                          rows: [
                            for (final student in students)
                              DataRow(
                                cells: [
                                  DataCell(
                                    SizedBox(
                                      width: 210,
                                      child: Row(
                                        children: [
                                          Expanded(
                                            child: Column(
                                              mainAxisAlignment:
                                                  MainAxisAlignment.center,
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                Text(
                                                  student.displayName,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: const TextStyle(
                                                    fontWeight: FontWeight.w700,
                                                  ),
                                                ),
                                                Text(
                                                  '${student.studentCode} · ${student.email}',
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: const TextStyle(
                                                    fontSize: 11,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                          IconButton(
                                            tooltip: student.isAlwaysExcused
                                                ? 'Đang miễn toàn khóa – nhấn để tắt'
                                                : 'Bật miễn điểm danh toàn khóa',
                                            onPressed: () => _togglePolicy(
                                              overview,
                                              student,
                                            ),
                                            icon: Icon(
                                              student.isAlwaysExcused
                                                  ? Icons.policy
                                                  : Icons.policy_outlined,
                                              color: student.isAlwaysExcused
                                                  ? AppColors.info
                                                  : null,
                                              size: 19,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    onTap: () =>
                                        _showStudentDetail(overview, student),
                                  ),
                                  DataCell(
                                    Text(
                                      '${overview.attendedCount(student)}/${overview.openedSlotCount}',
                                    ),
                                  ),
                                  DataCell(
                                    _AbsenceIndicator(
                                      overview: overview,
                                      student: student,
                                    ),
                                  ),
                                  DataCell(
                                    Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(
                                          student.active
                                              ? Icons.check_circle_outline
                                              : Icons.pause_circle_outline,
                                          size: 18,
                                          color: student.active
                                              ? AppColors.success
                                              : AppColors.textMuted,
                                        ),
                                        const SizedBox(width: 6),
                                        Text(
                                          student.active
                                              ? 'Đang học'
                                              : 'Đã ngừng',
                                        ),
                                      ],
                                    ),
                                  ),
                                  for (final slot in overview.slots)
                                    DataCell(
                                      AppAttendanceBadge(
                                        iconOnly: true,
                                        status: overview.statusFor(
                                          student.id,
                                          slot,
                                        ),
                                        source: overview
                                            .entryFor(student.id, slot.number)
                                            ?.source,
                                      ),
                                      onTap: () => _editAttendance(
                                        overview,
                                        student,
                                        slot,
                                      ),
                                    ),
                                  DataCell(
                                    Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        IconButton(
                                          tooltip: 'Sửa thông tin sinh viên',
                                          onPressed: () => _saveStudent(
                                            overview,
                                            student: student,
                                          ),
                                          icon: const Icon(Icons.edit_outlined),
                                        ),
                                        IconButton(
                                          tooltip: student.active
                                              ? 'Xóa khỏi lớp'
                                              : 'Khôi phục vào lớp',
                                          onPressed: () => _setStudentActive(
                                            overview,
                                            student,
                                          ),
                                          icon: Icon(
                                            student.active
                                                ? Icons.person_remove_outlined
                                                : Icons.person_add_alt_1,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
          ),
        ),
      ],
    );
  }

  void _showStudentDetail(CourseOverview overview, CourseStudent student) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(student.displayName),
        content: SizedBox(
          width: 620,
          child: ListView(
            shrinkWrap: true,
            children: [
              Text('${student.studentCode} · ${student.email}'),
              const SizedBox(height: 14),
              for (final slot in overview.slots)
                ListTile(
                  leading: AppAttendanceBadge(
                    iconOnly: true,
                    status: overview.statusFor(student.id, slot),
                  ),
                  title: Text('Buổi ${slot.number} · ${slot.date}'),
                  subtitle: Text(
                    _entryDescription(
                      overview.entryFor(student.id, slot.number),
                    ),
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Đóng'),
          ),
        ],
      ),
    );
  }

  Future<void> _showSlotDetail(
    CourseOverview overview,
    CourseSlotOverview slot,
  ) async {
    final present = overview.students.where((s) {
      final status = overview.statusFor(s.id, slot);
      return status == AttendanceStatus.present;
    }).length;
    final excused = overview.students
        .where(
          (s) => overview.statusFor(s.id, slot) == AttendanceStatus.excused,
        )
        .length;
    final selectedStudent = await showDialog<CourseStudent>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Buổi ${slot.number} · ${slot.date}'),
        content: SizedBox(
          width: 680,
          height: 520,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 10,
                children: [
                  Chip(label: Text('Có mặt $present')),
                  Chip(
                    label: Text(
                      'Vắng ${slot.hasOpened ? overview.activeStudentCount - present - excused : 0}',
                    ),
                  ),
                  Chip(label: Text('Có phép $excused')),
                  Chip(label: Text('Phiên ${slot.sessionIds.length}')),
                ],
              ),
              const Divider(),
              Expanded(
                child: ListView(
                  children: [
                    for (final student in overview.students)
                      ListTile(
                        leading: AppAttendanceBadge(
                          iconOnly: true,
                          status: overview.statusFor(student.id, slot),
                          source: overview
                              .entryFor(student.id, slot.number)
                              ?.source,
                        ),
                        title: Text(student.displayName),
                        subtitle: Text(
                          '${student.studentCode} · ${_entryDescription(overview.entryFor(student.id, slot.number))}',
                        ),
                        trailing: slot.hasOpened
                            ? IconButton(
                                tooltip: 'Điều chỉnh',
                                onPressed: () =>
                                    Navigator.pop(dialogContext, student),
                                icon: const Icon(Icons.edit_outlined),
                              )
                            : null,
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton.icon(
            onPressed: () => _exportSlot(overview, slot),
            icon: const Icon(Icons.download_outlined),
            label: const Text('Xuất CSV'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Đóng'),
          ),
        ],
      ),
    );
    if (selectedStudent != null && mounted) {
      await _editAttendance(overview, selectedStudent, slot);
    }
  }

  String _entryDescription(AttendanceEntry? entry) {
    if (entry == null) return 'Chưa có bản ghi';
    final time = entry.checkedInAt == null
        ? 'Không có thời gian'
        : DateFormat('HH:mm:ss dd/MM/yyyy').format(entry.checkedInAt!);
    return '$time · ${entry.source} · sync: ${entry.syncStatus}';
  }
}

String _statusLabel(AttendanceStatus status) => switch (status) {
  AttendanceStatus.present => 'Có mặt',
  AttendanceStatus.absent => 'Vắng',
  AttendanceStatus.excused => 'Có phép',
  AttendanceStatus.notYetOpen => 'Chưa mở',
};

class _AbsenceIndicator extends StatelessWidget {
  const _AbsenceIndicator({required this.overview, required this.student});

  final CourseOverview overview;
  final CourseStudent student;

  @override
  Widget build(BuildContext context) {
    final absent = overview.absentCount(student);
    final total = overview.slots.length;
    final risk = overview.absenceRiskFor(student);
    final percentage = total == 0
        ? '—'
        : '${(overview.absenceRate(student) * 100).toStringAsFixed(1)}%';
    final color = switch (risk) {
      AbsenceRiskLevel.warning => AppColors.warning,
      AbsenceRiskLevel.examRisk => AppColors.error,
      AbsenceRiskLevel.none => AppColors.textMuted,
    };
    final tooltip = switch (risk) {
      AbsenceRiskLevel.warning =>
        'Đã vắng không phép từ 10% tổng số buổi trong kế hoạch.',
      AbsenceRiskLevel.examRisk =>
        'Đã vượt 20% tổng số buổi, thuộc diện cấm thi.',
      AbsenceRiskLevel.none =>
        'Số buổi vắng không phép trên tổng số buổi trong kế hoạch.',
    };

    return Tooltip(
      message: tooltip,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '$absent/$total · $percentage',
            style: TextStyle(
              color: color,
              fontWeight: risk == AbsenceRiskLevel.none
                  ? FontWeight.normal
                  : FontWeight.w700,
            ),
          ),
          if (risk != AbsenceRiskLevel.none) ...[
            const SizedBox(width: 5),
            Icon(Icons.warning_amber_rounded, size: 17, color: color),
          ],
        ],
      ),
    );
  }
}
