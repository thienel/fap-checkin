import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../domain/class_overview.dart';
import '../domain/live_attendance.dart';
import '../domain/models.dart';
import '../services/attendance_api.dart';
import '../services/live_session_service.dart';

enum AttendanceFilter {
  all,
  present,
  notYetOpen,
  other, // absent or excused
}

class SessionScreen extends StatefulWidget {
  const SessionScreen({
    super.key,
    required this.api,
    required this.session,
    this.liveSessionService,
  });

  final AttendanceApi api;
  final AttendanceSession session;
  final LiveSessionService? liveSessionService;

  @override
  State<SessionScreen> createState() => _SessionScreenState();
}

class _SessionScreenState extends State<SessionScreen> {
  late final LiveSessionService _service;
  late final Stream<LiveAttendanceState> _liveStream;

  Timer? _rotationTimer;
  Timer? _countdownTimer;

  IssuedQr? _qr;
  final ValueNotifier<IssuedQr?> _qrNotifier = ValueNotifier<IssuedQr?>(null);
  late final ValueNotifier<int> _secondsLeftNotifier;

  bool _issuing = false;
  bool _stopping = false;
  bool _retryingSync = false;
  String? _error;

  String _searchQuery = '';
  AttendanceFilter _selectedFilter = AttendanceFilter.all;

  @override
  void initState() {
    super.initState();
    _service =
        widget.liveSessionService ?? LiveSessionService(api: widget.api);

    // Một subscription duy nhất cho toàn bộ vòng đời của màn hình.
    // Xoay QR tuyệt đối không unsubscribe hoặc reset stream danh sách.
    _liveStream = _service.watchLiveAttendance(session: widget.session);

    _secondsLeftNotifier =
        ValueNotifier<int>(widget.session.rotationSeconds);

    _issueQr();

    // Timer xoay mã QR theo chu kỳ
    _rotationTimer = Timer.periodic(
      Duration(seconds: widget.session.rotationSeconds),
      (_) => _issueQr(),
    );

    // Timer đếm ngược giây hiển thị trên UI
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_secondsLeftNotifier.value > 0) {
        _secondsLeftNotifier.value -= 1;
      }
    });
  }

  @override
  void dispose() {
    _rotationTimer?.cancel();
    _countdownTimer?.cancel();
    _qrNotifier.dispose();
    _secondsLeftNotifier.dispose();
    super.dispose();
  }

  Future<void> _issueQr() async {
    if (_issuing || _stopping) return;
    _issuing = true;
    try {
      final qr = await widget.api.issueQr(widget.session.id);
      if (mounted) {
        setState(() {
          _qr = qr;
          _qrNotifier.value = qr;
          _secondsLeftNotifier.value = widget.session.rotationSeconds;
          _error = null;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() => _error = 'Không tạo được QR mới: $error');
      }
    } finally {
      _issuing = false;
    }
  }

  String _formatDate(String isoDate) {
    final parsed = DateTime.tryParse(isoDate);
    if (parsed == null) return isoDate;
    final day = parsed.day.toString().padLeft(2, '0');
    final month = parsed.month.toString().padLeft(2, '0');
    final year = parsed.year.toString();
    return '$day/$month/$year';
  }

  Future<void> _stop() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: Color(0xFFE11D48)),
            SizedBox(width: 10),
            Text('Ngừng điểm danh?'),
          ],
        ),
        content: const Text(
          'Khi ngừng điểm danh, sinh viên sẽ không thể quét mã trong buổi học này nữa. Bạn có chắc chắn muốn kết thúc?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Tiếp tục điểm danh'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFE11D48),
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Xác nhận ngừng'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    setState(() => _stopping = true);
    _rotationTimer?.cancel();
    _countdownTimer?.cancel();
    try {
      await widget.api.stopAttendance(widget.session.id);
      if (mounted) Navigator.of(context).pop();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _stopping = false;
        _error = 'Không thể ngừng phiên: $error';
      });
    }
  }

  Future<void> _retrySheetSync() async {
    if (_retryingSync) return;
    setState(() => _retryingSync = true);
    try {
      await widget.api.syncPendingCheckIns();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Đã yêu cầu đồng bộ lại với Google Sheets.'),
          backgroundColor: Color(0xFF0F766E),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Đồng bộ Google Sheets thất bại: $error'),
          backgroundColor: const Color(0xFFE11D48),
        ),
      );
    } finally {
      if (mounted) setState(() => _retryingSync = false);
    }
  }

  void _openFullscreenQr() {
    showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.85),
      builder: (dialogContext) => _FullscreenQrDialog(
        session: widget.session,
        qrNotifier: _qrNotifier,
        countdownNotifier: _secondsLeftNotifier,
      ),
    );
  }

  void _showStudentDetail(CourseStudent student) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Icons.badge_outlined, color: Color(0xFF0F766E)),
            SizedBox(width: 10),
            Text('Hồ sơ chuyên cần sinh viên'),
          ],
        ),
        content: SizedBox(
          width: 500,
          child: FutureBuilder<StudentAttendanceDetail>(
            future: widget.api.getStudentAttendanceDetail(
              courseClassId: widget.session.courseClassId,
              studentId: student.id,
            ),
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const SizedBox(
                  height: 200,
                  child: Center(child: CircularProgressIndicator()),
                );
              }
              if (snapshot.hasError) {
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _StudentInfoRow(
                      icon: Icons.person_outline,
                      label: 'Họ tên',
                      value: student.fullName,
                    ),
                    _StudentInfoRow(
                      icon: Icons.alternate_email,
                      label: 'Email',
                      value: student.email,
                    ),
                    _StudentInfoRow(
                      icon: Icons.badge_outlined,
                      label: 'Mã số SV',
                      value: student.studentCode,
                    ),
                    const SizedBox(height: 14),
                    Text(
                      'Không tải được lịch sử: ${snapshot.error}',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ],
                );
              }

              final detail = snapshot.data!;
              final ratePercent = detail.totalSlots > 0
                  ? '${((detail.attendedSlots / detail.totalSlots) * 100).toStringAsFixed(1)}%'
                  : '0%';

              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _StudentInfoRow(
                    icon: Icons.person_outline,
                    label: 'Họ tên',
                    value: detail.student.fullName,
                  ),
                  _StudentInfoRow(
                    icon: Icons.alternate_email,
                    label: 'Email',
                    value: detail.student.email,
                  ),
                  _StudentInfoRow(
                    icon: Icons.badge_outlined,
                    label: 'Mã số SV',
                    value: detail.student.studentCode,
                  ),
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF0FDFA),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: const Color(0xFFCCFBF1)),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Tỷ lệ có mặt',
                                style: TextStyle(
                                  fontSize: 13,
                                  color: Color(0xFF0F766E),
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                ratePercent,
                                style: const TextStyle(
                                  fontSize: 28,
                                  fontWeight: FontWeight.w800,
                                  color: Color(0xFF0F766E),
                                ),
                              ),
                              Text(
                                '${detail.attendedSlots} / ${detail.totalSlots} buổi',
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: Color(0xFF64748B),
                                ),
                              ),
                            ],
                          ),
                        ),
                        Container(
                          height: 50,
                          width: 1,
                          color: const Color(0xFFCCFBF1),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('Đã mở: ${detail.openedSlots} buổi'),
                              const SizedBox(height: 4),
                              Text('Có phép: ${detail.excusedSlots} buổi'),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
        ),
        actions: [
          FilledButton.tonal(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Đóng'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: const Color(0xFFF8FAFC),
        appBar: AppBar(
          automaticallyImplyLeading: false,
          elevation: 0,
          backgroundColor: Colors.white,
          foregroundColor: const Color(0xFF0F172A),
          title: Row(
            children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: const Color(0xFFF1F5F9),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.qr_code_2_rounded,
                      size: 20,
                      color: Color(0xFF0F766E),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '${session.subject} · ${session.classCode}',
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF0F172A),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Flexible(
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: const Color(0xFFE0F2FE),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    'Buổi ${session.slot}${session.slotCount > 0 ? '/${session.slotCount}' : ''} · Slot ${session.daySlot ?? '—'} · ${_formatDate(session.date)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF0369A1),
                    ),
                  ),
                ),
              ),
            ],
          ),
          actions: [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: FilledButton.tonalIcon(
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFFF0FDFA),
                  foregroundColor: const Color(0xFF0F766E),
                ),
                onPressed: _openFullscreenQr,
                icon: const Icon(Icons.fullscreen, size: 20),
                label: const Text(
                  'Phóng to QR',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Padding(
              padding: const EdgeInsets.only(right: 20, top: 8, bottom: 8),
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFFE11D48),
                  foregroundColor: Colors.white,
                ),
                onPressed: _stopping ? null : _stop,
                icon: _stopping
                    ? const SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.stop_circle_outlined, size: 20),
                label: const Text(
                  'Ngừng điểm danh',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
            ),
          ],
        ),
        body: StreamBuilder<LiveAttendanceState>(
          stream: _liveStream,
          builder: (context, snapshot) {
            final state = snapshot.data ?? const LiveAttendanceLoading();

            return LayoutBuilder(
              builder: (context, constraints) {
                final isDesktopWide = constraints.maxWidth >= 960;

                if (isDesktopWide) {
                  return Padding(
                    padding: const EdgeInsets.all(24),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Cột trái: Control & QR Panel (chiếm ~30%)
                        SizedBox(
                          width: 340,
                          child: SingleChildScrollView(
                            child: _buildControlSidePanel(context),
                          ),
                        ),
                        const SizedBox(width: 24),
                        // Cột phải: Command Center (chiếm ~70% trung tâm)
                        Expanded(
                          child: _buildMainContent(context, state),
                        ),
                      ],
                    ),
                  );
                }

                // Khi cửa sổ bị thu nhỏ: bố cục cột cuộn dọc, không overflow
                return SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: [
                      _buildControlSidePanel(context),
                      const SizedBox(height: 20),
                      SizedBox(
                        height: 600,
                        child: _buildMainContent(context, state),
                      ),
                    ],
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }

  /// Cột điều khiển và hiển thị QR bên trái
  Widget _buildControlSidePanel(BuildContext context) {
    final session = widget.session;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Card QR động
        Card(
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: const BorderSide(color: Color(0xFFE2E8F0)),
          ),
          color: Colors.white,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                // Header card
                Row(
                  children: [
                    const Icon(
                      Icons.fiber_manual_record,
                      size: 12,
                      color: Color(0xFF10B981),
                    ),
                    const SizedBox(width: 5),
                    const Text(
                      'Trực tiếp',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF0F766E),
                      ),
                    ),
                    const Spacer(),
                    ValueListenableBuilder<int>(
                      valueListenable: _secondsLeftNotifier,
                      builder: (context, seconds, _) {
                        return Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xFFF1F5F9),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            'Đổi sau: ${seconds.toString().padLeft(2, '0')}s',
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: Color(0xFF475569),
                            ),
                          ),
                        );
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                // QR Container
                if (_qr == null)
                  const SizedBox.square(
                    dimension: 210,
                    child: Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          CircularProgressIndicator(strokeWidth: 3),
                          SizedBox(height: 12),
                          Text('Đang nạp mã QR…'),
                        ],
                      ),
                    ),
                  )
                else
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: const Color(0xFFE2E8F0)),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.04),
                          blurRadius: 10,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: QrImageView(
                      data: _qr!.url,
                      version: QrVersions.auto,
                      size: 200,
                      gapless: false,
                    ),
                  ),
                const SizedBox(height: 12),
                // Nút Phóng to QR
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFF0F766E),
                      side: const BorderSide(color: Color(0xFF0F766E)),
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    onPressed: _openFullscreenQr,
                    icon: const Icon(Icons.fullscreen, size: 20),
                    label: const Text(
                      'Phóng to cho máy chiếu',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  'Tự đổi mã mỗi ${session.rotationSeconds}s · Hiệu lực ${session.validitySeconds}s',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 11,
                    color: Color(0xFF64748B),
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 10),
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFFE4E6),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      _error!,
                      style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xFFE11D48),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        // Card thông tin nhanh
        Card(
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: const BorderSide(color: Color(0xFFE2E8F0)),
          ),
          color: Colors.white,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Column(
              children: [
                _InfoRowSimple(
                  icon: Icons.calendar_today_outlined,
                  label: 'Ngày học',
                  value: _formatDate(session.date),
                  badgeColor: const Color(0xFFF1F5F9),
                  textColor: const Color(0xFF334155),
                ),
                const SizedBox(height: 6),
                _InfoRowSimple(
                  icon: Icons.access_time_outlined,
                  label: 'Ca học',
                  value: 'Slot ${session.daySlot ?? '—'}',
                  badgeColor: const Color(0xFFE0F2FE),
                  textColor: const Color(0xFF0369A1),
                ),
                const SizedBox(height: 6),
                _InfoRowSimple(
                  icon: Icons.layers_outlined,
                  label: 'Tiến độ môn',
                  value:
                      'Buổi ${session.slot} / ${session.slotCount > 0 ? session.slotCount : '?'}',
                  badgeColor: const Color(0xFFCCFBF1),
                  textColor: const Color(0xFF0F766E),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// Khu vực nội dung chính chiếm 70% trung tâm
  Widget _buildMainContent(BuildContext context, LiveAttendanceState state) {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: Color(0xFFE2E8F0)),
      ),
      color: Colors.white,
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Thống kê nhanh & Progress bar
          _buildStatsHeader(state),
          const Divider(height: 1),
          // Thanh tìm kiếm và bộ lọc trạng thái
          _buildSearchAndFilterBar(state),
          const Divider(height: 1),
          // Bảng danh sách sinh viên
          Expanded(
            child: _buildStudentListBody(state),
          ),
        ],
      ),
    );
  }

  /// Thanh thống kê số liệu và tỷ lệ chuyên cần
  Widget _buildStatsHeader(LiveAttendanceState state) {
    if (state is! LiveAttendanceLoaded) {
      return Container(
        padding: const EdgeInsets.all(20),
        child: const Row(
          children: [
            Text(
              'Đang chuẩn bị dữ liệu lớp học…',
              style: TextStyle(color: Color(0xFF64748B)),
            ),
          ],
        ),
      );
    }

    final stats = state.stats;
    final hasSyncError = state.students.any((s) => s.syncStatus == 'error');

    return Container(
      padding: const EdgeInsets.all(20),
      color: Colors.white,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 4 thẻ thống kê trải đều 100% chiều rộng trên desktop
          LayoutBuilder(
            builder: (context, constraints) {
              if (constraints.maxWidth >= 600) {
                return Row(
                  children: [
                    Expanded(
                      child: _MetricCard(
                        label: 'Tổng số sinh viên',
                        count: '${stats.totalActive}',
                        icon: Icons.groups_outlined,
                        color: const Color(0xFF0F766E),
                        bgColor: const Color(0xFFF0FDFA),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _MetricCard(
                        label: 'Đã điểm danh',
                        count: '${stats.presentCount}',
                        icon: Icons.check_circle_outline_rounded,
                        color: const Color(0xFF059669),
                        bgColor: const Color(0xFFECFDF5),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _MetricCard(
                        label: 'Chưa điểm danh',
                        count: '${stats.notYetOpenCount}',
                        icon: Icons.pending_outlined,
                        color: const Color(0xFFD97706),
                        bgColor: const Color(0xFFFFFBEB),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _MetricCard(
                        label: 'Có phép / Vắng',
                        count: '${stats.excusedCount + stats.absentCount}',
                        icon: Icons.event_busy_outlined,
                        color: const Color(0xFF7C3AED),
                        bgColor: const Color(0xFFF5F3FF),
                      ),
                    ),
                  ],
                );
              }
              // Màn hình hẹp thì cho phép cuộn ngang mượt mà
              return SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    _MetricCard(
                      label: 'Tổng số sinh viên',
                      count: '${stats.totalActive}',
                      icon: Icons.groups_outlined,
                      color: const Color(0xFF0F766E),
                      bgColor: const Color(0xFFF0FDFA),
                    ),
                    const SizedBox(width: 12),
                    _MetricCard(
                      label: 'Đã điểm danh',
                      count: '${stats.presentCount}',
                      icon: Icons.check_circle_outline_rounded,
                      color: const Color(0xFF059669),
                      bgColor: const Color(0xFFECFDF5),
                    ),
                    const SizedBox(width: 12),
                    _MetricCard(
                      label: 'Chưa điểm danh',
                      count: '${stats.notYetOpenCount}',
                      icon: Icons.pending_outlined,
                      color: const Color(0xFFD97706),
                      bgColor: const Color(0xFFFFFBEB),
                    ),
                    const SizedBox(width: 12),
                    _MetricCard(
                      label: 'Có phép / Vắng',
                      count: '${stats.excusedCount + stats.absentCount}',
                      icon: Icons.event_busy_outlined,
                      color: const Color(0xFF7C3AED),
                      bgColor: const Color(0xFFF5F3FF),
                    ),
                  ],
                ),
              );
            },
          ),
          if (hasSyncError) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                color: const Color(0xFFFFF1F2),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFFFECDD3)),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.sync_problem,
                    size: 18,
                    color: Color(0xFFE11D48),
                  ),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'Có lỗi đồng bộ Google Sheets ở một số lượt điểm danh.',
                      style: TextStyle(
                        fontSize: 12,
                        color: Color(0xFFE11D48),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  TextButton.icon(
                    style: TextButton.styleFrom(
                      foregroundColor: const Color(0xFFE11D48),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                    ),
                    onPressed: _retryingSync ? null : _retrySheetSync,
                    icon: _retryingSync
                        ? const SizedBox.square(
                            dimension: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.refresh_rounded, size: 16),
                    label: const Text(
                      'Thử lại ngay',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 16),
          // Thanh Progress bar tỷ lệ
          Row(
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: LinearProgressIndicator(
                    value: stats.rate,
                    minHeight: 8,
                    backgroundColor: const Color(0xFFE2E8F0),
                    valueColor: const AlwaysStoppedAnimation<Color>(
                      Color(0xFF059669),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Text(
                'Tỷ lệ có mặt: ${stats.percentageFormatted}',
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF0F766E),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Thanh tìm kiếm và các Chip lọc trạng thái
  Widget _buildSearchAndFilterBar(LiveAttendanceState state) {
    int totalCount = 0;
    int presentCount = 0;
    int notYetCount = 0;
    int otherCount = 0;

    if (state is LiveAttendanceLoaded) {
      totalCount = state.stats.totalActive;
      presentCount = state.stats.presentCount;
      notYetCount = state.stats.notYetOpenCount;
      otherCount = state.stats.excusedCount + state.stats.absentCount;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      color: const Color(0xFFF8FAFC),
      child: Row(
        children: [
          // Ô tìm kiếm
          Expanded(
            flex: 3,
            child: SizedBox(
              height: 38,
              child: TextField(
                onChanged: (val) => setState(() => _searchQuery = val),
                decoration: InputDecoration(
                  hintText: 'Tìm kiếm theo MSSV, Họ tên hoặc Email…',
                  hintStyle: const TextStyle(
                    fontSize: 13,
                    color: Color(0xFF94A3B8),
                  ),
                  prefixIcon: const Icon(
                    Icons.search,
                    size: 18,
                    color: Color(0xFF64748B),
                  ),
                  suffixIcon: _searchQuery.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.clear, size: 16),
                          onPressed: () => setState(() => _searchQuery = ''),
                        )
                      : null,
                  filled: true,
                  fillColor: Colors.white,
                  contentPadding: EdgeInsets.zero,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(color: Color(0xFFCBD5E1)),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(
                      color: Color(0xFF0F766E),
                      width: 1.5,
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          // Filter chips cuộn ngang linh hoạt
          Expanded(
            flex: 4,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _FilterChip(
                    label: 'Tất cả ($totalCount)',
                    isSelected: _selectedFilter == AttendanceFilter.all,
                    onSelected: () =>
                        setState(() => _selectedFilter = AttendanceFilter.all),
                  ),
                  const SizedBox(width: 8),
                  _FilterChip(
                    label: 'Đã điểm danh ($presentCount)',
                    isSelected: _selectedFilter == AttendanceFilter.present,
                    color: const Color(0xFF059669),
                    onSelected: () => setState(
                        () => _selectedFilter = AttendanceFilter.present),
                  ),
                  const SizedBox(width: 8),
                  _FilterChip(
                    label: 'Chưa điểm danh ($notYetCount)',
                    isSelected: _selectedFilter == AttendanceFilter.notYetOpen,
                    color: const Color(0xFFD97706),
                    onSelected: () => setState(
                        () => _selectedFilter = AttendanceFilter.notYetOpen),
                  ),
                  const SizedBox(width: 8),
                  _FilterChip(
                    label: 'Vắng/Phép ($otherCount)',
                    isSelected: _selectedFilter == AttendanceFilter.other,
                    color: const Color(0xFF7C3AED),
                    onSelected: () => setState(
                        () => _selectedFilter = AttendanceFilter.other),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Danh sách sinh viên
  Widget _buildStudentListBody(LiveAttendanceState state) {
    if (state is LiveAttendanceLoading) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(strokeWidth: 3),
            SizedBox(height: 16),
            Text(
              'Đang tải danh sách lớp học…',
              style: TextStyle(color: Color(0xFF64748B)),
            ),
          ],
        ),
      );
    }

    if (state is LiveAttendanceError) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(
                Icons.error_outline_rounded,
                size: 48,
                color: Color(0xFFE11D48),
              ),
              const SizedBox(height: 16),
              Text(
                state.message,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Color(0xFFE11D48)),
              ),
            ],
          ),
        ),
      );
    }

    if (state is LiveAttendanceEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(
                Icons.people_outline_rounded,
                size: 48,
                color: Color(0xFF94A3B8),
              ),
              const SizedBox(height: 16),
              Text(
                state.message,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Color(0xFF64748B),
                  fontSize: 16,
                ),
              ),
            ],
          ),
        ),
      );
    }

    final loaded = state as LiveAttendanceLoaded;
    final query = _searchQuery.trim().toLowerCase();

    // Lọc theo tìm kiếm và filter chip
    final filtered = loaded.students.where((item) {
      // 1. Lọc theo trạng thái chip
      switch (_selectedFilter) {
        case AttendanceFilter.present:
          if (!item.isPresent) return false;
          break;
        case AttendanceFilter.notYetOpen:
          if (!item.isNotYetOpen) return false;
          break;
        case AttendanceFilter.other:
          if (item.isPresent || item.isNotYetOpen) return false;
          break;
        case AttendanceFilter.all:
          break;
      }

      // 2. Lọc theo chuỗi tìm kiếm
      if (query.isEmpty) return true;
      return item.studentCode.toLowerCase().contains(query) ||
          item.fullName.toLowerCase().contains(query) ||
          item.email.toLowerCase().contains(query);
    }).toList();

    if (filtered.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Text(
            'Không tìm thấy sinh viên nào phù hợp với bộ lọc.',
            style: TextStyle(color: Color(0xFF64748B), fontSize: 15),
          ),
        ),
      );
    }

    // Hiển thị dạng bảng ảo hóa (ListView.builder) cho hiệu năng 60 FPS
    return Column(
      children: [
        // Bảng header
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
          color: const Color(0xFFF1F5F9),
          child: const Row(
            children: [
              SizedBox(
                width: 44,
                child: Text(
                  'STT',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                    color: Color(0xFF475569),
                  ),
                ),
              ),
              SizedBox(
                width: 110,
                child: Text(
                  'MSSV',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                    color: Color(0xFF475569),
                  ),
                ),
              ),
              Expanded(
                flex: 3,
                child: Text(
                  'Họ và tên',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                    color: Color(0xFF475569),
                  ),
                ),
              ),
              SizedBox(
                width: 150,
                child: Text(
                  'Trạng thái',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                    color: Color(0xFF475569),
                  ),
                ),
              ),
              SizedBox(
                width: 110,
                child: Text(
                  'Giờ quét',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                    color: Color(0xFF475569),
                  ),
                ),
              ),
              SizedBox(
                width: 80,
                child: Text(
                  'Sheets',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                    color: Color(0xFF475569),
                  ),
                ),
              ),
              SizedBox(width: 40),
            ],
          ),
        ),
        // Danh sách sinh viên
        Expanded(
          child: ListView.separated(
            itemCount: filtered.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final item = filtered[index];
              return _StudentListTile(
                index: index + 1,
                item: item,
                onTap: () => _showStudentDetail(item.student),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// Dòng hiển thị thông tin sinh viên với hiệu ứng highlight
class _StudentListTile extends StatelessWidget {
  const _StudentListTile({
    required this.index,
    required this.item,
    required this.onTap,
  });

  final int index;
  final LiveStudentAttendance item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final isRecent = item.isRecent;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 400),
      color: isRecent ? const Color(0xFFECFDF5) : Colors.transparent,
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
      child: Row(
        children: [
          // STT
          SizedBox(
            width: 44,
            child: Text(
              index.toString().padLeft(2, '0'),
              style: const TextStyle(
                fontSize: 13,
                color: Color(0xFF64748B),
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          // MSSV
          SizedBox(
            width: 110,
            child: Text(
              item.studentCode.isEmpty ? '—' : item.studentCode,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontWeight: FontWeight.w800,
                fontSize: 13,
                color: Color(0xFF0F172A),
              ),
            ),
          ),
          // Họ tên & email
          Expanded(
            flex: 3,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        item.fullName.isEmpty
                            ? item.email
                            : item.fullName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight:
                              isRecent ? FontWeight.w800 : FontWeight.w600,
                          color: const Color(0xFF0F172A),
                        ),
                      ),
                    ),
                    if (isRecent) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFF10B981),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: const Text(
                          'Vừa quét',
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w800,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                Text(
                  item.email,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xFF64748B),
                  ),
                ),
              ],
            ),
          ),
          // Trạng thái điểm danh (Badge)
          SizedBox(
            width: 150,
            child: _buildStatusBadge(item.status),
          ),
          // Giờ quét
          SizedBox(
            width: 110,
            child: Text(
              item.formattedCheckInTime,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: item.isPresent
                    ? const Color(0xFF0F172A)
                    : const Color(0xFF94A3B8),
              ),
            ),
          ),
          // Trạng thái Google Sheets
          SizedBox(
            width: 80,
            child: Center(
              child: _buildSyncIcon(item.syncStatus, item.syncError),
            ),
          ),
          // Nút xem chi tiết
          SizedBox(
            width: 40,
            child: IconButton(
              icon: const Icon(
                Icons.chevron_right_rounded,
                size: 20,
                color: Color(0xFF94A3B8),
              ),
              onPressed: onTap,
              tooltip: 'Xem hồ sơ sinh viên',
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusBadge(AttendanceStatus status) {
    Widget badge;
    switch (status) {
      case AttendanceStatus.present:
        badge = Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: const Color(0xFFECFDF5),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: const Color(0xFFA7F3D0)),
          ),
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.check_circle_rounded,
                size: 14,
                color: Color(0xFF059669),
              ),
              SizedBox(width: 4),
              Text(
                'Đã điểm danh',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF059669),
                ),
              ),
            ],
          ),
        );
        break;
      case AttendanceStatus.notYetOpen:
        badge = Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: const Color(0xFFFFFBEB),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: const Color(0xFFFDE68A)),
          ),
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.hourglass_empty_rounded,
                size: 14,
                color: Color(0xFFD97706),
              ),
              SizedBox(width: 4),
              Text(
                'Chưa điểm danh',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFFD97706),
                ),
              ),
            ],
          ),
        );
        break;
      case AttendanceStatus.excused:
        badge = Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: const Color(0xFFF5F3FF),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: const Color(0xFFDDD6FE)),
          ),
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.verified_user_rounded,
                size: 14,
                color: Color(0xFF7C3AED),
              ),
              SizedBox(width: 4),
              Text(
                'Có phép',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF7C3AED),
                ),
              ),
            ],
          ),
        );
        break;
      case AttendanceStatus.absent:
        badge = Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: const Color(0xFFFFE4E6),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: const Color(0xFFFECDD3)),
          ),
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.cancel_rounded,
                size: 14,
                color: Color(0xFFE11D48),
              ),
              SizedBox(width: 4),
              Text(
                'Vắng mặt',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFFE11D48),
                ),
              ),
            ],
          ),
        );
        break;
    }

    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.centerLeft,
      child: badge,
    );
  }

  Widget _buildSyncIcon(String? syncStatus, String? syncError) {
    if (syncStatus == null) {
      return const Text('—', style: TextStyle(color: Color(0xFF94A3B8)));
    }

    if (syncStatus == 'synced') {
      return const Tooltip(
        message: 'Đã đồng bộ sang Google Sheets',
        child: Icon(
          Icons.cloud_done_rounded,
          size: 18,
          color: Color(0xFF059669),
        ),
      );
    }

    if (syncStatus == 'error') {
      return Tooltip(
        message: 'Lỗi đồng bộ: ${syncError ?? "Không rõ"}',
        child: const Icon(
          Icons.cloud_off_rounded,
          size: 18,
          color: Color(0xFFE11D48),
        ),
      );
    }

    return const Tooltip(
      message: 'Đang chờ đồng bộ Google Sheets',
      child: Icon(
        Icons.cloud_upload_outlined,
        size: 18,
        color: Color(0xFFD97706),
      ),
    );
  }
}

/// Dialog phóng to mã QR cho máy chiếu lớp học (Dark cinema style)
class _FullscreenQrDialog extends StatelessWidget {
  const _FullscreenQrDialog({
    required this.session,
    required this.qrNotifier,
    required this.countdownNotifier,
  });

  final AttendanceSession session;
  final ValueNotifier<IssuedQr?> qrNotifier;
  final ValueNotifier<int> countdownNotifier;

  @override
  Widget build(BuildContext context) {
    // Lắng nghe phím ESC để đóng dialog tiện lợi trên máy tính
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            Navigator.of(context).pop(),
      },
      child: Focus(
        autofocus: true,
        child: Dialog(
          insetPadding: EdgeInsets.zero,
          backgroundColor: Colors.transparent,
          child: Container(
            width: double.infinity,
            height: double.infinity,
            color: const Color(0xFF0F172A).withValues(alpha: 0.96),
            child: SafeArea(
              child: Column(
                children: [
                  // Top bar
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 32,
                      vertical: 20,
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${session.subject} · ${session.classCode}',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 24,
                                fontWeight: FontWeight.w900,
                                letterSpacing: 0.5,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'Buổi ${session.slot}${session.slotCount > 0 ? '/${session.slotCount}' : ''} · Slot ${session.daySlot ?? '—'} · ${session.date}',
                              style: const TextStyle(
                                color: Color(0xFF94A3B8),
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 14,
                                vertical: 6,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.white.withValues(alpha: 0.1),
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: const Row(
                                children: [
                                  Text(
                                    'ESC để thoát',
                                    style: TextStyle(
                                      color: Color(0xFF94A3B8),
                                      fontSize: 12,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 12),
                            IconButton(
                              style: IconButton.styleFrom(
                                backgroundColor:
                                    Colors.white.withValues(alpha: 0.15),
                              ),
                              icon: const Icon(
                                Icons.close_rounded,
                                color: Colors.white,
                                size: 26,
                              ),
                              onPressed: () => Navigator.of(context).pop(),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  // Khu vực QR trung tâm
                  Expanded(
                    child: Center(
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          final qrSize = min(
                            constraints.maxWidth * 0.7,
                            constraints.maxHeight * 0.7,
                          );

                          return ValueListenableBuilder<IssuedQr?>(
                            valueListenable: qrNotifier,
                            builder: (context, qr, _) {
                              if (qr == null) {
                                return const CircularProgressIndicator(
                                  color: Colors.white,
                                );
                              }

                              return Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Container(
                                    padding: const EdgeInsets.all(24),
                                    decoration: BoxDecoration(
                                      color: Colors.white,
                                      borderRadius: BorderRadius.circular(28),
                                      boxShadow: [
                                        BoxShadow(
                                          color: Colors.black
                                              .withValues(alpha: 0.5),
                                          blurRadius: 40,
                                          spreadRadius: 8,
                                        ),
                                      ],
                                    ),
                                    child: QrImageView(
                                      data: qr.url,
                                      version: QrVersions.auto,
                                      size: qrSize,
                                      gapless: false,
                                    ),
                                  ),
                                  const SizedBox(height: 24),
                                  ValueListenableBuilder<int>(
                                    valueListenable: countdownNotifier,
                                    builder: (context, seconds, _) {
                                      return Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 16,
                                          vertical: 8,
                                        ),
                                        decoration: BoxDecoration(
                                          color: Colors.white
                                              .withValues(alpha: 0.1),
                                          borderRadius:
                                              BorderRadius.circular(30),
                                        ),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            const Icon(
                                              Icons.sync_rounded,
                                              size: 16,
                                              color: Color(0xFF2DD4BF),
                                            ),
                                            const SizedBox(width: 8),
                                            Text(
                                              'Mã tự động đổi sau: ${seconds.toString().padLeft(2, '0')} giây',
                                              style: const TextStyle(
                                                color: Colors.white,
                                                fontSize: 14,
                                                fontWeight: FontWeight.w700,
                                              ),
                                            ),
                                          ],
                                        ),
                                      );
                                    },
                                  ),
                                ],
                              );
                            },
                          );
                        },
                      ),
                    ),
                  ),
                  // Hướng dẫn sinh viên ở chân trang
                  Padding(
                    padding: const EdgeInsets.only(bottom: 28),
                    child: Column(
                      children: [
                        const Text(
                          'Sinh viên mở web điểm danh và quét mã QR trên màn hình máy chiếu',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Không chia sẻ liên kết ra ngoài lớp học',
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.6),
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Thẻ số liệu thống kê ở header
class _MetricCard extends StatelessWidget {
  const _MetricCard({
    required this.label,
    required this.count,
    required this.icon,
    required this.color,
    required this.bgColor,
  });

  final String label;
  final String count;
  final IconData icon;
  final Color color;
  final Color bgColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.2)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 20, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  count,
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w900,
                    color: color,
                  ),
                ),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: color.withValues(alpha: 0.8),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Filter chip
class _FilterChip extends StatelessWidget {
  const _FilterChip({
    required this.label,
    required this.isSelected,
    required this.onSelected,
    this.color = const Color(0xFF0F766E),
  });

  final String label;
  final bool isSelected;
  final VoidCallback onSelected;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onSelected,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected ? color : Colors.white,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isSelected ? color : const Color(0xFFCBD5E1),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
            color: isSelected ? Colors.white : const Color(0xFF475569),
          ),
        ),
      ),
    );
  }
}

class _InfoRowSimple extends StatelessWidget {
  const _InfoRowSimple({
    required this.icon,
    required this.label,
    required this.value,
    this.badgeColor = const Color(0xFFF1F5F9),
    this.textColor = const Color(0xFF0F172A),
  });

  final IconData icon;
  final String label;
  final String value;
  final Color badgeColor;
  final Color textColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 16, color: const Color(0xFF0F766E)),
              const SizedBox(width: 8),
              Text(
                label,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF64748B),
                ),
              ),
            ],
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: badgeColor,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                  color: textColor,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _StudentInfoRow extends StatelessWidget {
  const _StudentInfoRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 20, color: const Color(0xFF0F766E)),
            const SizedBox(width: 12),
            SizedBox(
              width: 100,
              child: Text(
                label,
                style: const TextStyle(
                  color: Color(0xFF64748B),
                  fontSize: 13,
                ),
              ),
            ),
            Expanded(
              child: SelectableText(
                value.isEmpty ? '—' : value,
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                  color: Color(0xFF0F172A),
                ),
              ),
            ),
          ],
        ),
      );
}
