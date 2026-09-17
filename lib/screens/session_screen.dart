import 'dart:async';

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

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
  Timer? _clockTimer;
  IssuedQr? _qr;
  bool _issuing = false;
  bool _stopping = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _issueQr();
    _rotationTimer = Timer.periodic(
      Duration(seconds: widget.session.rotationSeconds),
      (_) => _issueQr(),
    );
    _clockTimer = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _rotationTimer?.cancel();
    _clockTimer?.cancel();
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

  int get _secondsRemaining {
    final qr = _qr;
    if (qr == null) return 0;
    final milliseconds = qr.expiresAt.difference(DateTime.now()).inMilliseconds;
    if (milliseconds <= 0) return 0;
    return (milliseconds / 1000).ceil();
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    final remaining = _secondsRemaining;
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
                          AnimatedSwitcher(
                            duration: const Duration(milliseconds: 200),
                            child: Container(
                              key: ValueKey(_qr!.url),
                              padding: const EdgeInsets.all(16),
                              color: Colors.white,
                              child: QrImageView(
                                data: _qr!.url,
                                version: QrVersions.auto,
                                size: 330,
                                gapless: false,
                              ),
                            ),
                          ),
                        const SizedBox(height: 18),
                        Text(
                          remaining > 0
                              ? 'QR hiện tại còn hiệu lực $remaining giây'
                              : 'Đang lấy QR mới…',
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(
                                color: remaining <= 5
                                    ? Theme.of(context).colorScheme.error
                                    : const Color(0xFF245B6B),
                                fontWeight: FontWeight.w700,
                              ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'QR đổi mỗi ${session.rotationSeconds} giây · '
                          'hết hạn sau ${session.validitySeconds} giây',
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
                      value: 'Slot ${session.slot} · ${session.date}',
                    ),
                    const SizedBox(height: 14),
                    Expanded(
                      child: StreamBuilder<int>(
                        stream: widget.api.watchAttendanceCount(session.id),
                        builder: (context, snapshot) {
                          return Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(28),
                            decoration: BoxDecoration(
                              gradient: const LinearGradient(
                                colors: [Color(0xFF164E63), Color(0xFF28758B)],
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                              ),
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                const Icon(
                                  Icons.how_to_reg_outlined,
                                  color: Colors.white,
                                  size: 38,
                                ),
                                const SizedBox(height: 18),
                                Text(
                                  '${snapshot.data ?? 0}',
                                  style: Theme.of(context)
                                      .textTheme
                                      .displayLarge
                                      ?.copyWith(
                                        color: Colors.white,
                                        fontWeight: FontWeight.w800,
                                      ),
                                ),
                                const Text(
                                  'sinh viên đã điểm danh',
                                  style: TextStyle(
                                    color: Color(0xFFD8EEF3),
                                    fontSize: 17,
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
