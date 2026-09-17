export type SchedulePreset =
  | "20_3"
  | "20_10"
  | "10_3"
  | "10_5"
  | "10_10";

export interface ScheduledSlot {
  number: number;
  date: string;
}

export function resolvePreset(slotCount: number, weekLabel: number): SchedulePreset {
  const value = `${slotCount}_${weekLabel}` as SchedulePreset;
  if (!["20_3", "20_10", "10_3", "10_5", "10_10"].includes(value)) {
    throw new Error("Tổ hợp slot/tuần không hợp lệ.");
  }
  return value;
}

export function generateSchedule(startDate: string, preset: SchedulePreset): ScheduledSlot[] {
  const current = parseIsoDate(startDate);
  if (current.getUTCDay() === 0) throw new Error("Ngày bắt đầu không được là Chủ nhật.");

  const slotCount = preset.startsWith("20_") ? 20 : 10;
  const result: ScheduledSlot[] = [];
  let cursor = current;

  for (let index = 0; index < slotCount; index += 1) {
    result.push({number: index + 1, date: toIsoDate(cursor)});
    if (index === slotCount - 1) break;

    if (preset === "20_10" || preset === "10_5") {
      cursor = addTeachingDays(cursor, 3);
    } else if (preset === "10_10") {
      cursor = addDays(cursor, 7);
    } else {
      cursor = addTeachingDays(cursor, 1);
    }
  }
  return result;
}

function parseIsoDate(value: string): Date {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(value)) throw new Error("Ngày phải có dạng YYYY-MM-DD.");
  const date = new Date(`${value}T00:00:00.000Z`);
  if (Number.isNaN(date.getTime()) || toIsoDate(date) !== value) {
    throw new Error("Ngày không hợp lệ.");
  }
  return date;
}

function addDays(date: Date, count: number): Date {
  const result = new Date(date);
  result.setUTCDate(result.getUTCDate() + count);
  return result;
}

function addTeachingDays(date: Date, count: number): Date {
  let result = new Date(date);
  let remaining = count;
  while (remaining > 0) {
    result = addDays(result, 1);
    if (result.getUTCDay() !== 0) remaining -= 1;
  }
  return result;
}

function toIsoDate(date: Date): string {
  return date.toISOString().slice(0, 10);
}
