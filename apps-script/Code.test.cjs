const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const { test } = require('node:test');
const vm = require('node:vm');

test('an older request cannot replace a newer Sheets revision', () => {
  const rows = [];
  const headers = [
    'Slot', 'Date', 'Check-in time', 'Email', 'Status', 'Source', 'Reason',
    'Session ID', 'Updated at', 'Record ID', 'Revision',
  ];
  const sheet = {
    getLastRow: () => rows.length + 1,
    getLastColumn: () => headers.length,
    getRange(row, column, count, width) {
      return {
        getValues: () => row === 1 ? [headers.slice(column - 1, column - 1 + width)] : [],
        getValue: () => rows[row - 2][column - 1],
        setValues(values) {
          if (row === 1) return;
          rows[row - 2] = values[0];
        },
        createTextFinder(recordId) {
          return {
            matchEntireCell() { return this; },
            findNext() {
              const index = rows.findIndex((item) => item[9] === recordId);
              return index < 0 ? null : { getRow: () => index + 2 };
            },
          };
        },
        sort() {},
      };
    },
    appendRow(row) { rows.push(row); },
  };
  const sandbox = {
    LockService: { getScriptLock: () => ({ waitLock() {}, releaseLock() {} }) },
    SpreadsheetApp: { openById: () => ({ getSheetByName: () => sheet }) },
    Utilities: { formatDate: () => '2026-09-26T10:00:00+07:00' },
  };
  const source = readFileSync(require.resolve('./Code.gs'), 'utf8');
  vm.runInNewContext(`${source}\nthis.upsertAttendance = upsertAttendance;`, sandbox);

  const payload = {
    subject: 'PRM393', classCode: 'SE1917', recordId: 'record-1', slot: 1,
    date: '2026-09-26', email: 'student@fpt.edu.vn', sessionId: 'session-1',
    attendanceStatus: 'absent', recordSource: 'teacher', revision: 2,
  };
  assert.equal(sandbox.upsertAttendance('spreadsheet-1', payload), 2);
  assert.equal(rows[0][4], 'absent');
  assert.equal(rows[0][10], 2);

  assert.throws(() => sandbox.upsertAttendance('spreadsheet-1', {
    ...payload, attendanceStatus: 'present', revision: 1,
  }), /revision mới hơn/);
  assert.equal(rows[0][4], 'absent');
  assert.equal(rows[0][10], 2);
});

test('new course instances use separate sheets while legacy IDs keep their tabs', () => {
  const names = [];
  const sheet = {
    getLastRow: () => 1,
    getLastColumn: () => 11,
    getRange: () => ({ getValues: () => [['Slot', 'Date', 'Check-in time', 'Email', 'Status']] }),
  };
  const sandbox = {
    SpreadsheetApp: { openById: () => ({ getSheetByName(name) { names.push(name); return sheet; } }) },
  };
  const source = readFileSync(require.resolve('./Code.gs'), 'utf8');
  vm.runInNewContext(`${source}\nthis.getOrCreateSheet = getOrCreateSheet;`, sandbox);
  sandbox.getOrCreateSheet('spreadsheet-1', 'PRM393', 'SE01', 'PRM393_SE01');
  sandbox.getOrCreateSheet('spreadsheet-1', 'PRM393', 'SE01', 'instance-new');
  assert.deepEqual(names, ['PRM393_SE01', 'instance-new_PRM393_SE01']);
});
