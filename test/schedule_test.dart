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

  test('xác định tuần từ thứ Hai đến Chủ nhật', () {
    final date = DateTime(2026, 9, 20); // Chủ nhật

    expect(_date(startOfWeek(date)), '2026-09-14');
    expect(_date(endOfWeek(date)), '2026-09-20');
  });

  test('xác định cùng ngày mà không phụ thuộc thời gian', () {
    expect(
      isSameDate(DateTime(2026, 9, 20, 8), DateTime(2026, 9, 20, 23, 59)),
      isTrue,
    );
    expect(isSameDate(DateTime(2026, 9, 20), DateTime(2026, 9, 21)), isFalse);
  });

  test('xác định slot trong ngày gần với thời điểm hiện tại', () {
    expect(closestDaySlot(DateTime(2026, 9, 20, 7, 30)), 1);
    expect(closestDaySlot(DateTime(2026, 9, 20, 10, 24)), 2);
    expect(closestDaySlot(DateTime(2026, 9, 20, 16)), 4);
    expect(closestDaySlot(DateTime(2026, 9, 20, 20)), 5);
  });
}

String _date(DateTime value) =>
    '${value.year.toString().padLeft(4, '0')}-'
    '${value.month.toString().padLeft(2, '0')}-'
    '${value.day.toString().padLeft(2, '0')}';
