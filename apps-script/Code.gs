const HEADERS = [
  'Slot',
  'Date',
  'Check-in time',
  'Email',
  'Status',
  'Source',
  'Reason',
  'Session ID',
  'Updated at',
  'Record ID',
];

function doPost(event) {
  try {
    const payload = JSON.parse(event.postData.contents || '{}');
    const properties = PropertiesService.getScriptProperties();
    const expectedSecret = properties.getProperty('SYNC_SECRET');
    if (!expectedSecret || payload.secret !== expectedSecret) {
      throw new Error('Secret đồng bộ không hợp lệ.');
    }

    const spreadsheetId = requiredText(
      properties.getProperty('SPREADSHEET_ID'),
      'SPREADSHEET_ID',
    );
    if (payload.action === 'upsert' || payload.action === 'append') {
      upsertAttendance(spreadsheetId, payload);
    } else if (payload.action === 'sort') {
      sortAttendance(spreadsheetId, payload);
    } else {
      throw new Error('Action không được hỗ trợ.');
    }
    return jsonResponse({ok: true});
  } catch (error) {
    console.error(error);
    return jsonResponse({ok: false, error: String(error.message || error)});
  }
}

function upsertAttendance(spreadsheetId, payload) {
  const lock = LockService.getScriptLock();
  lock.waitLock(20000);
  try {
    const sheet = getOrCreateSheet(
      spreadsheetId,
      requiredText(payload.subject, 'subject'),
      requiredText(payload.classCode, 'classCode'),
    );
    const recordId = requiredText(payload.recordId, 'recordId');
    let existing = null;
    if (sheet.getLastRow() > 1) {
      existing = sheet
        .getRange(2, 10, sheet.getLastRow() - 1, 1)
        .createTextFinder(recordId)
        .matchEntireCell(true)
        .findNext();
    }

    const checkedInAt = payload.checkedInAt ? new Date(payload.checkedInAt) : null;
    if (checkedInAt && Number.isNaN(checkedInAt.getTime())) {
      throw new Error('checkedInAt không hợp lệ.');
    }
    const slot = Number(payload.slot);
    if (!Number.isInteger(slot) || slot < 1) throw new Error('slot không hợp lệ.');
    const attendanceStatus = requiredText(
      payload.attendanceStatus || 'present',
      'attendanceStatus',
    );
    if (!['present', 'absent', 'excused'].includes(attendanceStatus)) {
      throw new Error('attendanceStatus không hợp lệ.');
    }
    const recordSource = requiredText(payload.recordSource || 'qr', 'recordSource');

    const row = [
      slot,
      requiredText(payload.date, 'date'),
      checkedInAt
        ? Utilities.formatDate(checkedInAt, 'Asia/Ho_Chi_Minh', 'HH:mm:ss')
        : '',
      requiredText(payload.email, 'email'),
      attendanceStatus,
      recordSource,
      String(payload.reason || '').trim(),
      String(payload.sessionId || '').trim(),
      Utilities.formatDate(new Date(), 'Asia/Ho_Chi_Minh', "yyyy-MM-dd'T'HH:mm:ssXXX"),
      recordId,
    ];
    if (existing) {
      sheet.getRange(existing.getRow(), 1, 1, HEADERS.length).setValues([row]);
    } else {
      sheet.appendRow(row);
    }
    sortSheet(sheet);
  } finally {
    lock.releaseLock();
  }
}

function sortAttendance(spreadsheetId, payload) {
  const lock = LockService.getScriptLock();
  lock.waitLock(20000);
  try {
    const sheet = getOrCreateSheet(
      spreadsheetId,
      requiredText(payload.subject, 'subject'),
      requiredText(payload.classCode, 'classCode'),
    );
    sortSheet(sheet);
  } finally {
    lock.releaseLock();
  }
}

function sortSheet(sheet) {
  const rowCount = sheet.getLastRow() - 1;
  if (rowCount > 1) {
    sheet.getRange(2, 1, rowCount, HEADERS.length).sort([
      {column: 1, ascending: true},
      {column: 2, ascending: true},
      {column: 3, ascending: true},
    ]);
  }
}

function getOrCreateSheet(spreadsheetId, subject, classCode) {
  const spreadsheet = SpreadsheetApp.openById(spreadsheetId);
  const title = `${subject}_${classCode}`
    .replace(/[\\/?*\[\]:]/g, '_')
    .slice(0, 100);
  let sheet = spreadsheet.getSheetByName(title);
  if (!sheet) sheet = spreadsheet.insertSheet(title);
  if (sheet.getLastRow() === 0) {
    sheet.getRange(1, 1, 1, HEADERS.length).setValues([HEADERS]);
    sheet.setFrozenRows(1);
    sheet.getRange(1, 1, 1, HEADERS.length).setFontWeight('bold');
  } else {
    migrateLegacyHeaders(sheet);
  }
  return sheet;
}

function migrateLegacyHeaders(sheet) {
  const oldHeaders = sheet.getRange(1, 1, 1, Math.min(8, sheet.getLastColumn()))
    .getValues()[0];
  if (oldHeaders[4] === 'Result' && oldHeaders[7] === 'Record ID') {
    const rowCount = sheet.getLastRow() - 1;
    const oldRows = rowCount > 0 ? sheet.getRange(2, 1, rowCount, 8).getValues() : [];
    const migrated = oldRows.map((row) => [
      row[0], row[1], row[2], row[3], 'present', 'qr', '', row[5], row[6], row[7],
    ]);
    sheet.clearContents();
    sheet.getRange(1, 1, 1, HEADERS.length).setValues([HEADERS]);
    if (migrated.length) {
      sheet.getRange(2, 1, migrated.length, HEADERS.length).setValues(migrated);
    }
    sheet.setFrozenRows(1);
    sheet.getRange(1, 1, 1, HEADERS.length).setFontWeight('bold');
  }
}

function requiredText(value, name) {
  if (typeof value !== 'string' || value.trim() === '') {
    throw new Error(`${name} đang trống.`);
  }
  return value.trim();
}

function jsonResponse(value) {
  return ContentService
    .createTextOutput(JSON.stringify(value))
    .setMimeType(ContentService.MimeType.JSON);
}
