import {google, sheets_v4} from "googleapis";

export interface AttendanceRow {
  recordId: string;
  subject: string;
  classCode: string;
  slot: number;
  date: string;
  email: string;
  sessionId: string;
  checkedInAt: Date;
  recordedAt: Date;
}

const headers = [
  "Slot",
  "Date",
  "Check-in time",
  "Email",
  "Result",
  "Session ID",
  "Recorded at",
  "Record ID",
];

function sheetTitle(subject: string, classCode: string): string {
  return `${subject}_${classCode}`.replace(/[\\/?*\[\]:]/g, "_").slice(0, 100);
}

async function client(): Promise<sheets_v4.Sheets> {
  const auth = new google.auth.GoogleAuth({
    scopes: ["https://www.googleapis.com/auth/spreadsheets"],
  });
  return google.sheets({version: "v4", auth});
}

async function ensureSheet(
  sheets: sheets_v4.Sheets,
  spreadsheetId: string,
  title: string,
): Promise<number> {
  const metadata = await sheets.spreadsheets.get({
    spreadsheetId,
    fields: "sheets.properties",
  });
  const existing = metadata.data.sheets?.find((sheet) => sheet.properties?.title === title);
  if (existing?.properties?.sheetId != null) return existing.properties.sheetId;

  try {
    const created = await sheets.spreadsheets.batchUpdate({
      spreadsheetId,
      requestBody: {requests: [{addSheet: {properties: {title}}}]},
    });
    const sheetId = created.data.replies?.[0]?.addSheet?.properties?.sheetId;
    if (sheetId == null) throw new Error("Không nhận được sheetId sau khi tạo tab.");
    await sheets.spreadsheets.values.update({
      spreadsheetId,
      range: `'${title}'!A1:H1`,
      valueInputOption: "RAW",
      requestBody: {values: [headers]},
    });
    return sheetId;
  } catch (error) {
    // Another concurrent request may have created the same tab.
    const retried = await sheets.spreadsheets.get({
      spreadsheetId,
      fields: "sheets.properties",
    });
    const found = retried.data.sheets?.find((sheet) => sheet.properties?.title === title);
    if (found?.properties?.sheetId != null) return found.properties.sheetId;
    throw error;
  }
}

export async function appendAttendance(
  spreadsheetId: string,
  row: AttendanceRow,
): Promise<void> {
  const sheets = await client();
  const title = sheetTitle(row.subject, row.classCode);
  await ensureSheet(sheets, spreadsheetId, title);

  const ids = await sheets.spreadsheets.values.get({
    spreadsheetId,
    range: `'${title}'!H:H`,
  });
  if (ids.data.values?.some((value) => value[0] === row.recordId)) return;

  const localTime = new Intl.DateTimeFormat("en-GB", {
    timeZone: "Asia/Ho_Chi_Minh",
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
    hour12: false,
  }).format(row.checkedInAt);

  await sheets.spreadsheets.values.append({
    spreadsheetId,
    range: `'${title}'!A:H`,
    valueInputOption: "USER_ENTERED",
    insertDataOption: "INSERT_ROWS",
    requestBody: {
      values: [[
        row.slot,
        row.date,
        localTime,
        row.email,
        "VALID",
        row.sessionId,
        row.recordedAt.toISOString(),
        row.recordId,
      ]],
    },
  });
}

export async function sortAttendanceSheet(
  spreadsheetId: string,
  subject: string,
  classCode: string,
): Promise<void> {
  const sheets = await client();
  const title = sheetTitle(subject, classCode);
  const sheetId = await ensureSheet(sheets, spreadsheetId, title);
  await sheets.spreadsheets.batchUpdate({
    spreadsheetId,
    requestBody: {
      requests: [{
        sortRange: {
          range: {sheetId, startRowIndex: 1, startColumnIndex: 0, endColumnIndex: 8},
          sortSpecs: [
            {dimensionIndex: 0, sortOrder: "ASCENDING"},
            {dimensionIndex: 1, sortOrder: "ASCENDING"},
            {dimensionIndex: 2, sortOrder: "ASCENDING"},
          ],
        },
      }],
    },
  });
}
