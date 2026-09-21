import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../domain/class_overview.dart';
import '../domain/models.dart';
import '../services/attendance_api.dart';

class SessionScreen extends StatefulWidget {
  const SessionScreen({super.key, required this.api, required this.session});

  final AttendanceApi api;
  final AttendanceSession session;

  @override
  State<SessionScreen> createState() => _SessionScreenState();
}

class _SessionScreenState extends State<SessionScreen> {
  Timer? _rotationTimer;
  late final Stream<List<CheckInRecord>> _checkIns;
  IssuedQr? _qr;
  bool _issuing = false;
  bool _stopping = false;
  bool _retryingSync = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    // Keep one subscription for the lifetime of this screen. QR rotation must
    // not unsubscribe/resubscribe and reset the attendance list.
    _checkIns = widget.api.watchSessionCheckIns(widget.session);
    _issueQr();
    _rotationTimer = Timer.periodic(
      Duration(seconds: widget.session.rotationSeconds),
      (_) => _issueQr(),
    );
  }

  @override
  void dispose() {
    _rotationTimer?.cancel();
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
          _error = null;
        });
      }
    } catch (error) {
      if (mounted) setState(() => _error = 'Không tạo được QR mới: $error');
    } finally {
      _issuing = false;
    }
  }

  Future<void> _stop() async {
    setState(() => _stopping = true);
    _rotationTimer?.cancel();
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
      // The slot may have been reopened with a new session ID while its
      // immutable check-in records still reference an earlier session.
      await widget.api.syncPendingCheckIns();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Đã thử đồng bộ lại Google Sheets.')),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Đồng bộ Google Sheets thất bại: $error')),
      );
    } finally {
      if (mounted) setState(() => _retryingSync = false);
    }
  }

  void _showStudentDetail(CheckInRecord record) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.badge_outlined),
            SizedBox(width: 10),
            Text('Thông tin sinh viên'),
          ],
        ),
        content: SizedBox(
          width: 480,
          child: FutureBuilder<StudentAttendanceDetail>(
            future: widget.api.getStudentAttendanceDetail(
              courseClassId: widget.session.courseClassId,
              studentId: record.studentId,
            ),
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const SizedBox(
                  height: 190,
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
                      value: record.fullName,
                    ),
                    _StudentInfoRow(
                      icon: Icons.alternate_email,
                      label: 'Email',
                      value: record.email,
                    ),
                    _StudentInfoRow(
                      icon: Icons.badge_outlined,
                      label: 'Mã sinh viên',
                      value: record.studentCode,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'Không tải được thống kê: ${snapshot.error}',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ],
                );
              }
              final detail = snapshot.requireData;
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _StudentInfoRow(
                    icon: Icons.person_outline,
                    label: 'Họ tên',
                    value: detail.student.displayName,
                  ),
                  _StudentInfoRow(
                    icon: Icons.alternate_email,
                    label: 'Email',
                    value: detail.student.email,
                  ),
                  _StudentInfoRow(
                    icon: Icons.badge_outlined,
                    label: 'Mã sinh viên',
                    value: detail.student.studentCode,
                  ),
                  const Divider(height: 28),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(18),
                    decoration: BoxDecoration(
                      color: const Color(0xFFE8F3F6),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.how_to_reg_outlined,
                          color: Color(0xFF17658C),
                          size: 32,
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '${detail.attendedSlots}/${detail.totalSlots}',
                                style: Theme.of(context)
                                    .textTheme
                                    .headlineMedium
                                    ?.copyWith(fontWeight: FontWeight.w800),
                              ),
                              const Text('slot đã điểm danh / tổng slot'),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Đã mở: ${detail.openedSlots}/${detail.totalSlots}',
                        ),
                      ),
                      Text('Có phép: ${detail.excusedSlots}'),
                    ],
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
        appBar: AppBar(
          automaticallyImplyLeading: false,
          title: Text('${session.subject} · ${session.classCode}'),
          actions: [
            Padding(
              padding: const EdgeInsets.only(right: 20),
              child: FilledButton.tonalIcon(
                onPressed: _stopping ? null : _stop,
                icon: _stopping
                    ? const SizedBox.square(
                        dimension: 17,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.stop_circle_outlined),
                label: const Text('Ngừng điểm danh'),
              ),
            ),
          ],
        ),
        body: Padding(
          padding: const EdgeInsets.fromLTRB(36, 24, 36, 36),
          child: Row(
            children: [
              Expanded(
                flex: 3,
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.all(30),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        if (_qr == null)
                          const SizedBox.square(
                            dimension: 300,
                            child: Center(child: CircularProgressIndicator()),
                          )
                        else
                          Container(
                            padding: const EdgeInsets.all(16),
                            color: Colors.white,
                            child: QrImageView(
                              data: _qr!.url,
                              version: QrVersions.auto,
                              size: 330,
                              gapless: false,
                            ),
                          ),
                        const SizedBox(height: 18),
                        Text(
                          _qr == null ? 'Đang lấy QR…' : 'QR đang hoạt động',
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(
                                color: const Color(0xFF245B6B),
                                fontWeight: FontWeight.w700,
                              ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'QR tự động đổi mỗi ${session.rotationSeconds} giây · '
                          'mỗi mã có hiệu lực ${session.validitySeconds} giây',
                        ),
                        if (_error != null) ...[
                          const SizedBox(height: 14),
                          Text(
                            _error!,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 24),
              Expanded(
                flex: 2,
                child: Column(
                  children: [
                    _InfoCard(
                      icon: Icons.menu_book_outlined,
                      label: 'Môn học · Lớp',
                      value: '${session.subject} · ${session.classCode}',
                    ),
                    const SizedBox(height: 14),
                    _InfoCard(
                      icon: Icons.event_note_outlined,
                      label: 'Buổi học',
                      value:
                          'Buổi ${session.slot}${session.slotCount > 0 ? '/${session.slotCount}' : ''} · ${session.date}',
                    ),
                    if (session.daySlot != null) ...[
                      const SizedBox(height: 14),
                      _InfoCard(
                        icon: Icons.schedule_outlined,
                        label: 'Khung giờ trong ngày',
                        value: 'Slot ${session.daySlot}',
                      ),
                    ],
                    const SizedBox(height: 14),
                    Expanded(
                      child: StreamBuilder<List<CheckInRecord>>(
                        stream: _checkIns,
                        builder: (context, snapshot) {
                          if (snapshot.hasError) {
                            return Card(
                              child: Center(
                                child: Padding(
                                  padding: const EdgeInsets.all(24),
                                  child: Text(
                                    'Không tải được danh sách điểm danh:\n${snapshot.error}',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .error,
                                    ),
                                  ),
                                ),
                              ),
                            );
                          }
                          final records =
                              snapshot.data ?? const <CheckInRecord>[];
                          final hasSyncError = records.any(
                            (record) => record.syncStatus == 'error',
                          );
                          final presentCount = records
                              .where(
                                (record) =>
                                    record.attendanceStatus == 'present',
                              )
                              .length;
                          return Card(
                            clipBehavior: Clip.antiAlias,
                            child: Column(
                              children: [
                                Container(
                                  width: double.infinity,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 20,
                                    vertical: 15,
                                  ),
                                  color: const Color(0xFF164E63),
                                  child: Row(
                                    children: [
                                      const Icon(
                                        Icons.how_to_reg_outlined,
                                        color: Colors.white,
                                      ),
                                      const SizedBox(width: 10),
                                      Text(
                                        '$presentCount có mặt · ${records.length - presentCount} trạng thái khác',
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 17,
                                          fontWeight: FontWeight.w800,
                                        ),
                                      ),
                                      const Spacer(),
                                      if (hasSyncError)
                                        TextButton.icon(
                                          style: TextButton.styleFrom(
                                            foregroundColor: Colors.white,
                                          ),
                                          onPressed: _retryingSync
                                              ? null
                                              : _retrySheetSync,
                                          icon: _retryingSync
                                              ? const SizedBox.square(
                                                  dimension: 16,
                                                  child:
                                                      CircularProgressIndicator(
                                                        strokeWidth: 2,
                                                        color: Colors.white,
                                                      ),
                                                )
                                              : const Icon(Icons.sync_problem),
                                          label: const Text('Thử đồng bộ lại'),
                                        ),
                                    ],
                                  ),
                                ),
                                Expanded(
                                  child:
                                      snapshot.connectionState ==
                                          ConnectionState.waiting
                                      ? const Center(
                                          child: CircularProgressIndicator(),
                                        )
                                      : records.isEmpty
                                      ? const Center(
                                          child: Padding(
                                            padding: EdgeInsets.all(20),
                                            child: Text(
                                              'Chưa có sinh viên check-in.',
                                              textAlign: TextAlign.center,
                                            ),
                                          ),
                                        )
                                      : ListView.separated(
                                          itemCount: records.length,
                                          separatorBuilder: (_, _) =>
                                              const Divider(height: 1),
                                          itemBuilder: (context, index) {
                                            final record = records[index];
                                            final syncColor =
                                                record.syncStatus == 'synced'
                                                ? const Color(0xFF167052)
                                                : record.syncStatus == 'error'
                                                ? const Color(0xFFB5473C)
                                                : const Color(0xFF9A6B13);
                                            return ListTile(
                                              dense: true,
                                              onTap: () =>
                                                  _showStudentDetail(record),
                                              leading: CircleAvatar(
                                                child: Text('${index + 1}'),
                                              ),
                                              title: Text(
                                                record.fullName.isEmpty
                                                    ? record.email
                                                    : record.fullName,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                              subtitle: Text(
                                                '${record.studentCode.isEmpty ? record.email : record.studentCode} · '
                                                '${_attendanceStatusLabel(record.attendanceStatus)} · '
                                                '${record.checkedInAt == null ? 'Không có giờ check-in' : DateFormat('HH:mm:ss').format(record.checkedInAt!)}',
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                              trailing: Tooltip(
                                                message:
                                                    record.syncError == null
                                                    ? 'Nguồn ${record.source} · ${record.syncStatus}'
                                                    : 'Lỗi đồng bộ: ${record.syncError}',
                                                child: Icon(
                                                  record.syncStatus == 'synced'
                                                      ? Icons
                                                            .cloud_done_outlined
                                                      : record.syncStatus ==
                                                            'error'
                                                      ? Icons.cloud_off_outlined
                                                      : Icons
                                                            .cloud_upload_outlined,
                                                  color: syncColor,
                                                ),
                                              ),
                                            );
                                          },
                                        ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String _attendanceStatusLabel(String status) => switch (status) {
  'absent' => 'Vắng',
  'excused' => 'Có phép',
  _ => 'Có mặt',
};

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
    padding: const EdgeInsets.symmetric(vertical: 7),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 21, color: const Color(0xFF17658C)),
        const SizedBox(width: 12),
        SizedBox(
          width: 105,
          child: Text(label, style: const TextStyle(color: Color(0xFF64777D))),
        ),
        Expanded(
          child: SelectableText(
            value.isEmpty ? '—' : value,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
        ),
      ],
    ),
  );
}

class _InfoCard extends StatelessWidget {
  const _InfoCard({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Row(
          children: [
            Icon(icon, size: 30, color: const Color(0xFF1D687C)),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: const TextStyle(color: Color(0xFF64777D))),
                  const SizedBox(height: 3),
                  Text(
                    value,
                    style: Theme.of(context).textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
