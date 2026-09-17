import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../domain/models.dart';
import '../services/attendance_api.dart';
import '../widgets/create_course_dialog.dart';
import 'session_screen.dart';

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

  @override
  void initState() {
    super.initState();
    _refresh();
    unawaited(widget.api.syncPendingCheckIns().catchError((_) {}));
  }

  void _refresh() {
    setState(() {
      _slots = widget.api.getTodaySlots(DateTime.now());
      _activeSession = widget.api.getActiveAttendance();
    });
  }

  Future<void> _createCourse() async {
    final created = await showDialog<bool>(
      context: context,
      builder: (_) => CreateCourseDialog(api: widget.api),
    );
    if (created == true) _refresh();
  }

  Future<void> _start(TodaySlot slot) async {
    final config = await showDialog<({int rotation, int validity})>(
      context: context,
      builder: (_) => const _SessionConfigDialog(),
    );
    if (config == null || !mounted) return;

    try {
      final session = await widget.api.startAttendance(
        slot: slot,
        rotationSeconds: config.rotation,
        validitySeconds: config.validity,
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
                const _SideItem(
                  icon: Icons.today_outlined,
                  label: 'Lịch hôm nay',
                  selected: true,
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
            child: Padding(
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
                              'Lịch hôm nay',
                              style: Theme.of(context).textTheme.headlineMedium
                                  ?.copyWith(fontWeight: FontWeight.w700),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'Hôm nay, ${DateFormat('dd/MM/yyyy').format(DateTime.now())}',
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        tooltip: 'Làm mới',
                        onPressed: _refresh,
                        icon: const Icon(Icons.refresh),
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
                        border: Border.all(color: const Color(0xFFE8C66A)),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Row(
                        children: [
                          Icon(Icons.info_outline, color: Color(0xFF805D00)),
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
                            border: Border.all(color: const Color(0xFF94CEB8)),
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
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Text(
                                      'Phiên điểm danh đang hoạt động',
                                      style: TextStyle(
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                    Text(
                                      '${session.subject} · ${session.classCode} · Slot ${session.slot}',
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
                            title: 'Hôm nay chưa có slot nào',
                            subtitle: 'Tạo môn–lớp mới hoặc kiểm tra lại ngày bắt đầu.',
                            action: FilledButton.icon(
                              onPressed: _createCourse,
                              icon: const Icon(Icons.add),
                              label: const Text('Tạo môn–lớp'),
                            ),
                          );
                        }
                        return ListView.separated(
                          itemCount: slots.length,
                          separatorBuilder: (_, _) =>
                              const SizedBox(height: 12),
                          itemBuilder: (context, index) {
                            final slot = slots[index];
                            return Card(
                              child: Padding(
                                padding: const EdgeInsets.all(20),
                                child: Row(
                                  children: [
                                    Container(
                                      width: 64,
                                      height: 64,
                                      alignment: Alignment.center,
                                      decoration: BoxDecoration(
                                        color: const Color(0xFFE3F2F4),
                                        borderRadius: BorderRadius.circular(14),
                                      ),
                                      child: Text(
                                        '${slot.slot}',
                                        style: Theme.of(context)
                                            .textTheme
                                            .headlineSmall
                                            ?.copyWith(
                                              color: const Color(0xFF14566A),
                                              fontWeight: FontWeight.w800,
                                            ),
                                      ),
                                    ),
                                    const SizedBox(width: 18),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            '${slot.subject} · ${slot.classCode}',
                                            style: Theme.of(context)
                                                .textTheme
                                                .titleLarge
                                                ?.copyWith(
                                                  fontWeight: FontWeight.w700,
                                                ),
                                          ),
                                          const SizedBox(height: 5),
                                          Text(
                                            'Slot ${slot.slot} · ${slot.date}',
                                          ),
                                        ],
                                      ),
                                    ),
                                    FilledButton.icon(
                                      onPressed: () => _start(slot),
                                      icon: const Icon(Icons.play_arrow),
                                      label: const Text('Bắt đầu điểm danh'),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        );
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
  final _validity = TextEditingController(text: '20');

  @override
  void dispose() {
    _rotation.dispose();
    _validity.dispose();
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
              const SizedBox(height: 12),
              const Text(
                'Toàn bộ đăng nhập Google phải hoàn tất trước khi QR hết hạn.',
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
            Navigator.pop(context, (rotation: rotation, validity: validity));
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
    this.selected = false,
  });

  final IconData icon;
  final String label;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: selected ? const Color(0xFF286A7E) : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(icon, color: Colors.white),
          const SizedBox(width: 12),
          Text(label, style: const TextStyle(color: Colors.white)),
        ],
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
