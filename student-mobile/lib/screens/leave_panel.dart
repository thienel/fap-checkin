import 'package:flutter/material.dart';

import '../models/student_models.dart';
import '../repositories/student_repository.dart';

class LeavePanel extends StatefulWidget {
  const LeavePanel({super.key, required this.repository, required this.course});
  final StudentRepository repository;
  final StudentCourse course;
  @override
  State<LeavePanel> createState() => _LeavePanelState();
}

class _LeavePanelState extends State<LeavePanel> {
  late Stream<List<StudentLeave>> stream;
  final reason = TextEditingController();
  final selected = <int>{};
  bool busy = false;
  String? message;
  @override
  void initState() {
    super.initState();
    stream = widget.repository.watchLeave(widget.course.id);
  }

  @override
  void dispose() {
    reason.dispose();
    super.dispose();
  }

  Future<void> submit() async {
    setState(() {
      busy = true;
      message = null;
    });
    try {
      await widget.repository.submitLeave(
        widget.course,
        selected.toList(),
        reason.text,
      );
      if (mounted) {
        setState(() {
          selected.clear();
          reason.clear();
          message = 'Đã gửi đơn. Chờ giảng viên xem xét.';
        });
      }
    } catch (e) {
      if (mounted) setState(() => message = friendlyError(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => StreamBuilder<List<StudentLeave>>(
    stream: stream,
    builder: (context, snapshot) {
      if (snapshot.hasError) {
        return Column(
          children: [
            Text(friendlyError(snapshot.error!)),
            TextButton(
              onPressed: () => setState(
                () => stream = widget.repository.watchLeave(widget.course.id),
              ),
              child: const Text('Tải lại đơn'),
            ),
          ],
        );
      }
      if (!snapshot.hasData) {
        return const Center(child: CircularProgressIndicator());
      }
      final requests = snapshot.data!;
      final submitted = requests.map((r) => r.slot).toSet();
      final future = widget.course.slots
          .where((s) => s.date.compareTo(dateKey(vietnamNow())) > 0)
          .toList();
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Chọn các buổi học từ ngày mai. Mỗi buổi chỉ gửi một đơn.',
          ),
          if (future.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Text('Không còn buổi học tương lai.'),
            ),
          for (final slot in future)
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              title: Text('Buổi ${slot.number} · ${slot.date}'),
              subtitle: submitted.contains(slot.number)
                  ? const Text('Đã có đơn')
                  : null,
              value:
                  selected.contains(slot.number) &&
                  !submitted.contains(slot.number),
              onChanged: busy || submitted.contains(slot.number)
                  ? null
                  : (value) => setState(() {
                      if (value == true) {
                        selected.add(slot.number);
                      } else {
                        selected.remove(slot.number);
                      }
                    }),
            ),
          if (future.any((s) => !submitted.contains(s.number))) ...[
            TextField(
              controller: reason,
              enabled: !busy,
              minLines: 3,
              maxLines: 5,
              maxLength: 1000,
              decoration: const InputDecoration(
                labelText: 'Lý do xin nghỉ',
                helperText: 'Từ 10 đến 1000 ký tự',
              ),
            ),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: busy ? null : submit,
              icon: const Icon(Icons.send_outlined),
              label: Text(busy ? 'Đang gửi…' : 'Gửi đơn xin nghỉ'),
            ),
          ],
          if (message != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(message!),
            ),
          const SizedBox(height: 24),
          Text('Lịch sử đơn', style: Theme.of(context).textTheme.titleMedium),
          if (requests.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text('Chưa có đơn xin nghỉ.'),
            ),
          for (final request in requests)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Buổi ${request.slot} · ${request.date} · ${request.label}',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const SizedBox(height: 8),
                    Text(request.reason),
                    if (request.response.isNotEmpty)
                      Text('Phản hồi: ${request.response}'),
                    if (request.status == 'approved')
                      const Text(
                        'Điểm danh có phép được giảng viên xử lý khi mở buổi.',
                      ),
                  ],
                ),
              ),
            ),
        ],
      );
    },
  );
}
