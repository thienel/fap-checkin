import 'package:flutter_test/flutter_test.dart';

import 'package:fap_check_attendance/domain/schedule.dart';

void main() {
  test('lịch hai buổi một tuần bỏ qua Chủ nhật', () {
    final slots = generateSchedule(
      startDate: DateTime(2026, 9, 17), // Thứ Năm
      preset: SchedulePreset.tenSlotsFiveWeeks,
    );

    expect(slots.take(4).map((slot) => _date(slot.date)), [
      '2026-09-17',
      '2026-09-21',
      '2026-09-24',
      '2026-09-28',
    ]);
  });

  test('lịch mười tuần giữ nguyên thứ', () {
    final slots = generateSchedule(
      startDate: DateTime(2026, 9, 16),
      preset: SchedulePreset.tenSlotsTenWeeks,
    );

    expect(slots, hasLength(10));
    expect(_date(slots[1].date), '2026-09-23');
    expect(_date(slots[9].date), '2026-11-18');
  });

  test('lịch cấp tốc đi qua mọi ngày trừ Chủ nhật', () {
    final slots = generateSchedule(
      startDate: DateTime(2026, 9, 19), // Thứ Bảy
      preset: SchedulePreset.tenSlotsThreeWeeks,
    );

    expect(_date(slots[1].date), '2026-09-21');
    expect(slots.every((slot) => slot.date.weekday != DateTime.sunday), isTrue);
  });

  test('từ chối ngày bắt đầu là Chủ nhật', () {
    expect(
      () => generateSchedule(
        startDate: DateTime(2026, 9, 20),
        preset: SchedulePreset.twentySlotsThreeWeeks,
      ),
      throwsArgumentError,
    );
  });
}

String _date(DateTime value) =>
    '${value.year.toString().padLeft(4, '0')}-'
    '${value.month.toString().padLeft(2, '0')}-'
    '${value.day.toString().padLeft(2, '0')}';
