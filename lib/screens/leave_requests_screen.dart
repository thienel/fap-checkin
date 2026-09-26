import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../domain/models.dart';
import '../services/attendance_api.dart';
import '../theme/app_theme.dart';
import '../widgets/app_ui.dart';

class LeaveRequestsScreen extends StatefulWidget {
  const LeaveRequestsScreen({super.key, required this.api});

  final AttendanceApi api;

  @override
  State<LeaveRequestsScreen> createState() => _LeaveRequestsScreenState();
}

class _LeaveRequestsScreenState extends State<LeaveRequestsScreen> {
  late Future<List<CourseClassSummary>> _classes;
  Future<List<LeaveRequest>>? _requests;
  CourseClassSummary? _selected;
  bool _pendingOnly = true;
  bool _deciding = false;

  @override
  void initState() {
    super.initState();
    _classes = widget.api.getCourseClasses();
  }

  void _select(CourseClassSummary? course) {
    setState(() {
      _selected = course;
      _requests = course == null
          ? null
          : widget.api.getLeaveRequests(course.id);
    });
  }

  void _refresh() {
    final course = _selected;
    if (course != null) {
      setState(() => _requests = widget.api.getLeaveRequests(course.id));
    }
  }

  Future<void> _decide(LeaveRequest request, bool approve) async {
    final course = _selected;
    if (course == null || _deciding) return;
    final controller = TextEditingController();
    final response = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(approve ? 'Duyệt đơn xin nghỉ' : 'Từ chối đơn xin nghỉ'),
        content: SizedBox(
          width: 440,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${request.studentName} · Buổi ${request.slot} · ${request.date}',
              ),
              const SizedBox(height: 12),
              Text(request.reason),
              const SizedBox(height: 16),
              TextField(
                controller: controller,
                autofocus: true,
                maxLength: 1000,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: 'Phản hồi cho sinh viên',
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
              if (controller.text.trim().isNotEmpty) {
                Navigator.pop(context, controller.text.trim());
              }
            },
            child: Text(approve ? 'Duyệt' : 'Từ chối'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (response == null || !mounted) return;
    setState(() => _deciding = true);
    try {
      await widget.api.decideLeaveRequest(
        courseClassId: course.id,
        requestId: request.id,
        approve: approve,
        response: response,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            approve ? 'Đã duyệt đơn xin nghỉ.' : 'Đã từ chối đơn xin nghỉ.',
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('$error')));
    } finally {
      if (mounted) {
        setState(() => _deciding = false);
        _refresh();
      }
    }
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(AppSpace.xl),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AppPageHeader(
          title: 'Yêu cầu nghỉ',
          subtitle:
              'Duyệt theo từng buổi; sinh viên sẽ thấy quyết định và phản hồi.',
          actions: [
            if (_selected != null) ...[
              OutlinedButton.icon(
                onPressed: () async {
                  await Clipboard.setData(
                    ClipboardData(
                      text: widget.api.leaveRequestUrl(_selected!.id),
                    ),
                  );
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Đã sao chép liên kết xin nghỉ cho lớp.'),
                      ),
                    );
                  }
                },
                icon: const Icon(Icons.link),
                label: const Text('Sao chép liên kết sinh viên'),
              ),
              IconButton(
                onPressed: _refresh,
                tooltip: 'Tải lại',
                icon: const Icon(Icons.refresh),
              ),
            ],
          ],
        ),
        const SizedBox(height: AppSpace.lg),
        FutureBuilder<List<CourseClassSummary>>(
          future: _classes,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return Text('Không tải được danh sách lớp: ${snapshot.error}');
            }
            if (!snapshot.hasData) return const LinearProgressIndicator();
            return DropdownButtonFormField<CourseClassSummary>(
              initialValue: _selected,
              decoration: const InputDecoration(labelText: 'Môn–lớp'),
              items: snapshot.data!
                  .map(
                    (course) => DropdownMenuItem(
                      value: course,
                      child: Text(course.label),
                    ),
                  )
                  .toList(),
              onChanged: _select,
            );
          },
        ),
        if (_selected != null) ...[
          const SizedBox(height: AppSpace.md),
          FilterChip(
            label: const Text('Chỉ đơn chờ xử lý'),
            selected: _pendingOnly,
            onSelected: (value) => setState(() => _pendingOnly = value),
          ),
          const SizedBox(height: AppSpace.md),
          Expanded(
            child: FutureBuilder<List<LeaveRequest>>(
              future: _requests,
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return Center(
                    child: Text('Không tải được đơn: ${snapshot.error}'),
                  );
                }
                if (!snapshot.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }
                final rows = snapshot.data!
                    .where((item) => !_pendingOnly || item.status == 'pending')
                    .toList();
                if (rows.isEmpty) {
                  return const Center(
                    child: Text('Không có đơn trong bộ lọc này.'),
                  );
                }
                return ListView.separated(
                  itemCount: rows.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (context, index) {
                    final item = rows[index];
                    final state = switch (item.status) {
                      'approved' => 'Đã duyệt',
                      'rejected' => 'Đã từ chối',
                      _ => 'Chờ xử lý',
                    };
                    return Card(
                      child: Padding(
                        padding: const EdgeInsets.all(AppSpace.md),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${item.studentName} · ${item.email}',
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                            Text('Buổi ${item.slot} · ${item.date} · $state'),
                            const SizedBox(height: 8),
                            Text('Lý do: ${item.reason}'),
                            if (item.response.isNotEmpty)
                              Text('Phản hồi: ${item.response}'),
                            if (item.hasAttendanceConflict)
                              const AppNotice(
                                message: 'Có điểm danh thực tế cho buổi đã duyệt nghỉ. Cần kiểm tra record trước khi chỉnh sửa.',
                                tone: AppTone.warning,
                              ),
                            if (item.status == 'pending')
                              Wrap(
                                spacing: 8,
                                children: [
                                  FilledButton(
                                    onPressed: _deciding
                                        ? null
                                        : () => _decide(item, true),
                                    child: const Text('Duyệt'),
                                  ),
                                  OutlinedButton(
                                    onPressed: _deciding
                                        ? null
                                        : () => _decide(item, false),
                                    child: const Text('Từ chối'),
                                  ),
                                ],
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
      ],
    ),
  );
}
