enum SchedulePreset {
  twentySlotsThreeWeeks(20, 3, '20 slot · 3 tuần'),
  twentySlotsTenWeeks(20, 10, '20 slot · 10 tuần'),
  tenSlotsThreeWeeks(10, 3, '10 slot · 3 tuần'),
  tenSlotsFiveWeeks(10, 5, '10 slot · 5 tuần'),
  tenSlotsTenWeeks(10, 10, '10 slot · 10 tuần');

  const SchedulePreset(this.slotCount, this.weekLabel, this.label);

  final int slotCount;
  final int weekLabel;
  final String label;
}

class ScheduledSlot {
  const ScheduledSlot({required this.number, required this.date});

  final int number;
  final DateTime date;
}

List<ScheduledSlot> generateSchedule({
  required DateTime startDate,
  required SchedulePreset preset,
}) {
  final normalized = DateTime(startDate.year, startDate.month, startDate.day);
  if (normalized.weekday == DateTime.sunday) {
    throw ArgumentError.value(startDate, 'startDate', 'Không được là Chủ nhật');
  }

  final result = <ScheduledSlot>[];
  var current = normalized;
  for (var index = 0; index < preset.slotCount; index++) {
    result.add(ScheduledSlot(number: index + 1, date: current));
    if (index == preset.slotCount - 1) break;

    current = switch (preset) {
      SchedulePreset.twentySlotsTenWeeks ||
      SchedulePreset.tenSlotsFiveWeeks => _addTeachingDays(current, 3),
      SchedulePreset.tenSlotsTenWeeks => current.add(const Duration(days: 7)),
      SchedulePreset.twentySlotsThreeWeeks ||
      SchedulePreset.tenSlotsThreeWeeks => _addTeachingDays(current, 1),
    };
  }
  return result;
}

DateTime _addTeachingDays(DateTime date, int count) {
  var cursor = date;
  var remaining = count;
  while (remaining > 0) {
    cursor = cursor.add(const Duration(days: 1));
    if (cursor.weekday != DateTime.sunday) remaining--;
  }
  return cursor;
}
