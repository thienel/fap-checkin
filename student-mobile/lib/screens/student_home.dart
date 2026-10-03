import 'package:flutter/material.dart';

import '../models/student_models.dart';
import '../repositories/student_repository.dart';
import 'course_detail.dart';
import 'leave_panel.dart';
import 'scanner_screen.dart';

class StudentHome extends StatefulWidget {
  const StudentHome({
    super.key,
    required this.repository,
    required this.onSignOut,
  });
  final StudentRepository repository;
  final Future<void> Function() onSignOut;
  @override
  State<StudentHome> createState() => _StudentHomeState();
}

class _StudentHomeState extends State<StudentHome> {
  late Stream<CourseLoad> courseStream;
  int tab = 0;
  DateTime week = weekStart(vietnamNow());
  String? term, leaveCourse;
  @override
  void initState() {
    super.initState();
    courseStream = widget.repository.watchCourses();
  }

  Future<void> refresh() async {
    setState(() => courseStream = widget.repository.watchCourses());
  }

  void openCourse(StudentCourse course) => Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) =>
          CourseDetail(repository: widget.repository, course: course),
    ),
  );
  Future<void> signOut() async {
    try {
      await widget.onSignOut();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(friendlyError(e))));
      }
    }
  }

  Widget courseTile(StudentCourse course) => Card(
    child: ListTile(
      leading: const Icon(Icons.menu_book_outlined),
      title: Text(course.label),
      subtitle: Text(
        '${course.term ?? 'Chưa có thông tin học kỳ'} · ${course.slots.length} buổi',
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => openCourse(course),
    ),
  );
  List<Widget> schedule(List<StudentCourse> courses, String from, String to) {
    final rows = [
      for (final c in courses)
        for (final s in c.slots)
          if (s.date.compareTo(from) >= 0 && s.date.compareTo(to) <= 0)
            (course: c, slot: s),
    ];
    rows.sort((a, b) {
      final date = a.slot.date.compareTo(b.slot.date);
      return date != 0
          ? date
          : (a.slot.daySlot ?? 99).compareTo(b.slot.daySlot ?? 99);
    });
    if (rows.isEmpty) {
      return [
        const Padding(
          padding: EdgeInsets.all(24),
          child: Text('Không có buổi học trong thời gian này.'),
        ),
      ];
    }
    return rows.map((row) {
      final conflict =
          row.slot.daySlot != null &&
          rows
                  .where(
                    (r) =>
                        r.slot.date == row.slot.date &&
                        r.slot.daySlot == row.slot.daySlot,
                  )
                  .length >
              1;
      return Card(
        child: ListTile(
          onTap: () => openCourse(row.course),
          leading: const Icon(Icons.event_outlined),
          title: Text(row.course.label),
          subtitle: Text(
            '${row.slot.date} · Buổi ${row.slot.number}/${row.course.slots.length}\n${row.slot.timeLabel(row.course.duration)}${conflict ? '\nTrùng khung giờ với buổi học khác' : ''}',
          ),
          isThreeLine: true,
        ),
      );
    }).toList();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(
        ['FAP Sinh viên', 'Lịch học', 'Môn học', 'Đơn xin nghỉ'][tab],
      ),
      actions: [
        IconButton(
          tooltip: 'Tải lại',
          onPressed: refresh,
          icon: const Icon(Icons.refresh),
        ),
        IconButton(
          tooltip: 'Đổi tài khoản / đăng xuất',
          onPressed: signOut,
          icon: const Icon(Icons.logout),
        ),
      ],
    ),
    floatingActionButton: FloatingActionButton.extended(
      onPressed: () => Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => ScannerScreen(repository: widget.repository),
        ),
      ),
      icon: const Icon(Icons.qr_code_scanner),
      label: const Text('Quét QR'),
    ),
    bottomNavigationBar: NavigationBar(
      selectedIndex: tab,
      onDestinationSelected: (i) => setState(() => tab = i),
      destinations: const [
        NavigationDestination(
          icon: Icon(Icons.home_outlined),
          label: 'Trang chủ',
        ),
        NavigationDestination(
          icon: Icon(Icons.calendar_month_outlined),
          label: 'Lịch học',
        ),
        NavigationDestination(
          icon: Icon(Icons.menu_book_outlined),
          label: 'Môn học',
        ),
        NavigationDestination(
          icon: Icon(Icons.description_outlined),
          label: 'Đơn',
        ),
      ],
    ),
    body: StreamBuilder<CourseLoad>(
      stream: courseStream,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(friendlyError(snapshot.error!)),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: refresh,
                    child: const Text('Thử lại'),
                  ),
                ],
              ),
            ),
          );
        }
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final load = snapshot.data!;
        final courses = load.courses;
        final terms =
            courses
                .map((c) => c.term ?? 'Chưa có thông tin học kỳ')
                .toSet()
                .toList()
              ..sort();
        final selectedTerm = terms.contains(term) ? term : null;
        final selectedCourse = courses.isEmpty
            ? null
            : courses.firstWhere(
                (c) => c.id == leaveCourse,
                orElse: () => courses.first,
              );
        return RefreshIndicator(
          onRefresh: refresh,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
            children: [
              Text(
                widget.repository.email,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 16),
              if (load.fromCache || load.loading)
                const Card(
                  child: Padding(
                    padding: EdgeInsets.all(16),
                    child: Text(
                      'Đang chờ máy chủ xác nhận danh sách môn. Kiểm tra kết nối mạng.',
                    ),
                  ),
                ),
              for (final error in load.errors.values)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(error),
                  ),
                ),
              if (courses.isEmpty &&
                  !load.fromCache &&
                  !load.loading &&
                  load.errors.isEmpty)
                const Card(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      'Email này chưa được giảng viên thêm vào lớp. Hãy liên hệ giảng viên hoặc đổi tài khoản.',
                    ),
                  ),
                ),
              if (tab == 0) ...[
                Text(
                  'Lịch hôm nay',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                Text(dateKey(vietnamNow())),
                const SizedBox(height: 12),
                ...schedule(
                  courses,
                  dateKey(vietnamNow()),
                  dateKey(vietnamNow()),
                ),
                const SizedBox(height: 24),
                Text(
                  'Môn của bạn',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                ...courses.map(courseTile),
              ],
              if (tab == 1) ...[
                Row(
                  children: [
                    IconButton(
                      tooltip: 'Tuần trước',
                      onPressed: () => setState(
                        () => week = week.subtract(const Duration(days: 7)),
                      ),
                      icon: const Icon(Icons.chevron_left),
                    ),
                    Expanded(
                      child: Text(
                        '${dateKey(week)} → ${dateKey(week.add(const Duration(days: 6)))}',
                        textAlign: TextAlign.center,
                      ),
                    ),
                    IconButton(
                      tooltip: 'Tuần sau',
                      onPressed: () => setState(
                        () => week = week.add(const Duration(days: 7)),
                      ),
                      icon: const Icon(Icons.chevron_right),
                    ),
                  ],
                ),
                TextButton(
                  onPressed: () =>
                      setState(() => week = weekStart(vietnamNow())),
                  child: const Text('Về tuần này'),
                ),
                ...schedule(
                  courses,
                  dateKey(week),
                  dateKey(week.add(const Duration(days: 6))),
                ),
              ],
              if (tab == 2) ...[
                DropdownButtonFormField<String>(
                  key: ValueKey('${selectedTerm ?? 'all'}:${terms.join(',')}'),
                  initialValue: selectedTerm,
                  decoration: const InputDecoration(labelText: 'Học kỳ'),
                  items: [
                    const DropdownMenuItem(
                      value: null,
                      child: Text('Tất cả học kỳ'),
                    ),
                    ...terms.map(
                      (t) => DropdownMenuItem(value: t, child: Text(t)),
                    ),
                  ],
                  onChanged: (value) => setState(() => term = value),
                ),
                const SizedBox(height: 12),
                ...courses
                    .where(
                      (c) =>
                          selectedTerm == null ||
                          (c.term ?? 'Chưa có thông tin học kỳ') ==
                              selectedTerm,
                    )
                    .map(courseTile),
              ],
              if (tab == 3 && selectedCourse != null) ...[
                DropdownButtonFormField<String>(
                  key: ValueKey(selectedCourse.id),
                  initialValue: selectedCourse.id,
                  decoration: const InputDecoration(labelText: 'Môn–lớp'),
                  items: courses
                      .map(
                        (c) => DropdownMenuItem(
                          value: c.id,
                          child: Text(
                            '${c.label} · ${c.term ?? '?'}',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      )
                      .toList(),
                  onChanged: (value) => setState(() => leaveCourse = value),
                ),
                const SizedBox(height: 16),
                LeavePanel(
                  key: ValueKey(selectedCourse.id),
                  repository: widget.repository,
                  course: selectedCourse,
                ),
              ],
            ],
          ),
        );
      },
    ),
  );
}
