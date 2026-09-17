const HEADERS = [
  'Slot',
  'Date',
  'Check-in time',
  'Email',
  'Result',
  'Session ID',
  'Recorded at',
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
    if (payload.action === 'append') {
      appendAttendance(spreadsheetId, payload);
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

function appendAttendance(spreadsheetId, payload) {
  const lock = LockService.getScriptLock();
  lock.waitLock(20000);
  try {
    const sheet = getOrCreateSheet(
      spreadsheetId,
      requiredText(payload.subject, 'subject'),
      requiredText(payload.classCode, 'classCode'),
    );
    const recordId = requiredText(payload.recordId, 'recordId');
    if (sheet.getLastRow() > 1) {
      const existing = sheet
        .getRange(2, 8, sheet.getLastRow() - 1, 1)
        .createTextFinder(recordId)
        .matchEntireCell(true)
        .findNext();
      if (existing) return;
    }

    const checkedInAt = new Date(requiredText(payload.checkedInAt, 'checkedInAt'));
    if (Number.isNaN(checkedInAt.getTime())) {
      throw new Error('checkedInAt không hợp lệ.');
    }
    const slot = Number(payload.slot);
    if (!Number.isInteger(slot) || slot < 1) throw new Error('slot không hợp lệ.');

    sheet.appendRow([
      slot,
      requiredText(payload.date, 'date'),
      Utilities.formatDate(checkedInAt, 'Asia/Ho_Chi_Minh', 'HH:mm:ss'),
      requiredText(payload.email, 'email'),
      'VALID',
      requiredText(payload.sessionId, 'sessionId'),
      Utilities.formatDate(checkedInAt, 'Asia/Ho_Chi_Minh', "yyyy-MM-dd'T'HH:mm:ssXXX"),
      recordId,
    ]);
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
  }
  return sheet;
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
