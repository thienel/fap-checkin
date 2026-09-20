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

class DaySlotDefinition {
  const DaySlotDefinition(this.number, this.timeRange);

  final int number;
  final String? timeRange;

  String get label =>
      timeRange == null ? 'Slot $number' : 'Slot $number · $timeRange';
}

const daySlotDefinitions = <DaySlotDefinition>[
  DaySlotDefinition(1, '07:00–09:15'),
  DaySlotDefinition(2, '09:30–11:45'),
  DaySlotDefinition(3, '12:30–14:45'),
  DaySlotDefinition(4, '15:00–17:15'),
  DaySlotDefinition(5, '17:45–20:00'),
  DaySlotDefinition(6, null),
  DaySlotDefinition(7, null),
];

int closestDaySlot(DateTime date) {
  final minutes = date.hour * 60 + date.minute;
  if (minutes < 9 * 60 + 23) return 1;
  if (minutes < 12 * 60 + 8) return 2;
  if (minutes < 14 * 60 + 53) return 3;
  if (minutes < 17 * 60 + 30) return 4;
  return 5;
}

DateTime startOfWeek(DateTime date) {
  final normalized = DateTime(date.year, date.month, date.day);
  return normalized.subtract(
    Duration(days: normalized.weekday - DateTime.monday),
  );
}

DateTime endOfWeek(DateTime date) =>
    startOfWeek(date).add(const Duration(days: 6));

bool isSameDate(DateTime left, DateTime right) =>
    left.year == right.year &&
    left.month == right.month &&
    left.day == right.day;

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
