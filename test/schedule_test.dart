import 'package:flutter_test/flutter_test.dart';

import 'package:fap_check_attendance/domain/schedule.dart';

void main() {
  test('suy học kỳ từ ngày trong ảnh', () {
    expect(academicTermForDate(DateTime(2026, 1, 1)), '2026-SPRING');
    expect(academicTermForDate(DateTime(2026, 4, 30)), '2026-SPRING');
    expect(academicTermForDate(DateTime(2026, 5, 1)), '2026-SUMMER');
    expect(academicTermForDate(DateTime(2026, 8, 31)), '2026-SUMMER');
    expect(academicTermForDate(DateTime(2026, 9, 1)), '2026-FALL');
    expect(academicTermForDate(DateTime(2026, 12, 31)), '2026-FALL');
  });

  test('ngày 25/10 gợi ý ngày bắt đầu trong kỳ Fall khi thiếu số buổi', () {
    final observed = DateTime(2025, 10, 25);
    expect(academicTermForDate(observed), '2025-FALL');
    expect(
      suggestScheduleStartDateFromObserved(
        observedDate: observed,
        preset: SchedulePreset.twentySlotsTenWeeks,
      ),
      DateTime(2025, 9, 3),
    );
  });

  test('block 3 tuần gợi ý đầu block từ một ngày học tháng 10', () {
    expect(
      suggestScheduleStartDateFromObserved(
        observedDate: DateTime(2025, 10, 24),
        preset: SchedulePreset.thirtySlotsThreeWeeks,
      ),
      DateTime(2025, 10, 6),
    );
  });

  test('hai loại block chính đều có 45 giờ học', () {
    expect(
      SchedulePreset.twentySlotsTenWeeks.slotCount *
          SchedulePreset.twentySlotsTenWeeks.slotDurationMinutes,
      45 * 60,
    );
    expect(
      SchedulePreset.thirtySlotsThreeWeeks.slotCount *
          SchedulePreset.thirtySlotsThreeWeeks.slotDurationMinutes,
      45 * 60,
    );
  });

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

  test('block 3 tuần tạo 30 slot theo cặp trong 15 ngày Thứ 2–6', () {
    final slots = generateSchedule(
      startDate: DateTime(2026, 9, 28),
      preset: SchedulePreset.thirtySlotsThreeWeeks,
    );
    expect(slots, hasLength(30));
    expect(_date(slots[0].date), '2026-09-28');
    expect(_date(slots[1].date), '2026-09-28');
    expect(_date(slots[9].date), '2026-10-02');
    expect(_date(slots[10].date), '2026-10-05');
    expect(_date(slots[29].date), '2026-10-16');
    expect(
      slots
          .map(
            (slot) =>
                '${_date(slot.date)}-${daySlotForScheduledSlot(preset: SchedulePreset.thirtySlotsThreeWeeks, firstDaySlot: 3, sessionNumber: slot.number)}',
          )
          .toSet(),
      hasLength(30),
    );
    expect(
      slots
          .take(4)
          .map(
            (slot) => daySlotForScheduledSlot(
              preset: SchedulePreset.thirtySlotsThreeWeeks,
              firstDaySlot: 3,
              sessionNumber: slot.number,
            ),
          ),
      [3, 4, 3, 4],
    );
  });

  test('suy ra ngày buổi 1 từ ngày một buổi trong ảnh cho mọi nhịp học', () {
    final startDate = DateTime(2026, 9, 17);
    for (final preset in SchedulePreset.values) {
      final slots = generateSchedule(startDate: startDate, preset: preset);
      for (final slot in slots) {
        expect(
          inferScheduleStartDate(
            observedDate: slot.date,
            sessionNumber: slot.number,
            preset: preset,
          ),
          startDate,
          reason: '${preset.label} · buổi ${slot.number}',
        );
      }
    }
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
