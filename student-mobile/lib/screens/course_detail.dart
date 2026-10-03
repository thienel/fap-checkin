import 'package:flutter/material.dart';

import '../models/student_models.dart';
import '../repositories/student_repository.dart';
import 'leave_panel.dart';

class CourseDetail extends StatefulWidget {
  const CourseDetail({
    super.key,
    required this.repository,
    required this.course,
  });
  final StudentRepository repository;
  final StudentCourse course;
  @override
  State<CourseDetail> createState() => _CourseDetailState();
}

class _CourseDetailState extends State<CourseDetail> {
  late Stream<StudentCourse> courseStream;
  @override
  void initState() {
    super.initState();
    courseStream = widget.repository.watchCourse(widget.course.id);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(widget.course.label)),
    body: StreamBuilder<StudentCourse>(
      stream: courseStream,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(friendlyError(snapshot.error!)),
            ),
          );
        }
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final course = snapshot.data!;
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(course.term ?? 'Chưa có thông tin học kỳ'),
            Text('${course.student.name} · ${course.student.code}'),
            if (course.student.alwaysExcused)
              const Text(
                'Giảng viên đã đặt chính sách miễn điểm danh toàn môn.',
              ),
            const SizedBox(height: 24),
            AttendancePanel(
              key: ValueKey(
                '${course.id}:${course.student.alwaysExcused}:${course.slots.map((s) => '${s.number}-${s.date}-${s.daySlot}').join(',')}',
              ),
              course: course,
              repository: widget.repository,
            ),
            const SizedBox(height: 24),
            Text('Đơn xin nghỉ', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            LeavePanel(repository: widget.repository, course: course),
          ],
        );
      },
    ),
  );
}

class AttendancePanel extends StatefulWidget {
  const AttendancePanel({
    super.key,
    required this.course,
    required this.repository,
  });
  final StudentCourse course;
  final StudentRepository repository;
  @override
  State<AttendancePanel> createState() => _AttendancePanelState();
}

class _AttendancePanelState extends State<AttendancePanel> {
  late Stream<AttendanceSummary> stream;
  @override
  void initState() {
    super.initState();
    stream = widget.repository.watchAttendance(widget.course);
  }

  @override
  Widget build(BuildContext context) => StreamBuilder<AttendanceSummary>(
    stream: stream,
    builder: (context, snapshot) {
      if (snapshot.hasError) {
        return Column(
          children: [
            Text(friendlyError(snapshot.error!)),
            TextButton(
              onPressed: () => setState(
                () => stream = widget.repository.watchAttendance(widget.course),
              ),
              child: const Text('Tải lại điểm danh'),
            ),
          ],
        );
      }
      if (!snapshot.hasData) {
        return const Center(child: CircularProgressIndicator());
      }
      final summary = snapshot.data!;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Điểm danh của bạn',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    summary.reliable
                        ? 'Có mặt ${summary.present} · Vắng ${summary.absent} · Có phép ${summary.excused}'
                        : 'Đang xác minh điểm danh với máy chủ…',
                  ),
                  const SizedBox(height: 8),
                  Text(
                    summary.attendanceRate == null
                        ? 'Chưa có dữ liệu tính tỷ lệ'
                        : 'Tỷ lệ tham dự ${(summary.attendanceRate! * 100).round()}%',
                  ),
                  const Text('Thống kê tính trên các buổi đã kết thúc.'),
                  if (summary.warning != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        summary.warning!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          for (final row in summary.rows)
            Card(
              child: ListTile(
                title: Text('Buổi ${row.slot.number} · ${row.slot.date}'),
                subtitle: Text(
                  '${row.slot.timeLabel(widget.course.duration)}\n${row.status.label}',
                ),
                isThreeLine: true,
                trailing: Icon(switch (row.status) {
                  AttendanceState.present => Icons.check_circle_outline,
                  AttendanceState.absent => Icons.cancel_outlined,
                  AttendanceState.excused => Icons.verified_outlined,
                  _ => Icons.schedule,
                }),
              ),
            ),
        ],
      );
    },
  );
}
