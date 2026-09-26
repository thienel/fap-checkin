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
import '../theme/app_theme.dart';
import '../widgets/app_ui.dart';

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
  Timer? _checkoutRetryTimer;

  IssuedQr? _qr;
  final ValueNotifier<IssuedQr?> _qrNotifier = ValueNotifier<IssuedQr?>(null);
  late final ValueNotifier<int> _secondsLeftNotifier;
  late final ValueNotifier<int> _checkoutSecondsLeftNotifier;
  late String _checkoutCode;
  late DateTime? _checkoutCodeIssuedAt;

  bool _issuing = false;
  bool _rotatingCheckoutCode = false;
  bool _stopping = false;
  bool _stopCompleted = false;
  bool _retryingSync = false;
  String? _error;
  String? _stopError;
  String? _checkoutError;

  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();
  AttendanceFilter _selectedFilter = AttendanceFilter.all;

  @override
  void initState() {
    super.initState();
    _service = widget.liveSessionService ?? LiveSessionService(api: widget.api);

    // Một subscription duy nhất cho toàn bộ vòng đời của màn hình.
    // Xoay QR tuyệt đối không unsubscribe hoặc reset stream danh sách.
    _liveStream = _service.watchLiveAttendance(session: widget.session);

    _secondsLeftNotifier = ValueNotifier<int>(widget.session.rotationSeconds);
    _checkoutSecondsLeftNotifier = ValueNotifier<int>(
      _checkoutSecondsRemaining(widget.session.checkoutCodeIssuedAt),
    );
    _checkoutCode = widget.session.checkoutCode;
    _checkoutCodeIssuedAt = widget.session.checkoutCodeIssuedAt;

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
      _checkoutSecondsLeftNotifier.value = _checkoutSecondsRemaining(
        _checkoutCodeIssuedAt,
      );
      if (_checkoutSecondsLeftNotifier.value == 0 && _checkoutError == null) {
        unawaited(_rotateCheckoutCode());
      }
    });
  }

  @override
  void dispose() {
    _rotationTimer?.cancel();
    _countdownTimer?.cancel();
    _checkoutRetryTimer?.cancel();
    _qrNotifier.dispose();
    _secondsLeftNotifier.dispose();
    _checkoutSecondsLeftNotifier.dispose();
    _searchController.dispose();
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

  Future<void> _rotateCheckoutCode() async {
    if (_rotatingCheckoutCode || _stopping || _checkoutCode.isEmpty) return;
    _rotatingCheckoutCode = true;
    _checkoutRetryTimer?.cancel();
    try {
      final rotated = await widget.api.rotateCheckoutCode(widget.session.id);
      if (mounted) {
        setState(() {
          _checkoutCode = rotated.code;
          _checkoutCodeIssuedAt = rotated.issuedAt;
          _checkoutSecondsLeftNotifier.value = _checkoutSecondsRemaining(
            rotated.issuedAt,
          );
          _checkoutError = null;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() => _checkoutError = 'Không thể đổi checkout code: $error');
        _checkoutRetryTimer = Timer(const Duration(seconds: 5), () {
          if (!mounted) return;
          setState(() => _checkoutError = null);
          unawaited(_rotateCheckoutCode());
        });
      }
    } finally {
      _rotatingCheckoutCode = false;
    }
  }

  int _checkoutSecondsRemaining(DateTime? issuedAt) {
    if (issuedAt == null) return widget.session.checkoutRotationSeconds;
    final elapsed = DateTime.now().difference(issuedAt).inSeconds;
    final remaining = widget.session.checkoutRotationSeconds - elapsed;
    if (remaining <= 0) return 0;
    if (remaining > widget.session.checkoutRotationSeconds) {
      return widget.session.checkoutRotationSeconds;
    }
    return remaining;
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
            Icon(Icons.warning_amber_rounded, color: AppColors.error),
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
            style: FilledButton.styleFrom(backgroundColor: AppColors.error),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Xác nhận ngừng'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    setState(() {
      _stopping = true;
      _stopError = null;
    });
    try {
      final warnings = await widget.api.stopAttendance(widget.session.id);
      if (!mounted) return;
      _finishStop(warnings);
    } catch (error) {
      if (!mounted) return;
      var stopError = 'Không thể ngừng phiên: $error';
      try {
        if (!await widget.api.isAttendanceActive(widget.session.id)) {
          if (mounted) {
            _finishStop([
              'Phiên đã đóng nhưng chưa xác minh được bước dọn dẹp: $error',
            ]);
          }
          return;
        }
      } catch (verificationError) {
        if (!mounted) return;
        stopError = 'Không xác minh được trạng thái phiên: $verificationError';
      }
      if (!mounted) return;
      setState(() {
        _stopping = false;
        _stopError = stopError;
      });
      unawaited(_issueQr());
      if (_checkoutSecondsLeftNotifier.value == 0) {
        unawaited(_rotateCheckoutCode());
      }
    }
  }

  void _finishStop(List<String> warnings) {
    _rotationTimer?.cancel();
    _countdownTimer?.cancel();
    _checkoutRetryTimer?.cancel();
    if (warnings.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Đã ngừng phiên. ${warnings.join(' ')}')),
      );
    }
    setState(() => _stopCompleted = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).pop();
    });
  }

  Future<void> _retrySheetSync() async {
    if (_retryingSync) return;
    setState(() => _retryingSync = true);
    try {
      final result = await widget.api.syncPendingCheckIns(force: true);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            result.notConfigured
                ? 'Google Sheets chưa được cấu hình.'
                : 'Đã đồng bộ ${result.synced} bản ghi; còn chờ ${result.pending}, lỗi ${result.error}.',
          ),
          backgroundColor: AppColors.primary,
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Đồng bộ Google Sheets thất bại: $error'),
          backgroundColor: AppColors.error,
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

  void _showStudentDetail(LiveStudentAttendance attendance) {
    final student = attendance.student;
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Icons.badge_outlined, color: AppColors.primary),
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
                      color: AppColors.successSurface,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: AppColors.successSurface),
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
                                  color: AppColors.primary,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                ratePercent,
                                style: const TextStyle(
                                  fontSize: 28,
                                  fontWeight: FontWeight.w800,
                                  color: AppColors.primary,
                                ),
                              ),
                              Text(
                                '${detail.attendedSlots} / ${detail.totalSlots} buổi',
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: AppColors.textMuted,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Container(
                          height: 50,
                          width: 1,
                          color: AppColors.successSurface,
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
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Đóng'),
          ),
          FilledButton.icon(
            onPressed: () {
              Navigator.of(dialogContext).pop();
              unawaited(_editLiveAttendance(attendance));
            },
            icon: const Icon(Icons.edit_outlined),
            label: const Text('Sửa trạng thái'),
          ),
        ],
      ),
    );
  }

  Future<({AttendanceStatus status, String reason})?> _attendanceChangeDialog(
    LiveStudentAttendance attendance,
  ) {
    var selected = attendance.status == AttendanceStatus.notYetOpen
        ? AttendanceStatus.absent
        : attendance.status;
    var reason = '';
    return showDialog<({AttendanceStatus status, String reason})>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Cập nhật trạng thái điểm danh'),
          content: SizedBox(
            width: 440,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${attendance.displayName} · Buổi ${widget.session.slot}',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 6),
                Text(
                  'Hiện tại: ${_attendanceStatusLabel(attendance.status)}',
                  style: const TextStyle(color: AppColors.textMuted),
                ),
                const SizedBox(height: 16),
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
                const SizedBox(height: 12),
                TextField(
                  autofocus: true,
                  maxLength: 300,
                  onChanged: (value) => setDialogState(() => reason = value),
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
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Hủy'),
            ),
            FilledButton(
              onPressed: reason.trim().length < 3
                  ? null
                  : () => Navigator.pop(dialogContext, (
                      status: selected,
                      reason: reason.trim(),
                    )),
              child: const Text('Lưu thay đổi'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _editLiveAttendance(LiveStudentAttendance attendance) async {
    final change = await _attendanceChangeDialog(attendance);
    if (change == null || !mounted) return;
    try {
      final result = await widget.api.adjustAttendance(
        courseClassId: widget.session.courseClassId,
        slot: widget.session.slot,
        studentId: attendance.student.id,
        status: change.status,
        reason: change.reason,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            result.synced
                ? 'Đã cập nhật trạng thái điểm danh và Google Sheets.'
                : 'Đã lưu trạng thái điểm danh; chờ đồng bộ Google Sheets: ${result.syncError}',
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Cập nhật chưa hoàn tất: $error')));
    }
  }

  String _attendanceStatusLabel(AttendanceStatus status) => switch (status) {
    AttendanceStatus.present => 'Có mặt',
    AttendanceStatus.absent => 'Vắng',
    AttendanceStatus.excused => 'Có phép',
    AttendanceStatus.notYetOpen => 'Chưa điểm danh',
  };

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    return PopScope(
      canPop: _stopCompleted,
      child: Scaffold(
        backgroundColor: AppColors.canvas,
        appBar: AppBar(
          automaticallyImplyLeading: false,
          elevation: 0,
          toolbarHeight: 68,
          backgroundColor: AppColors.surface,
          foregroundColor: AppColors.text,
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '${session.subject} · ${session.classCode}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: AppSpace.xs),
              Text(
                'Buổi ${session.slot}${session.slotCount > 0 ? '/${session.slotCount}' : ''} · Slot ${session.daySlot ?? '—'} · ${_formatDate(session.date)}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 12,
                  color: AppColors.textMuted,
                ),
              ),
            ],
          ),
          actions: [
            Padding(
              padding: const EdgeInsets.only(right: 16, top: 12, bottom: 12),
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.error,
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
                final isDesktopWide = constraints.maxWidth >= 1160;

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
                        Expanded(child: _buildMainContent(context, state)),
                      ],
                    ),
                  );
                }

                // Khi cửa sổ bị thu nhỏ: bố cục cột cuộn dọc, không overflow
                return SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: [
                      Align(
                        alignment: Alignment.topLeft,
                        child: SizedBox(
                          width: min(340, constraints.maxWidth - 32),
                          child: _buildControlSidePanel(context),
                        ),
                      ),
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
                      color: AppColors.success,
                    ),
                    const SizedBox(width: 5),
                    const Text(
                      'Trực tiếp',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: AppColors.primary,
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
                            color: AppColors.surfaceMuted,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            'Đổi sau: ${seconds.toString().padLeft(2, '0')}s',
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: AppColors.textMuted,
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
                      border: Border.all(color: AppColors.border),
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
                      foregroundColor: AppColors.primary,
                      side: const BorderSide(color: AppColors.primary),
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    onPressed: _openFullscreenQr,
                    icon: const Icon(Icons.fullscreen, size: 20),
                    label: const Text(
                      'Phóng to QR',
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
                    color: AppColors.textMuted,
                  ),
                ),
                if (_error != null || _stopError != null) ...[
                  const SizedBox(height: 10),
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: AppColors.errorSurface,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      _stopError ?? _error!,
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppColors.error,
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
        Card(
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: const BorderSide(color: AppColors.border),
          ),
          color: AppColors.successSurface,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Row(
              children: [
                const Icon(Icons.key_rounded, color: AppColors.primary),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Checkout code',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: AppColors.primary,
                        ),
                      ),
                      const SizedBox(height: 4),
                      SelectableText(
                        _checkoutCode.isEmpty ? '—' : _checkoutCode,
                        style: const TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 3,
                          color: AppColors.primaryDark,
                        ),
                      ),
                      const SizedBox(height: 3),
                      ValueListenableBuilder<int>(
                        valueListenable: _checkoutSecondsLeftNotifier,
                        builder: (context, seconds, _) => Text(
                          'Code mới sau ${seconds.toString().padLeft(2, '0')} giây',
                          style: const TextStyle(
                            fontSize: 11,
                            color: AppColors.textMuted,
                          ),
                        ),
                      ),
                      if (_checkoutError != null) ...[
                        const SizedBox(height: 4),
                        Text(
                          _checkoutError!,
                          style: const TextStyle(
                            fontSize: 11,
                            color: AppColors.error,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Sao chép checkout code',
                  onPressed: _checkoutCode.isEmpty
                      ? null
                      : () async {
                          await Clipboard.setData(
                            ClipboardData(text: _checkoutCode),
                          );
                          if (!context.mounted) return;
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Đã sao chép checkout code.'),
                            ),
                          );
                        },
                  icon: const Icon(
                    Icons.copy_rounded,
                    color: AppColors.primary,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        // Card thông tin nhanh
        Card(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Column(
              children: [
                _InfoRowSimple(
                  icon: Icons.calendar_today_outlined,
                  label: 'Ngày học',
                  value: _formatDate(session.date),
                  badgeColor: AppColors.surfaceMuted,
                  textColor: AppColors.text,
                ),
                const SizedBox(height: 6),
                _InfoRowSimple(
                  icon: Icons.access_time_outlined,
                  label: 'Ca học',
                  value: 'Slot ${session.daySlot ?? '—'}',
                  badgeColor: AppColors.infoSurface,
                  textColor: AppColors.info,
                ),
                const SizedBox(height: 6),
                _InfoRowSimple(
                  icon: Icons.layers_outlined,
                  label: 'Tiến độ môn',
                  value:
                      'Buổi ${session.slot} / ${session.slotCount > 0 ? session.slotCount : '?'}',
                  badgeColor: AppColors.successSurface,
                  textColor: AppColors.primary,
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
          Expanded(child: _buildStudentListBody(state)),
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
              style: TextStyle(color: AppColors.textMuted),
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
                        color: AppColors.primary,
                        bgColor: AppColors.successSurface,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _MetricCard(
                        label: 'Đã điểm danh',
                        count: '${stats.presentCount}',
                        icon: Icons.check_circle_outline_rounded,
                        color: AppColors.success,
                        bgColor: AppColors.successSurface,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _MetricCard(
                        label: 'Chưa điểm danh',
                        count: '${stats.notYetOpenCount}',
                        icon: Icons.pending_outlined,
                        color: AppColors.warning,
                        bgColor: AppColors.warningSurface,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _MetricCard(
                        label: 'Có phép / Vắng',
                        count: '${stats.excusedCount + stats.absentCount}',
                        icon: Icons.event_busy_outlined,
                        color: AppColors.info,
                        bgColor: AppColors.infoSurface,
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
                      color: AppColors.primary,
                      bgColor: AppColors.successSurface,
                    ),
                    const SizedBox(width: 12),
                    _MetricCard(
                      label: 'Đã điểm danh',
                      count: '${stats.presentCount}',
                      icon: Icons.check_circle_outline_rounded,
                      color: AppColors.success,
                      bgColor: AppColors.successSurface,
                    ),
                    const SizedBox(width: 12),
                    _MetricCard(
                      label: 'Chưa điểm danh',
                      count: '${stats.notYetOpenCount}',
                      icon: Icons.pending_outlined,
                      color: AppColors.warning,
                      bgColor: AppColors.warningSurface,
                    ),
                    const SizedBox(width: 12),
                    _MetricCard(
                      label: 'Có phép / Vắng',
                      count: '${stats.excusedCount + stats.absentCount}',
                      icon: Icons.event_busy_outlined,
                      color: AppColors.info,
                      bgColor: AppColors.infoSurface,
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
                color: AppColors.errorSurface,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppColors.border),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.sync_problem,
                    size: 18,
                    color: AppColors.error,
                  ),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'Có lỗi đồng bộ Google Sheets ở một số lượt điểm danh.',
                      style: TextStyle(
                        fontSize: 12,
                        color: AppColors.error,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  TextButton.icon(
                    style: TextButton.styleFrom(
                      foregroundColor: AppColors.error,
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
                    backgroundColor: AppColors.border,
                    valueColor: const AlwaysStoppedAnimation<Color>(
                      AppColors.success,
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
                  color: AppColors.primary,
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
      color: AppColors.canvas,
      child: Row(
        children: [
          // Ô tìm kiếm
          Expanded(
            flex: 3,
            child: TextField(
              controller: _searchController,
              onChanged: (val) => setState(() => _searchQuery = val),
              decoration: InputDecoration(
                hintText: 'Tìm mã, tên hoặc email',
                prefixIcon: const Icon(
                  Icons.search,
                  size: 18,
                  color: AppColors.textMuted,
                ),
                suffixIcon: _searchQuery.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear, size: 16),
                        onPressed: () {
                          _searchController.clear();
                          setState(() => _searchQuery = '');
                        },
                      )
                    : null,
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
                    color: AppColors.success,
                    onSelected: () => setState(
                      () => _selectedFilter = AttendanceFilter.present,
                    ),
                  ),
                  const SizedBox(width: 8),
                  _FilterChip(
                    label: 'Chưa điểm danh ($notYetCount)',
                    isSelected: _selectedFilter == AttendanceFilter.notYetOpen,
                    color: AppColors.warning,
                    onSelected: () => setState(
                      () => _selectedFilter = AttendanceFilter.notYetOpen,
                    ),
                  ),
                  const SizedBox(width: 8),
                  _FilterChip(
                    label: 'Vắng/Phép ($otherCount)',
                    isSelected: _selectedFilter == AttendanceFilter.other,
                    color: AppColors.info,
                    onSelected: () => setState(
                      () => _selectedFilter = AttendanceFilter.other,
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
              style: TextStyle(color: AppColors.textMuted),
            ),
          ],
        ),
      );
    }

    if (state is LiveAttendanceError) {
      return AppEmptyState(
        icon: Icons.error_outline_rounded,
        title: 'Không tải được điểm danh',
        description: state.message,
      );
    }

    if (state is LiveAttendanceEmpty) {
      return AppEmptyState(
        icon: Icons.people_outline_rounded,
        title: 'Chưa có sinh viên',
        description: state.message,
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
      return const AppEmptyState(
        icon: Icons.filter_alt_off_outlined,
        title: 'Không tìm thấy sinh viên',
        description: 'Thử từ khóa hoặc trạng thái khác.',
      );
    }

    // Giữ các cột thẳng hàng và cho phép cuộn ngang khi cửa sổ hẹp.
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: SizedBox(
          width: max(720, constraints.maxWidth),
          height: constraints.maxHeight,
          child: Column(
            children: [
              // Bảng header
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 10,
                ),
                color: AppColors.surfaceMuted,
                child: const Row(
                  children: [
                    SizedBox(
                      width: 44,
                      child: Text(
                        'STT',
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 12,
                          color: AppColors.textMuted,
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
                          color: AppColors.textMuted,
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
                          color: AppColors.textMuted,
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
                          color: AppColors.textMuted,
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
                          color: AppColors.textMuted,
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
                          color: AppColors.textMuted,
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
                      onTap: () => _showStudentDetail(item),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
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

    return Material(
      color: isRecent ? AppColors.successSurface : AppColors.surface,
      child: InkWell(
        onTap: onTap,
        hoverColor: AppColors.surfaceMuted,
        child: Padding(
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
                    color: AppColors.textMuted,
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
                    color: AppColors.text,
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
                            item.fullName.isEmpty ? item.email : item.fullName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: isRecent
                                  ? FontWeight.w800
                                  : FontWeight.w600,
                              color: AppColors.text,
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
                              color: AppColors.success,
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
                        color: AppColors.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
              // Trạng thái điểm danh (Badge)
              SizedBox(
                width: 150,
                child: AppAttendanceBadge(
                  status: item.status,
                  pendingLabel: 'Chưa điểm danh',
                ),
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
                        ? AppColors.text
                        : AppColors.textMuted,
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
                    color: AppColors.textMuted,
                  ),
                  onPressed: onTap,
                  tooltip: 'Xem hồ sơ sinh viên',
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSyncIcon(String? syncStatus, String? syncError) {
    if (syncStatus == null) {
      return const Text('—', style: TextStyle(color: AppColors.textMuted));
    }

    if (syncStatus == 'synced') {
      return const Tooltip(
        message: 'Đã đồng bộ sang Google Sheets',
        child: Icon(
          Icons.cloud_done_rounded,
          size: 18,
          color: AppColors.success,
        ),
      );
    }

    if (syncStatus == 'error') {
      return Tooltip(
        message: 'Lỗi đồng bộ: ${syncError ?? "Không rõ"}',
        child: const Icon(
          Icons.cloud_off_rounded,
          size: 18,
          color: AppColors.error,
        ),
      );
    }

    return const Tooltip(
      message: 'Đang chờ đồng bộ Google Sheets',
      child: Icon(
        Icons.cloud_upload_outlined,
        size: 18,
        color: AppColors.warning,
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
            color: AppColors.text.withValues(alpha: 0.96),
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
                                color: AppColors.textMuted,
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
                                      color: AppColors.textMuted,
                                      fontSize: 12,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 12),
                            IconButton(
                              style: IconButton.styleFrom(
                                backgroundColor: Colors.white.withValues(
                                  alpha: 0.15,
                                ),
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
                                          color: Colors.black.withValues(
                                            alpha: 0.5,
                                          ),
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
                                          color: Colors.white.withValues(
                                            alpha: 0.1,
                                          ),
                                          borderRadius: BorderRadius.circular(
                                            30,
                                          ),
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
    this.color = AppColors.primary,
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
          border: Border.all(color: isSelected ? color : AppColors.border),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
            color: isSelected ? Colors.white : AppColors.textMuted,
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
    this.badgeColor = AppColors.surfaceMuted,
    this.textColor = AppColors.text,
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
        color: AppColors.canvas,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 16, color: AppColors.primary),
              const SizedBox(width: 8),
              Text(
                label,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textMuted,
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
        Icon(icon, size: 20, color: AppColors.primary),
        const SizedBox(width: 12),
        SizedBox(
          width: 100,
          child: Text(
            label,
            style: const TextStyle(color: AppColors.textMuted, fontSize: 13),
          ),
        ),
        Expanded(
          child: SelectableText(
            value.isEmpty ? '—' : value,
            style: const TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 13,
              color: AppColors.text,
            ),
          ),
        ),
      ],
    ),
  );
}
