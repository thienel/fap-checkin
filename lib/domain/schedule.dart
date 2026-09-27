enum SchedulePreset {
  thirtySlotsThreeWeeks(30, 3, '30 slot · 3 tuần'),
  twentySlotsThreeWeeks(20, 3, '20 slot · 3 tuần'),
  twentySlotsTenWeeks(20, 10, '20 slot · 10 tuần'),
  tenSlotsThreeWeeks(10, 3, '10 slot · 3 tuần'),
  tenSlotsFiveWeeks(10, 5, '10 slot · 5 tuần'),
  tenSlotsTenWeeks(10, 10, '10 slot · 10 tuần');

  const SchedulePreset(this.slotCount, this.weekLabel, this.label);

  final int slotCount;
  final int weekLabel;
  final String label;

  int get slotDurationMinutes =>
      this == SchedulePreset.thirtySlotsThreeWeeks ? 90 : 135;
}

String academicTermForDate(DateTime date) {
  final season = date.month <= 4
      ? 'SPRING'
      : date.month <= 8
      ? 'SUMMER'
      : 'FALL';
  return '${date.year}-$season';
}

DateTime academicTermStart(DateTime date) {
  final month = date.month <= 4
      ? 1
      : date.month <= 8
      ? 5
      : 9;
  return DateTime(date.year, month);
}

DateTime academicTermEnd(DateTime date) {
  final start = academicTermStart(date);
  return DateTime(
    start.year,
    start.month + 4,
  ).subtract(const Duration(days: 1));
}

class ScheduledSlot {
  const ScheduledSlot({required this.number, required this.date, this.daySlot});

  final int number;
  final DateTime date;
  final int? daySlot;
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

int daySlotForScheduledSlot({
  required SchedulePreset preset,
  required int firstDaySlot,
  required int sessionNumber,
}) {
  if (firstDaySlot < 1 || firstDaySlot > 7) {
    throw RangeError.range(firstDaySlot, 1, 7, 'firstDaySlot');
  }
  if (sessionNumber < 1 || sessionNumber > preset.slotCount) {
    throw RangeError.range(sessionNumber, 1, preset.slotCount, 'sessionNumber');
  }
  if (preset == SchedulePreset.thirtySlotsThreeWeeks && firstDaySlot == 7) {
    throw RangeError.value(
      firstDaySlot,
      'firstDaySlot',
      'Cần hai slot liên tiếp',
    );
  }
  return preset == SchedulePreset.thirtySlotsThreeWeeks
      ? firstDaySlot + (sessionNumber - 1) % 2
      : firstDaySlot;
}

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
  if (preset == SchedulePreset.thirtySlotsThreeWeeks &&
      normalized.weekday == DateTime.saturday) {
    throw ArgumentError.value(
      startDate,
      'startDate',
      'Block 3 tuần bắt đầu từ Thứ 2–6',
    );
  }

  final result = <ScheduledSlot>[];
  var current = normalized;
  for (var index = 0; index < preset.slotCount; index++) {
    result.add(ScheduledSlot(number: index + 1, date: current));
    if (index == preset.slotCount - 1) break;

    current = switch (preset) {
      SchedulePreset.thirtySlotsThreeWeeks =>
        index.isEven ? current : _addWeekdays(current, 1),
      SchedulePreset.twentySlotsTenWeeks ||
      SchedulePreset.tenSlotsFiveWeeks => _addTeachingDays(current, 3),
      SchedulePreset.tenSlotsTenWeeks => current.add(const Duration(days: 7)),
      SchedulePreset.twentySlotsThreeWeeks ||
      SchedulePreset.tenSlotsThreeWeeks => _addTeachingDays(current, 1),
    };
  }
  return result;
}

/// Suy ra ngày buổi 1 từ ngày của một buổi đã đọc được trong thời khóa biểu.
DateTime inferScheduleStartDate({
  required DateTime observedDate,
  required int sessionNumber,
  required SchedulePreset preset,
}) {
  if (sessionNumber < 1 || sessionNumber > preset.slotCount) {
    throw RangeError.range(sessionNumber, 1, preset.slotCount, 'sessionNumber');
  }
  var current = DateTime(
    observedDate.year,
    observedDate.month,
    observedDate.day,
  );
  if (current.weekday == DateTime.sunday) {
    throw ArgumentError.value(
      observedDate,
      'observedDate',
      'Không được là Chủ nhật',
    );
  }
  if (preset == SchedulePreset.thirtySlotsThreeWeeks &&
      current.weekday == DateTime.saturday) {
    throw ArgumentError.value(
      observedDate,
      'observedDate',
      'Block 3 tuần học Thứ 2–6',
    );
  }
  for (var index = 1; index < sessionNumber; index++) {
    current = switch (preset) {
      SchedulePreset.thirtySlotsThreeWeeks =>
        index.isOdd ? current : _subtractWeekdays(current, 1),
      SchedulePreset.twentySlotsTenWeeks ||
      SchedulePreset.tenSlotsFiveWeeks => _subtractTeachingDays(current, 3),
      SchedulePreset.tenSlotsTenWeeks => current.subtract(
        const Duration(days: 7),
      ),
      SchedulePreset.twentySlotsThreeWeeks ||
      SchedulePreset.tenSlotsThreeWeeks => _subtractTeachingDays(current, 1),
    };
  }
  return current;
}

/// Gợi ý ngày bắt đầu khi ảnh có ngày học nhưng không đọc được số buổi.
/// Chọn lịch bắt đầu sớm nhất trong kỳ vẫn chứa ngày được nhìn thấy.
DateTime? suggestScheduleStartDateFromObserved({
  required DateTime observedDate,
  required SchedulePreset preset,
}) {
  final observed = DateTime(
    observedDate.year,
    observedDate.month,
    observedDate.day,
  );
  if (observed.weekday == DateTime.sunday ||
      (preset == SchedulePreset.thirtySlotsThreeWeeks &&
          observed.weekday == DateTime.saturday)) {
    return null;
  }
  final firstDay = academicTermStart(observed);
  final lastDay = academicTermEnd(observed);
  DateTime? fallback;
  for (
    var candidate = firstDay;
    !candidate.isAfter(observed);
    candidate = candidate.add(const Duration(days: 1))
  ) {
    if (candidate.weekday == DateTime.sunday ||
        (preset == SchedulePreset.thirtySlotsThreeWeeks &&
            candidate.weekday == DateTime.saturday)) {
      continue;
    }
    final schedule = generateSchedule(startDate: candidate, preset: preset);
    if (!schedule.any((slot) => isSameDate(slot.date, observed))) continue;
    if (!schedule.last.date.isAfter(lastDay)) return candidate;
    fallback ??= candidate;
  }
  return fallback;
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

DateTime _subtractTeachingDays(DateTime date, int count) {
  var cursor = date;
  var remaining = count;
  while (remaining > 0) {
    cursor = cursor.subtract(const Duration(days: 1));
    if (cursor.weekday != DateTime.sunday) remaining--;
  }
  return cursor;
}

DateTime _addWeekdays(DateTime date, int count) {
  var cursor = date;
  var remaining = count;
  while (remaining > 0) {
    cursor = cursor.add(const Duration(days: 1));
    if (cursor.weekday <= DateTime.friday) remaining--;
  }
  return cursor;
}

DateTime _subtractWeekdays(DateTime date, int count) {
  var cursor = date;
  var remaining = count;
  while (remaining > 0) {
    cursor = cursor.subtract(const Duration(days: 1));
    if (cursor.weekday <= DateTime.friday) remaining--;
  }
  return cursor;
}
