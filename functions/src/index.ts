import {createHash, randomBytes} from "node:crypto";

import {initializeApp} from "firebase-admin/app";
import {FieldValue, Timestamp, getFirestore} from "firebase-admin/firestore";
import {HttpsError, onCall} from "firebase-functions/v2/https";
import {defineString} from "firebase-functions/params";
import {onSchedule} from "firebase-functions/v2/scheduler";
import {setGlobalOptions} from "firebase-functions/v2/options";

import {generateSchedule, resolvePreset} from "./schedule";
import {appendAttendance, sortAttendanceSheet} from "./sheets";

initializeApp();
setGlobalOptions({region: "asia-southeast1", maxInstances: 20});

const db = getFirestore();
const spreadsheetId = defineString("GOOGLE_SHEETS_ID");
const publicWebUrl = defineString("PUBLIC_WEB_URL");

const codePattern = /^[A-Z0-9_-]{2,20}$/;

export const createCourseClass = onCall(async (request) => {
  const uid = await assertTeacher(request.auth?.uid);
  const subject = requiredCode(request.data?.subject, "subject");
  const classCode = requiredCode(request.data?.classCode, "classCode");
  const startDate = requiredString(request.data?.startDate, "startDate");
  const slotCount = requiredInteger(request.data?.slotCount, "slotCount");
  const weekLabel = requiredInteger(request.data?.weekLabel, "weekLabel");

  let schedule;
  try {
    schedule = generateSchedule(startDate, resolvePreset(slotCount, weekLabel));
  } catch (error) {
    throw new HttpsError("invalid-argument", messageOf(error));
  }

  const id = `${subject}_${classCode}`;
  const ref = db.collection("courseClasses").doc(id);
  if ((await ref.get()).exists) {
    throw new HttpsError("already-exists", "Môn–lớp này đã tồn tại.");
  }

  await ref.create({
    subject,
    classCode,
    startDate,
    slotCount,
    weekLabel,
    schedule,
    ownerUid: uid,
    createdAt: FieldValue.serverTimestamp(),
  });
  return {courseClassId: id, schedule};
});

export const getTodaySlots = onCall(async (request) => {
  const uid = await assertTeacher(request.auth?.uid);
  const date = requiredString(request.data?.date, "date");
  if (!/^\d{4}-\d{2}-\d{2}$/.test(date)) {
    throw new HttpsError("invalid-argument", "Ngày phải có dạng YYYY-MM-DD.");
  }

  const snapshot = await db.collection("courseClasses").where("ownerUid", "==", uid).get();
  const slots: Array<Record<string, unknown>> = [];
  for (const document of snapshot.docs) {
    const data = document.data();
    const match = (data.schedule as Array<{number: number; date: string}>).find(
      (item) => item.date === date,
    );
    if (match) {
      slots.push({
        courseClassId: document.id,
        subject: data.subject,
        classCode: data.classCode,
        slot: match.number,
        date: match.date,
      });
    }
  }
  slots.sort((a, b) => String(a.subject).localeCompare(String(b.subject)));
  return {slots};
});

export const getActiveAttendance = onCall(async (request) => {
  const uid = await assertTeacher(request.auth?.uid);
  const activeRef = db.collection("activeAttendanceSessions").doc(uid);
  const activeSnapshot = await activeRef.get();
  const sessionId = activeSnapshot.data()?.sessionId as string | undefined;
  if (!activeSnapshot.exists || !sessionId) return {session: null};

  const sessionSnapshot = await db.collection("attendanceSessions").doc(sessionId).get();
  const session = sessionSnapshot.data();
  if (!sessionSnapshot.exists || !session || session.status !== "active") {
    await activeRef.delete();
    return {session: null};
  }
  if (session.ownerUid !== uid) {
    throw new HttpsError("permission-denied", "Phiên điểm danh không thuộc tài khoản này.");
  }
  return {
    session: {
      sessionId: sessionSnapshot.id,
      subject: session.subject,
      classCode: session.classCode,
      slot: session.slot,
      date: session.date,
      rotationSeconds: session.rotationSeconds,
      validitySeconds: session.validitySeconds,
    },
  };
});

export const startAttendance = onCall(async (request) => {
  const uid = await assertTeacher(request.auth?.uid);
  const courseClassId = requiredString(request.data?.courseClassId, "courseClassId");
  const slot = requiredInteger(request.data?.slot, "slot");
  const rotationSeconds = boundedInteger(request.data?.rotationSeconds, "rotationSeconds", 1, 60);
  const validitySeconds = boundedInteger(request.data?.validitySeconds, "validitySeconds", 2, 120);
  if (validitySeconds < rotationSeconds) {
    throw new HttpsError(
      "invalid-argument",
      "Thời hạn QR phải lớn hơn hoặc bằng chu kỳ đổi QR.",
    );
  }

  const courseSnapshot = await db.collection("courseClasses").doc(courseClassId).get();
  if (!courseSnapshot.exists || courseSnapshot.data()?.ownerUid !== uid) {
    throw new HttpsError("not-found", "Không tìm thấy môn–lớp.");
  }
  const course = courseSnapshot.data()!;
  const scheduled = (course.schedule as Array<{number: number; date: string}>).find(
    (item) => item.number === slot,
  );
  if (!scheduled) throw new HttpsError("invalid-argument", "Slot không tồn tại.");
  if (scheduled.date !== vietnamDate(new Date())) {
    throw new HttpsError("failed-precondition", "Chỉ có thể mở slot được xếp lịch hôm nay.");
  }

  const sessionRef = db.collection("attendanceSessions").doc();
  const activeRef = db.collection("activeAttendanceSessions").doc(uid);
  await db.runTransaction(async (transaction) => {
    if ((await transaction.get(activeRef)).exists) {
      throw new HttpsError(
        "already-exists",
        "Bạn đang có một phiên điểm danh khác. Hãy ngừng phiên đó trước.",
      );
    }
    transaction.create(sessionRef, {
      ownerUid: uid,
      courseClassId,
      subject: course.subject,
      classCode: course.classCode,
      slot,
      date: scheduled.date,
      rotationSeconds,
      validitySeconds,
      status: "active",
      attendanceCount: 0,
      startedAt: FieldValue.serverTimestamp(),
    });
    transaction.create(activeRef, {sessionId: sessionRef.id});
  });

  return {
    sessionId: sessionRef.id,
    subject: course.subject,
    classCode: course.classCode,
    slot,
    date: scheduled.date,
    rotationSeconds,
    validitySeconds,
  };
});

export const issueQrToken = onCall(async (request) => {
  const uid = await assertTeacher(request.auth?.uid);
  const sessionId = requiredString(request.data?.sessionId, "sessionId");
  const sessionSnapshot = await db.collection("attendanceSessions").doc(sessionId).get();
  const session = sessionSnapshot.data();
  if (!sessionSnapshot.exists || !session || session.ownerUid !== uid) {
    throw new HttpsError("not-found", "Không tìm thấy phiên điểm danh.");
  }
  if (session.status !== "active") {
    throw new HttpsError("failed-precondition", "Phiên điểm danh đã kết thúc.");
  }

  const issuedAt = Timestamp.now();
  const expiresAt = Timestamp.fromMillis(
    issuedAt.toMillis() + Number(session.validitySeconds) * 1000,
  );
  const token = randomBytes(32).toString("base64url");
  await db.collection("qrTokens").doc(token).create({sessionId, issuedAt, expiresAt});

  return {
    checkInUrl: `${publicWebUrl.value().replace(/\/$/, "")}/check-in?t=${token}`,
    expiresAt: expiresAt.toDate().toISOString(),
  };
});

export const stopAttendance = onCall(async (request) => {
  const uid = await assertTeacher(request.auth?.uid);
  const sessionId = requiredString(request.data?.sessionId, "sessionId");
  const sessionRef = db.collection("attendanceSessions").doc(sessionId);
  const activeRef = db.collection("activeAttendanceSessions").doc(uid);

  let subject = "";
  let classCode = "";
  await db.runTransaction(async (transaction) => {
    const snapshot = await transaction.get(sessionRef);
    const activeSnapshot = await transaction.get(activeRef);
    const session = snapshot.data();
    if (!snapshot.exists || !session || session.ownerUid !== uid) {
      throw new HttpsError("not-found", "Không tìm thấy phiên điểm danh.");
    }
    subject = session.subject as string;
    classCode = session.classCode as string;
    if (session.status === "active") {
      transaction.update(sessionRef, {
        status: "stopped",
        stoppedAt: FieldValue.serverTimestamp(),
      });
    }
    if (activeSnapshot.data()?.sessionId === sessionId) {
      transaction.delete(activeRef);
    }
  });

  let sortWarning: string | null = null;
  try {
    await sortAttendanceSheet(spreadsheetId.value(), subject, classCode);
  } catch (error) {
    console.error("Cannot sort attendance sheet", error);
    sortWarning = "Phiên đã dừng nhưng chưa thể sắp xếp Google Sheet.";
  }
  return {stopped: true, warning: sortWarning};
});

export const checkIn = onCall(async (request) => {
  if (!request.auth) throw new HttpsError("unauthenticated", "Hãy đăng nhập Google.");
  const provider = request.auth.token.firebase?.sign_in_provider;
  if (provider !== "google.com") {
    throw new HttpsError("permission-denied", "Điểm danh yêu cầu tài khoản Google.");
  }
  const email = String(request.auth.token.email ?? "").trim().toLowerCase();
  if (!email) throw new HttpsError("failed-precondition", "Tài khoản Google không có email.");
  const token = requiredString(request.data?.token, "token");
  const tokenRef = db.collection("qrTokens").doc(token);
  const now = Timestamp.now();

  let checkInId = "";
  let wasCreated = false;
  await db.runTransaction(async (transaction) => {
    const tokenSnapshot = await transaction.get(tokenRef);
    const tokenData = tokenSnapshot.data();
    if (!tokenSnapshot.exists || !tokenData) {
      throw new HttpsError("not-found", "QR không hợp lệ.");
    }
    const expiresAt = tokenData.expiresAt as Timestamp;
    if (now.toMillis() > expiresAt.toMillis()) {
      throw new HttpsError("deadline-exceeded", "QR đã hết hạn. Hãy quét mã mới.");
    }

    const sessionId = tokenData.sessionId as string;
    const sessionRef = db.collection("attendanceSessions").doc(sessionId);
    const sessionSnapshot = await transaction.get(sessionRef);
    const session = sessionSnapshot.data();
    if (!sessionSnapshot.exists || !session || session.status !== "active") {
      throw new HttpsError("failed-precondition", "Phiên điểm danh đã kết thúc.");
    }

    checkInId = createHash("sha256")
      .update(`${session.courseClassId}|${session.slot}|${email}`)
      .digest("hex");
    const checkInRef = db.collection("checkIns").doc(checkInId);
    if ((await transaction.get(checkInRef)).exists) return;

    wasCreated = true;
    transaction.create(checkInRef, {
      email,
      sessionId,
      courseClassId: session.courseClassId,
      subject: session.subject,
      classCode: session.classCode,
      slot: session.slot,
      date: session.date,
      checkedInAt: now,
      recordedAt: now,
      syncStatus: "pending",
      createdAt: now,
    });
    transaction.update(sessionRef, {attendanceCount: FieldValue.increment(1)});
  });

  if (!wasCreated) return {status: "duplicate", email};
  const synced = await syncCheckIn(checkInId);
  return {status: "valid", email, sheetSync: synced ? "complete" : "pending"};
});

export const retrySheetSync = onSchedule("every 5 minutes", async () => {
  const snapshot = await db
    .collection("checkIns")
    .where("syncStatus", "in", ["pending", "error"])
    .limit(50)
    .get();
  await Promise.allSettled(snapshot.docs.map((document) => syncCheckIn(document.id)));
});

export const cleanupExpiredQrTokens = onSchedule("every 30 minutes", async () => {
  const snapshot = await db
    .collection("qrTokens")
    .where("expiresAt", "<", Timestamp.now())
    .limit(500)
    .get();
  if (snapshot.empty) return;
  const batch = db.batch();
  snapshot.docs.forEach((document) => batch.delete(document.ref));
  await batch.commit();
});

async function syncCheckIn(checkInId: string): Promise<boolean> {
  const ref = db.collection("checkIns").doc(checkInId);
  const snapshot = await ref.get();
  const data = snapshot.data();
  if (!snapshot.exists || !data) return false;
  if (data.syncStatus === "complete") return true;

  try {
    await appendAttendance(spreadsheetId.value(), {
      recordId: checkInId,
      subject: data.subject,
      classCode: data.classCode,
      slot: data.slot,
      date: data.date,
      email: data.email,
      sessionId: data.sessionId,
      checkedInAt: (data.checkedInAt as Timestamp).toDate(),
      recordedAt: (data.recordedAt as Timestamp).toDate(),
    });
    await ref.update({syncStatus: "complete", syncedAt: FieldValue.serverTimestamp()});
    return true;
  } catch (error) {
    console.error(`Cannot sync check-in ${checkInId}`, error);
    await ref.update({syncStatus: "error", syncError: messageOf(error).slice(0, 500)});
    return false;
  }
}

async function assertTeacher(uid: string | undefined): Promise<string> {
  if (!uid) throw new HttpsError("unauthenticated", "Hãy đăng nhập giảng viên.");
  const teacher = await db.collection("teachers").doc(uid).get();
  if (!teacher.exists || teacher.data()?.active !== true) {
    throw new HttpsError("permission-denied", "Tài khoản chưa được cấp quyền giảng viên.");
  }
  return uid;
}

function requiredCode(value: unknown, field: string): string {
  const code = requiredString(value, field).toUpperCase();
  if (!codePattern.test(code)) {
    throw new HttpsError("invalid-argument", `${field} chỉ nhận 2–20 ký tự A–Z, 0–9, _ hoặc -.`);
  }
  return code;
}

function requiredString(value: unknown, field: string): string {
  if (typeof value !== "string" || value.trim() === "") {
    throw new HttpsError("invalid-argument", `Thiếu ${field}.`);
  }
  return value.trim();
}

function requiredInteger(value: unknown, field: string): number {
  if (typeof value !== "number" || !Number.isInteger(value)) {
    throw new HttpsError("invalid-argument", `${field} phải là số nguyên.`);
  }
  return value;
}

function boundedInteger(value: unknown, field: string, min: number, max: number): number {
  const result = requiredInteger(value, field);
  if (result < min || result > max) {
    throw new HttpsError("invalid-argument", `${field} phải từ ${min} đến ${max}.`);
  }
  return result;
}

function messageOf(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

function vietnamDate(date: Date): string {
  const parts = new Intl.DateTimeFormat("en-GB", {
    timeZone: "Asia/Ho_Chi_Minh",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).formatToParts(date);
  const value = Object.fromEntries(parts.map((part) => [part.type, part.value]));
  return `${value.year}-${value.month}-${value.day}`;
}
