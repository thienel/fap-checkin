import assert from "node:assert/strict";
import test from "node:test";

import {generateSchedule} from "./schedule";

test("two sessions per week skips Sunday", () => {
  const slots = generateSchedule("2026-09-17", "10_5"); // Thursday
  assert.deepEqual(slots.slice(0, 4).map((item) => item.date), [
    "2026-09-17",
    "2026-09-21",
    "2026-09-24",
    "2026-09-28",
  ]);
});

test("weekly preset preserves weekday", () => {
  const slots = generateSchedule("2026-09-16", "10_10");
  assert.equal(slots.length, 10);
  assert.equal(slots[1].date, "2026-09-23");
  assert.equal(slots[9].date, "2026-11-18");
});

test("intensive preset fills every non-Sunday", () => {
  const slots = generateSchedule("2026-09-19", "10_3"); // Saturday
  assert.equal(slots[1].date, "2026-09-21");
  assert.equal(slots.length, 10);
});

test("Sunday is rejected", () => {
  assert.throws(() => generateSchedule("2026-09-20", "20_3"), /Chủ nhật/);
});
