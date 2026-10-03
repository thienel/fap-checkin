import { readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { after, before, test } from 'node:test';

import {
  assertFails,
  assertSucceeds,
  initializeTestEnvironment,
} from '@firebase/rules-unit-testing';
import {
  collection,
  collectionGroup,
  deleteDoc,
  doc,
  getDoc,
  getDocs,
  query,
  runTransaction,
  serverTimestamp,
  setDoc,
  updateDoc,
  where,
  writeBatch,
} from 'firebase/firestore';

const projectId = 'demo-fap-checkin-rules';
const teacherUid = 'teacher-1';
const otherTeacherUid = 'teacher-2';
const studentUid = 'student-uid-1';
const courseClassId = 'TEST_DEMO_20260920';
let testEnvironment;

const now = new Date();
const futureTime = new Date(Date.now() + 60 * 1000);

before(async () => {
  testEnvironment = await initializeTestEnvironment({
    projectId,
    firestore: {
      rules: readFileSync(new URL('../../firestore.rules', import.meta.url), 'utf8'),
    },
  });

  await testEnvironment.withSecurityRulesDisabled(async (context) => {
    const db = context.firestore();

    // Teachers
    await setDoc(doc(db, 'teachers', teacherUid), { active: true });
    await setDoc(doc(db, 'teachers', otherTeacherUid), { active: true });

    // Course classes
    await setDoc(doc(db, 'courseClasses', courseClassId), {
      ownerUid: teacherUid,
      subject: 'PRM393',
      classCode: 'DEMO',
    });
    await setDoc(doc(db, 'courseClasses', 'OTHER_CLASS'), {
      ownerUid: otherTeacherUid,
      subject: 'PRM393',
      classCode: 'OTHER',
    });

    // Student in roster
    const studentDocId = 'student-hash-1';
    await setDoc(doc(db, 'courseClasses', courseClassId, 'students', studentDocId), {
      emailNormalized: 'student1@fpt.edu.vn',
      email: 'student1@fpt.edu.vn',
      studentCode: 'SE001',
      studentCodeNormalized: 'SE001',
      fullName: 'Nguyen Van A',
      active: true,
      attendancePolicy: 'normal',
    });
    await setDoc(doc(db, 'courseClasses', courseClassId, 'students', 'student-hash-2'), {
      emailNormalized: 'student2@fpt.edu.vn',
      email: 'student2@fpt.edu.vn',
      studentCode: 'SE002',
      studentCodeNormalized: 'SE002',
      fullName: 'Nguyen Van B',
      active: true,
      attendancePolicy: 'normal',
    });

    // Active session
    await setDoc(doc(db, 'attendanceSessions', 'session-1'), {
      ownerUid: teacherUid,
      courseClassId,
      subject: 'PRM393',
      classCode: 'DEMO',
      slot: 1,
      slotKey: '1',
      date: '2026-09-20',
      status: 'active',
      rotationSeconds: 10,
      validitySeconds: 30,
      currentQrGeneration: 5,
    });

    // Stopped session
    await setDoc(doc(db, 'attendanceSessions', 'session-stopped'), {
      ownerUid: teacherUid,
      courseClassId,
      subject: 'PRM393',
      classCode: 'DEMO',
      slot: 2,
      slotKey: '2',
      date: '2026-09-20',
      status: 'stopped',
      rotationSeconds: 10,
      validitySeconds: 30,
      currentQrGeneration: 3,
    });

    // QR token for generation 5 (valid)
    await setDoc(doc(db, 'qrTokens', 'valid-token-gen5'), {
      ownerUid: teacherUid,
      sessionId: 'session-1',
      issuedAt: new Date(),
      validitySeconds: 30,
      qrGeneration: 5,
    });

    // QR token for generation 4 (old/stale)
    await setDoc(doc(db, 'qrTokens', 'stale-token-gen4'), {
      ownerUid: teacherUid,
      sessionId: 'session-1',
      issuedAt: new Date(),
      validitySeconds: 30,
      qrGeneration: 4,
    });

    // Existing records for tests
    await setDoc(
      doc(db, 'attendance', courseClassId, 'slots', '1', 'records', 'student-1'),
      {
        ownerUid: teacherUid,
        studentId: 'student-1',
        courseClassId,
        slotKey: '1',
        attendanceStatus: 'present',
        recordSource: 'qr',
        syncStatus: 'pending',
      },
    );
    await setDoc(
      doc(db, 'attendance', 'OTHER_CLASS', 'slots', '1', 'records', 'student-2'),
      {
        ownerUid: otherTeacherUid,
        studentId: 'student-2',
        courseClassId: 'OTHER_CLASS',
        slotKey: '1',
        attendanceStatus: 'present',
        recordSource: 'qr',
        syncStatus: 'pending',
      },
    );

    // TeacherScheduleLocks
    await setDoc(doc(db, 'teacherScheduleLocks', `${teacherUid}_2026-09-20_1`), {
      ownerUid: teacherUid,
      date: '2026-09-20',
      daySlot: 1,
      courseClassId,
      subject: 'PRM393',
      classCode: 'DEMO',
      slotNumber: 1,
    });

    // StudentCodeClaims
    await setDoc(doc(db, 'courseClasses', courseClassId, 'studentCodeClaims', 'SE001'), {
      studentId: 'student-hash-1',
      ownerUid: teacherUid,
    });
  });
});

after(async () => {
  await testEnvironment?.cleanup();
});

test('mobile discovery requires own normalized email and active filter', async () => {
  const db = testEnvironment.authenticatedContext('mobile-discovery', {
    email: 'STUDENT1@FPT.EDU.VN', firebase: { sign_in_provider: 'google.com' },
  }).firestore();
  const group = collectionGroup(db, 'students');
  await assertSucceeds(getDocs(query(group,
    where('emailNormalized', '==', 'student1@fpt.edu.vn'), where('active', '==', true))));
  await assertFails(getDocs(group));
  await assertFails(getDocs(query(group, where('emailNormalized', '==', 'student1@fpt.edu.vn'))));
  await assertFails(getDocs(query(group,
    where('emailNormalized', '==', 'student2@fpt.edu.vn'), where('active', '==', true))));
  for (const context of [testEnvironment.unauthenticatedContext(),
    testEnvironment.authenticatedContext('password-user', {
      email: 'student1@fpt.edu.vn', firebase: { sign_in_provider: 'password' },
    })]) {
    await assertFails(getDocs(query(collectionGroup(context.firestore(), 'students'),
      where('emailNormalized', '==', 'student1@fpt.edu.vn'), where('active', '==', true))));
  }
  await assertFails(setDoc(doc(db, 'fake', 'course', 'students', 'forged'), {
    emailNormalized: 'student1@fpt.edu.vn', active: true,
  }));
});

test('mobile access allows closed-session queries and is revoked by inactive roster', async () => {
  const id = 'MOBILE_ACCESS';
  const uid = 'mobile-access';
  await testEnvironment.withSecurityRulesDisabled(async (context) => {
    const db = context.firestore();
    await setDoc(doc(db, 'courseClasses', id), { ownerUid: teacherUid, subject: 'TEST', classCode: 'MOB' });
    await setDoc(doc(db, 'courseClasses', id, 'students', 'my-student'), {
      emailNormalized: 'mobile@example.com', active: true,
    });
    await setDoc(doc(db, 'attendanceSessions', 'mobile-closed'), {
      ownerUid: teacherUid, courseClassId: id, slot: 1, status: 'stopped',
    });
  });
  const db = testEnvironment.authenticatedContext(uid, {
    email: 'MOBILE@example.com', firebase: { sign_in_provider: 'google.com' },
  }).firestore();
  const access = doc(db, 'courseClasses', id, 'studentAccess', uid);
  await assertFails(getDocs(query(collection(db, 'attendanceSessions'), where('courseClassId', '==', id))));
  await assertSucceeds(setDoc(access, {
    studentId: 'my-student', emailNormalized: 'mobile@example.com', createdAt: serverTimestamp(),
  }));
  await assertSucceeds(getDoc(doc(db, 'courseClasses', id)));
  await assertSucceeds(getDocs(query(collection(db, 'attendanceSessions'), where('courseClassId', '==', id))));
  await assertSucceeds(getDoc(doc(db, 'attendanceSessions', 'mobile-closed')));
  await assertFails(getDocs(collection(db, 'attendanceSessions')));
  await assertFails(getDocs(query(collection(db, 'attendanceSessions'), where('courseClassId', '==', courseClassId))));
  await assertSucceeds(getDoc(doc(db, 'attendance', id, 'slots', '1', 'records', 'my-student')));
  await assertSucceeds(getDoc(doc(db, 'attendance', id, 'slots', '1', 'checkIns', uid)));
  await assertSucceeds(getDocs(query(collection(db, 'courseClasses', id, 'leaveRequests'), where('firebaseUid', '==', uid))));
  await assertFails(getDoc(doc(db, 'attendanceCheckoutCodes', 'session-1')));
  await assertFails(getDocs(collection(db, 'attendance', id, 'slots', '1', 'records')));
  await assertFails(getDoc(doc(db, 'courseClasses', id, 'imports', 'private')));
  await testEnvironment.withSecurityRulesDisabled(async (context) => {
    await updateDoc(doc(context.firestore(), 'courseClasses', id, 'students', 'my-student'), { active: false });
  });
  await assertFails(getDoc(doc(db, 'courseClasses', id)));
  await assertFails(getDoc(doc(db, 'courseClasses', id, 'students', 'my-student')));
  await assertFails(getDocs(query(collection(db, 'attendanceSessions'), where('courseClassId', '==', id))));
  await assertFails(getDoc(doc(db, 'attendance', id, 'slots', '1', 'records', 'my-student')));
  await assertFails(getDoc(doc(db, 'attendance', id, 'slots', '1', 'checkIns', uid)));
  await assertFails(getDocs(query(collection(db, 'courseClasses', id, 'leaveRequests'), where('firebaseUid', '==', uid))));
});

test('mobile access cannot claim another student or another UID', async () => {
  const uid = 'mobile-forger';
  const db = testEnvironment.authenticatedContext(uid, {
    email: 'student1@fpt.edu.vn', firebase: { sign_in_provider: 'google.com' },
  }).firestore();
  await assertFails(setDoc(doc(db, 'courseClasses', courseClassId, 'studentAccess', uid), {
    studentId: 'student-hash-2', emailNormalized: 'student1@fpt.edu.vn', createdAt: serverTimestamp(),
  }));
  await assertFails(setDoc(doc(db, 'courseClasses', courseClassId, 'studentAccess', 'another-uid'), {
    studentId: 'student-hash-1', emailNormalized: 'student1@fpt.edu.vn', createdAt: serverTimestamp(),
  }));
});

test('mobile discovers classes assigned before first login across teachers and terms', async () => {
  const email = 'multicourse@example.com';
  const studentId = createHash('sha256').update(email).digest('hex');
  await testEnvironment.withSecurityRulesDisabled(async (context) => {
    const admin = context.firestore();
    for (const [id, ownerUid, academicTerm, active] of [
      ['MOBILE_TERM_A', teacherUid, '2026-SUMMER', true],
      ['MOBILE_TERM_B', otherTeacherUid, '2026-FALL', true],
      ['MOBILE_TERM_INACTIVE', teacherUid, '2026-FALL', false],
    ]) {
      await setDoc(doc(admin, 'courseClasses', id), { ownerUid, academicTerm, subject: 'PRM393', classCode: 'SE1910' });
      await setDoc(doc(admin, 'courseClasses', id, 'students', studentId), { emailNormalized: email, active });
    }
  });
  const db = testEnvironment.authenticatedContext('first-mobile-login', {
    email: 'MULTICOURSE@example.com', firebase: { sign_in_provider: 'google.com' },
  }).firestore();
  const results = await assertSucceeds(getDocs(query(collectionGroup(db, 'students'),
    where('emailNormalized', '==', email), where('active', '==', true))));
  const ids = results.docs.map((d) => d.ref.parent.parent.id).sort();
  if (JSON.stringify(ids) !== JSON.stringify(['MOBILE_TERM_A', 'MOBILE_TERM_B'])) {
    throw new Error(`Unexpected discovery results: ${ids}`);
  }
  for (const id of ids) {
    await assertSucceeds(setDoc(doc(db, 'courseClasses', id, 'studentAccess', 'first-mobile-login'), {
      studentId, emailNormalized: email, createdAt: serverTimestamp(),
    }));
    await assertSucceeds(getDoc(doc(db, 'courseClasses', id)));
  }
});

test('mobile transaction uses canonical payload and concurrent scans preserve one record', async () => {
  const email = 'concurrent@example.com';
  const studentId = createHash('sha256').update(email).digest('hex');
  const id = 'MOBILE_TRANSACTION';
  const sessionId = 'mobile-transaction-session';
  const token = 'mobile-transaction-token';
  const user = 'mobile-transaction-user';
  const transactionTeacher = 'mobile-transaction-teacher';
  await testEnvironment.withSecurityRulesDisabled(async (context) => {
    const db = context.firestore();
    await setDoc(doc(db, 'teachers', transactionTeacher), { active: true });
    await setDoc(doc(db, 'courseClasses', id), { ownerUid: transactionTeacher, subject: 'PRM393', classCode: 'MOB' });
    await setDoc(doc(db, 'courseClasses', id, 'students', studentId), {
      email, emailNormalized: email, studentCode: 'SE123', fullName: 'Student Test', active: true,
    });
    await setDoc(doc(db, 'attendanceSessions', sessionId), {
      ownerUid: transactionTeacher, courseClassId: id, subject: 'PRM393', classCode: 'MOB',
      slot: 1, slotKey: '1', date: '2026-10-03', status: 'active', currentQrGeneration: 1, validitySeconds: 120,
    });
    await setDoc(doc(db, 'qrTokens', token), { ownerUid: transactionTeacher, sessionId,
      issuedAt: new Date(), validitySeconds: 120, qrGeneration: 1 });
    await setDoc(doc(db, 'attendanceCheckoutCodes', sessionId), { ownerUid: transactionTeacher, sessionId,
      issuedAt: new Date(), code: 'AB123', generation: 1, rotationSeconds: 3600 });
  });
  const db = testEnvironment.authenticatedContext(user, {
    email: 'CONCURRENT@example.com', firebase: { sign_in_provider: 'google.com' },
  }).firestore();
  const ref = doc(db, 'attendance', id, 'slots', '1', 'records', studentId);
  async function scan() {
    return runTransaction(db, async (tx) => {
      await tx.get(doc(db, 'qrTokens', token));
      await tx.get(doc(db, 'attendanceSessions', sessionId));
      const profile = (await tx.get(doc(db, 'courseClasses', id, 'students', studentId))).data();
      const existing = await tx.get(ref);
      if (existing.exists()) return existing.data().attendanceStatus;
      tx.set(ref, {
        ownerUid: transactionTeacher, firebaseUid: user, studentId, email: profile.email, emailNormalized: email,
        studentCode: profile.studentCode, fullName: profile.fullName, sessionId, courseClassId: id,
        subject: 'PRM393', classCode: 'MOB', slot: 1, slotKey: '1', date: '2026-10-03',
        qrToken: token, checkoutCode: 'AB123', checkedInAt: serverTimestamp(), createdAt: serverTimestamp(),
        updatedAt: serverTimestamp(), updatedBy: user, syncStatus: 'pending',
        attendanceStatus: 'present', recordSource: 'qr', revision: 1,
      });
      return 'present';
    });
  }
  await Promise.all([assertSucceeds(scan()), assertSucceeds(scan())]);
  const record = await assertSucceeds(getDoc(ref));
  if (record.data().revision !== 1 || record.data().attendanceStatus !== 'present') throw new Error('Duplicate scan altered record');
  await assertFails(updateDoc(ref, { attendanceStatus: 'excused' }));
  await assertFails(deleteDoc(ref));
  await testEnvironment.withSecurityRulesDisabled(async (context) => {
    await updateDoc(doc(context.firestore(), 'attendance', id, 'slots', '1', 'records', studentId), { attendanceStatus: 'absent' });
  });
  if (await assertSucceeds(scan()) !== 'absent') throw new Error('Teacher decision was overwritten');
});

// =============================================================================
// Test goc - giu nguyen
// =============================================================================

test('Google student can read only their own roster profile', async () => {
  const db = testEnvironment.authenticatedContext(studentUid, {
    email: 'student1@fpt.edu.vn',
    firebase: { sign_in_provider: 'google.com' },
  }).firestore();
  const students = collection(db, 'courseClasses', courseClassId, 'students');

  await assertSucceeds(getDoc(doc(students, 'student-hash-1')));
  await assertFails(getDoc(doc(students, 'student-hash-2')));
  await assertFails(getDocs(students));
});

test('only a roster member can submit leave and only the teacher can decide once', async () => {
  const leaveCourseId = 'LEAVE_TEST';
  const date = new Date(Date.now() + 7 * 86400000).toISOString().slice(0, 10);
  await testEnvironment.withSecurityRulesDisabled(async (context) => {
    const admin = context.firestore();
    await setDoc(doc(admin, 'courseClasses', leaveCourseId), {
      ownerUid: teacherUid, subject: 'PRM393', classCode: 'LEAVE',
      schedule: [{ number: 1, date, daySlot: 1 }],
    });
    await setDoc(doc(admin, 'courseClasses', leaveCourseId, 'students', 'student-hash-1'), {
      emailNormalized: 'student1@fpt.edu.vn', email: 'student1@fpt.edu.vn',
      studentCode: 'SE001', fullName: 'Student One', active: true,
      attendancePolicy: 'normal',
    });
  });
  const studentDb = testEnvironment.authenticatedContext(studentUid, {
    email: 'student1@fpt.edu.vn', firebase: { sign_in_provider: 'google.com' },
  }).firestore();
  const strangerDb = testEnvironment.authenticatedContext('other-student', {
    email: 'stranger@fpt.edu.vn', firebase: { sign_in_provider: 'google.com' },
  }).firestore();
  const teacherDb = testEnvironment.authenticatedContext(teacherUid).firestore();
  const course = doc(studentDb, 'courseClasses', leaveCourseId);
  await assertFails(getDoc(course));
  await assertSucceeds(getDoc(doc(studentDb, 'courseClasses', leaveCourseId, 'students', 'student-hash-1')));
  await assertSucceeds(setDoc(doc(studentDb, 'courseClasses', leaveCourseId, 'studentAccess', studentUid), {
    studentId: 'student-hash-1', emailNormalized: 'student1@fpt.edu.vn', createdAt: serverTimestamp(),
  }));
  await assertSucceeds(getDoc(course));
  await assertFails(setDoc(doc(strangerDb, 'courseClasses', leaveCourseId, 'studentAccess', 'other-student'), {
    studentId: 'student-hash-1', emailNormalized: 'stranger@fpt.edu.vn', createdAt: serverTimestamp(),
  }));
  const requestPath = ['courseClasses', leaveCourseId, 'leaveRequests', 'student-hash-1_1'];
  const request = doc(studentDb, ...requestPath);
  await assertFails(setDoc(request, {
    ownerUid: teacherUid, courseClassId: leaveCourseId, studentId: 'student-hash-1',
    firebaseUid: studentUid, emailNormalized: 'student1@fpt.edu.vn',
    slot: 1, date, slotDate: new Date(Date.parse(`${date}T00:00:00Z`) + 86400000),
    reason: 'Em xin nghỉ vì việc gia đình.', status: 'pending', createdAt: serverTimestamp(),
  }));
  await assertSucceeds(setDoc(request, {
    ownerUid: teacherUid, courseClassId: leaveCourseId, studentId: 'student-hash-1',
    firebaseUid: studentUid, emailNormalized: 'student1@fpt.edu.vn',
    slot: 1, date, slotDate: new Date(`${date}T00:00:00Z`),
    reason: 'Em xin nghỉ vì việc gia đình.', status: 'pending', createdAt: serverTimestamp(),
  }));
  await assertFails(setDoc(doc(studentDb, 'courseClasses', leaveCourseId, 'leaveRequests', 'forged-slot'), {
    ownerUid: teacherUid, courseClassId: leaveCourseId, studentId: 'student-hash-1',
    firebaseUid: studentUid, emailNormalized: 'student1@fpt.edu.vn',
    slot: 1, date, slotDate: new Date(`${date}T00:00:00Z`),
    reason: 'Em xin nghỉ vì việc gia đình.', status: 'pending', createdAt: serverTimestamp(),
  }));
  await assertFails(setDoc(doc(studentDb, 'courseClasses', leaveCourseId, 'leaveRequests', 'student-hash-1_2'), {
    ownerUid: teacherUid, courseClassId: leaveCourseId, studentId: 'student-hash-1',
    firebaseUid: studentUid, emailNormalized: 'student1@fpt.edu.vn',
    slot: 2, date, slotDate: new Date(`${date}T00:00:00Z`),
    reason: 'Em xin nghỉ vì việc gia đình.', status: 'pending', createdAt: serverTimestamp(),
  }));
  await assertFails(getDoc(doc(strangerDb, ...requestPath)));
  await assertFails(updateDoc(request, { status: 'approved' }));
  const teacherRequest = doc(teacherDb, ...requestPath);
  await assertFails(updateDoc(teacherRequest, {
    status: 'approved', response: 'Đã duyệt', decidedBy: teacherUid,
    decidedAt: serverTimestamp(),
  }));
  const decision = writeBatch(teacherDb);
  decision.update(teacherRequest, {
    status: 'approved', response: 'Đã duyệt', decidedBy: teacherUid,
    decidedAt: serverTimestamp(),
  });
  decision.set(doc(teacherRequest, 'audit', 'decision'), {
    from: 'pending', to: 'approved', response: 'Đã duyệt',
    actorUid: teacherUid, decidedAt: serverTimestamp(),
  });
  await assertSucceeds(decision.commit());
  await assertFails(updateDoc(teacherRequest, {
    status: 'rejected', response: 'Đổi ý', decidedBy: teacherUid,
    decidedAt: serverTimestamp(),
  }));
});

test('course owner can read and list roster, another teacher cannot', async () => {
  const ownerDb = testEnvironment.authenticatedContext(teacherUid).firestore();
  const otherDb = testEnvironment.authenticatedContext(otherTeacherUid).firestore();
  const ownerStudents = collection(ownerDb, 'courseClasses', courseClassId, 'students');
  const otherStudents = collection(otherDb, 'courseClasses', courseClassId, 'students');

  await assertSucceeds(getDoc(doc(ownerStudents, 'student-hash-1')));
  const roster = await assertSucceeds(getDocs(ownerStudents));
  if (roster.size !== 2) throw new Error(`Expected two students, got ${roster.size}.`);
  await assertFails(getDoc(doc(otherStudents, 'student-hash-1')));
  await assertFails(getDocs(otherStudents));
});

test('course instances are isolated by owner and academic term', async () => {
  async function createInstance(uid, term, id) {
    const db = testEnvironment.authenticatedContext(uid).firestore();
    const course = doc(db, 'courseClasses', id);
    const claim = doc(db, 'courseClassClaims', `${uid}_${term}_PRM393_SE01`);
    const batch = writeBatch(db);
    batch.set(course, {
      subject: 'PRM393', classCode: 'SE01', academicTerm: term,
      startDate: '2026-09-01', slotCount: 1, weekLabel: 'test',
      schedule: [], ownerUid: uid, createdAt: serverTimestamp(),
    });
    batch.set(claim, {
      ownerUid: uid, academicTerm: term, subject: 'PRM393',
      classCode: 'SE01', courseClassId: id, createdAt: serverTimestamp(),
    });
    await assertSucceeds(batch.commit());
    return { db, course, claim };
  }

  const first = await createInstance(teacherUid, '2026-FALL', 'instance-first');
  const second = await createInstance(otherTeacherUid, '2026-FALL', 'instance-other-owner');
  const third = await createInstance(teacherUid, '2027-SPRING', 'instance-next-term');
  await assertSucceeds(getDoc(first.course));
  await assertSucceeds(getDoc(second.course));
  await assertSucceeds(getDoc(third.course));
  await assertFails(getDoc(doc(second.db, 'courseClasses', 'instance-first')));
  await assertFails(setDoc(first.claim, { courseClassId: 'another-instance' }, { merge: true }));
  const duplicate = writeBatch(first.db);
  duplicate.set(doc(first.db, 'courseClasses', 'instance-duplicate'), {
    subject: 'PRM393', classCode: 'SE01', academicTerm: '2026-FALL',
    startDate: '2026-09-02', slotCount: 1, weekLabel: 'test',
    schedule: [], ownerUid: teacherUid, createdAt: serverTimestamp(),
  });
  duplicate.set(first.claim, {
    ownerUid: teacherUid, academicTerm: '2026-FALL', subject: 'PRM393',
    classCode: 'SE01', courseClassId: 'instance-duplicate', createdAt: serverTimestamp(),
  });
  await assertFails(duplicate.commit());
});

test('teacher can create a course with its claim and schedule lock in a transaction', async () => {
  const db = testEnvironment.authenticatedContext(teacherUid).firestore();
  const course = doc(db, 'courseClasses', 'transaction-course');
  const claim = doc(db, 'courseClassClaims', `${teacherUid}_2026-FALL_PRM393_SE99`);
  const lock = doc(db, 'teacherScheduleLocks', `${teacherUid}_2026-10-01_2`);

  await assertSucceeds(runTransaction(db, async (transaction) => {
    const claimSnapshot = await transaction.get(claim);
    const lockSnapshot = await transaction.get(lock);
    if (claimSnapshot.exists() || lockSnapshot.exists()) {
      throw new Error('Expected an unused course claim and schedule lock.');
    }
    transaction.set(course, {
      subject: 'PRM393', classCode: 'SE99', academicTerm: '2026-FALL',
      startDate: '2026-10-01', slotCount: 1, weekLabel: 1,
      slotDurationMinutes: 135,
      schedule: [{ number: 1, date: '2026-10-01', daySlot: 2 }],
      ownerUid: teacherUid, createdAt: serverTimestamp(),
    });
    transaction.set(claim, {
      ownerUid: teacherUid, academicTerm: '2026-FALL', subject: 'PRM393',
      classCode: 'SE99', courseClassId: course.id, createdAt: serverTimestamp(),
    });
    transaction.set(lock, {
      ownerUid: teacherUid, date: '2026-10-01', daySlot: 2,
      courseClassId: course.id, subject: 'PRM393', classCode: 'SE99',
      slotNumber: 1, createdAt: serverTimestamp(),
    });
  }));
});

test('course owner can list canonical records for a slot', async () => {
  const db = testEnvironment.authenticatedContext(teacherUid).firestore();
  const records = collection(
    db,
    'attendance',
    courseClassId,
    'slots',
    '1',
    'records',
  );

  const snapshot = await assertSucceeds(getDocs(records));
  if (snapshot.size !== 1) throw new Error(`Expected one record, got ${snapshot.size}.`);
});

test('student check-in accepts the current checkout code and rejects a wrong code', async () => {
  const sessionId = 'checkout-code-test-session';
  const qrToken = 'checkout-code-test-token';
  await testEnvironment.withSecurityRulesDisabled(async (context) => {
    const admin = context.firestore();
    await setDoc(doc(admin, 'attendanceSessions', sessionId), {
      ownerUid: teacherUid, courseClassId, subject: 'PRM393', classCode: 'DEMO',
      slot: 1, slotKey: '1', date: '2026-09-20', status: 'active',
      validitySeconds: 120, currentQrGeneration: 1,
    });
    await setDoc(doc(admin, 'qrTokens', qrToken), {
      ownerUid: teacherUid, sessionId, issuedAt: new Date(),
      validitySeconds: 120, qrGeneration: 1,
    });
    await setDoc(doc(admin, 'attendanceCheckoutCodes', sessionId), {
      ownerUid: teacherUid, sessionId, code: 'ABC23',
      rotationSeconds: 120, generation: 1, issuedAt: new Date(),
    });
  });

  const db = testEnvironment.authenticatedContext(studentUid, {
    email: 'student1@fpt.edu.vn',
    firebase: { sign_in_provider: 'google.com' },
  }).firestore();
  const record = doc(db, 'attendance', courseClassId, 'slots', '1', 'records', 'student-hash-1');
  const payload = {
    ownerUid: teacherUid, firebaseUid: studentUid, studentId: 'student-hash-1',
    email: 'student1@fpt.edu.vn', emailNormalized: 'student1@fpt.edu.vn',
    studentCode: 'SE001', fullName: 'Nguyen Van A', sessionId,
    courseClassId, subject: 'PRM393', classCode: 'DEMO',
    slot: 1, slotKey: '1', date: '2026-09-20', qrToken,
    checkedInAt: serverTimestamp(), createdAt: serverTimestamp(),
    updatedAt: serverTimestamp(), updatedBy: studentUid,
    syncStatus: 'pending', revision: 1, attendanceStatus: 'present',
    recordSource: 'qr',
  };
  await assertFails(setDoc(record, { ...payload, checkoutCode: 'WRONG' }));
  await assertSucceeds(setDoc(record, { ...payload, checkoutCode: 'ABC23' }));
  await testEnvironment.withSecurityRulesDisabled(async (context) => {
    await deleteDoc(doc(context.firestore(), 'attendance', courseClassId, 'slots', '1', 'records', 'student-hash-1'));
  });

  const teacherDb = testEnvironment.authenticatedContext(teacherUid).firestore();
  await assertSucceeds(updateDoc(doc(teacherDb, 'attendanceCheckoutCodes', sessionId), {
    code: 'DEF45', previousCode: 'ABC23', previousCodeGeneration: 1,
    generation: 2,
    issuedAt: serverTimestamp(),
  }));
  await assertSucceeds(setDoc(record, { ...payload, checkoutCode: 'ABC23' }));
  await testEnvironment.withSecurityRulesDisabled(async (context) => {
    const admin = context.firestore();
    await deleteDoc(doc(admin, 'attendance', courseClassId, 'slots', '1', 'records', 'student-hash-1'));
    await updateDoc(doc(admin, 'attendanceCheckoutCodes', sessionId), {
      issuedAt: new Date(Date.now() - 15_000),
    });
  });
  await assertFails(setDoc(record, { ...payload, checkoutCode: 'ABC23' }));

  // An already-running older desktop client can still rotate its code. Its
  // unchanged previousCode must not become valid again after that rotation.
  await assertSucceeds(updateDoc(doc(teacherDb, 'attendanceCheckoutCodes', sessionId), {
    code: 'GHI67', generation: 3, issuedAt: serverTimestamp(),
  }));
  await assertFails(setDoc(record, { ...payload, checkoutCode: 'ABC23' }));
  await assertSucceeds(setDoc(record, { ...payload, checkoutCode: 'GHI67' }));
  await testEnvironment.withSecurityRulesDisabled(async (context) => {
    await deleteDoc(doc(context.firestore(), 'attendance', courseClassId, 'slots', '1', 'records', 'student-hash-1'));
  });
});

test('teacher can query only their pending records across slots', async () => {
  const db = testEnvironment.authenticatedContext(teacherUid).firestore();
  const pending = query(
    collectionGroup(db, 'records'),
    where('ownerUid', '==', teacherUid),
    where('syncStatus', 'in', ['pending', 'error']),
  );

  const snapshot = await assertSucceeds(getDocs(pending));
  if (snapshot.size !== 1) throw new Error(`Expected one owned record, got ${snapshot.size}.`);
});

test('another teacher cannot list records in a course they do not own', async () => {
  const db = testEnvironment.authenticatedContext(otherTeacherUid).firestore();
  const records = collection(
    db,
    'attendance',
    courseClassId,
    'slots',
    '1',
    'records',
  );

  await assertFails(getDocs(records));
});

// =============================================================================
// Task 1.3 - records create deny tests
// =============================================================================

test('[records deny] payload co field du bi tu choi', async () => {
  const db = testEnvironment.authenticatedContext(studentUid, {
    email: 'student1@fpt.edu.vn',
    firebase: { sign_in_provider: 'google.com' },
  }).firestore();
  await assertFails(
    setDoc(
      doc(db, 'attendance', courseClassId, 'slots', '1', 'records', 'student-hash-1'),
      {
        ownerUid: teacherUid,
        firebaseUid: studentUid,
        studentId: 'student-hash-1',
        email: 'student1@fpt.edu.vn',
        emailNormalized: 'student1@fpt.edu.vn',
        studentCode: 'SE001',
        fullName: 'Nguyen Van A',
        sessionId: 'session-1',
        courseClassId,
        subject: 'PRM393',
        classCode: 'DEMO',
        slot: 1,
        slotKey: '1',
        date: '2026-09-20',
        qrToken: 'valid-token-gen5',
        checkedInAt: new Date(),
        createdAt: new Date(),
        updatedAt: new Date(),
        updatedBy: studentUid,
        syncStatus: 'pending',
        attendanceStatus: 'present',
        recordSource: 'qr',
        EXTRA_FIELD: 'should not be allowed',  // <-- field du
      },
    ),
  );
});

test('[records deny] attendanceStatus != present bi tu choi', async () => {
  const db = testEnvironment.authenticatedContext(studentUid, {
    email: 'student1@fpt.edu.vn',
    firebase: { sign_in_provider: 'google.com' },
  }).firestore();
  await assertFails(
    setDoc(
      doc(db, 'attendance', courseClassId, 'slots', '1', 'records', 'student-hash-1'),
      {
        ownerUid: teacherUid,
        firebaseUid: studentUid,
        studentId: 'student-hash-1',
        email: 'student1@fpt.edu.vn',
        emailNormalized: 'student1@fpt.edu.vn',
        studentCode: 'SE001',
        fullName: 'Nguyen Van A',
        sessionId: 'session-1',
        courseClassId,
        subject: 'PRM393',
        classCode: 'DEMO',
        slot: 1,
        slotKey: '1',
        date: '2026-09-20',
        qrToken: 'valid-token-gen5',
        checkedInAt: new Date(),
        createdAt: new Date(),
        updatedAt: new Date(),
        updatedBy: studentUid,
        syncStatus: 'pending',
        attendanceStatus: 'absent',  // <-- phai la 'present'
        recordSource: 'qr',
      },
    ),
  );
});

test('[records deny] recordSource != qr bi tu choi', async () => {
  const db = testEnvironment.authenticatedContext(studentUid, {
    email: 'student1@fpt.edu.vn',
    firebase: { sign_in_provider: 'google.com' },
  }).firestore();
  await assertFails(
    setDoc(
      doc(db, 'attendance', courseClassId, 'slots', '1', 'records', 'student-hash-1'),
      {
        ownerUid: teacherUid,
        firebaseUid: studentUid,
        studentId: 'student-hash-1',
        email: 'student1@fpt.edu.vn',
        emailNormalized: 'student1@fpt.edu.vn',
        studentCode: 'SE001',
        fullName: 'Nguyen Van A',
        sessionId: 'session-1',
        courseClassId,
        subject: 'PRM393',
        classCode: 'DEMO',
        slot: 1,
        slotKey: '1',
        date: '2026-09-20',
        qrToken: 'valid-token-gen5',
        checkedInAt: new Date(),
        createdAt: new Date(),
        updatedAt: new Date(),
        updatedBy: studentUid,
        syncStatus: 'pending',
        attendanceStatus: 'present',
        recordSource: 'teacher',  // <-- student khong duoc dung 'teacher'
      },
    ),
  );
});

// =============================================================================
// Task 1.3 - checkIns legacy create bi block
// =============================================================================

test('[checkIns deny] legacy create bi tu choi sau migration', async () => {
  const db = testEnvironment.authenticatedContext(studentUid, {
    email: 'student1@fpt.edu.vn',
    firebase: { sign_in_provider: 'google.com' },
  }).firestore();
  await assertFails(
    setDoc(
      doc(db, 'attendance', courseClassId, 'slots', '1', 'checkIns', studentUid),
      {
        ownerUid: teacherUid,
        firebaseUid: studentUid,
        studentId: 'student-hash-1',
        email: 'student1@fpt.edu.vn',
        emailNormalized: 'student1@fpt.edu.vn',
        studentCode: 'SE001',
        fullName: 'Nguyen Van A',
        sessionId: 'session-1',
        courseClassId,
        subject: 'PRM393',
        classCode: 'DEMO',
        slot: 1,
        slotKey: '1',
        date: '2026-09-20',
        qrToken: 'valid-token-gen5',
        checkedInAt: new Date(),
        createdAt: new Date(),
        syncStatus: 'pending',
      },
    ),
  );
});

// =============================================================================
// Task 1.1 - studentCodeClaims
// =============================================================================

test('[studentCodeClaims allow] owner co the tao claim', async () => {
  const db = testEnvironment.authenticatedContext(teacherUid).firestore();
  await assertSucceeds(
    setDoc(
      doc(db, 'courseClasses', courseClassId, 'studentCodeClaims', 'SE999'),
      {
        studentId: 'student-hash-999',
        ownerUid: teacherUid,
        createdAt: new Date(),
      },
    ),
  );
});

test('[studentCodeClaims deny] nguoi khac khong duoc tao claim', async () => {
  const db = testEnvironment.authenticatedContext(otherTeacherUid).firestore();
  await assertFails(
    setDoc(
      doc(db, 'courseClasses', courseClassId, 'studentCodeClaims', 'SE888'),
      {
        studentId: 'student-hash-888',
        ownerUid: otherTeacherUid,
        createdAt: new Date(),
      },
    ),
  );
});

// =============================================================================
// Task 1.2 - teacherScheduleLocks
// =============================================================================

test('[teacherScheduleLocks allow] owner co the tao lock', async () => {
  const db = testEnvironment.authenticatedContext(teacherUid).firestore();
  await assertSucceeds(
    setDoc(
      doc(db, 'teacherScheduleLocks', `${teacherUid}_2026-09-21_2`),
      {
        ownerUid: teacherUid,
        date: '2026-09-21',
        daySlot: 2,
        courseClassId,
        subject: 'PRM393',
        classCode: 'DEMO',
        slotNumber: 2,
        createdAt: new Date(),
      },
    ),
  );
});

test('[teacherScheduleLocks deny] nguoi khac khong duoc tao lock voi ownerUid sai', async () => {
  const db = testEnvironment.authenticatedContext(otherTeacherUid).firestore();
  await assertFails(
    setDoc(
      // Co gang tao lock voi ownerUid la teacherUid (nguoi khac)
      doc(db, 'teacherScheduleLocks', `${teacherUid}_2026-09-22_3`),
      {
        ownerUid: teacherUid,  // <-- ownerUid khong khop voi auth.uid
        date: '2026-09-22',
        daySlot: 3,
        courseClassId: 'OTHER_CLASS',
        subject: 'PRM393',
        classCode: 'OTHER',
        slotNumber: 3,
        createdAt: new Date(),
      },
    ),
  );
});

test('[teacherScheduleLocks deny] update lock bi tu choi', async () => {
  const db = testEnvironment.authenticatedContext(teacherUid).firestore();
  await assertFails(
    setDoc(
      doc(db, 'teacherScheduleLocks', `${teacherUid}_2026-09-20_1`),
      { ownerUid: teacherUid, date: '2026-09-20', daySlot: 1, courseClassId, subject: 'PRM393', classCode: 'DEMO', slotNumber: 1 },
      { merge: true },
    ),
  );
});

test('an old student code can be reclaimed without allowing two owners', async () => {
  const db = testEnvironment.authenticatedContext(teacherUid).firestore();
  const students = collection(db, 'courseClasses', courseClassId, 'students');
  const claims = collection(db, 'courseClasses', courseClassId, 'studentCodeClaims');
  const first = doc(students, 'student-import-x');
  const second = doc(students, 'student-import-y');
  const oldClaim = doc(claims, 'SE70A');
  await assertSucceeds(setDoc(first, {
    email: 'x@fpt.edu.vn', emailNormalized: 'x@fpt.edu.vn',
    studentCode: 'SE70A', studentCodeNormalized: 'SE70A', fullName: 'X',
    active: true, attendancePolicy: 'normal', importedBy: teacherUid,
  }));
  await assertSucceeds(setDoc(oldClaim, { studentId: first.id, ownerUid: teacherUid }));

  const change = writeBatch(db);
  change.update(first, { studentCode: 'SE70B', studentCodeNormalized: 'SE70B' });
  change.delete(oldClaim);
  change.set(doc(claims, 'SE70B'), { studentId: first.id, ownerUid: teacherUid });
  await assertSucceeds(change.commit());

  const reuse = writeBatch(db);
  reuse.set(second, {
    email: 'y@fpt.edu.vn', emailNormalized: 'y@fpt.edu.vn',
    studentCode: 'SE70A', studentCodeNormalized: 'SE70A', fullName: 'Y',
    active: true, attendancePolicy: 'normal', importedBy: teacherUid,
  });
  reuse.set(oldClaim, { studentId: second.id, ownerUid: teacherUid });
  await assertSucceeds(reuse.commit());
  await assertFails(setDoc(oldClaim, { studentId: first.id, ownerUid: teacherUid }));

  const concurrentClaim = doc(claims, 'SE70C');
  const attempts = await Promise.allSettled([
    setDoc(concurrentClaim, { studentId: first.id, ownerUid: teacherUid }),
    setDoc(concurrentClaim, { studentId: second.id, ownerUid: teacherUid }),
  ]);
  if (attempts.filter((result) => result.status === 'fulfilled').length !== 1) {
    throw new Error('Exactly one concurrent claim must succeed.');
  }
});

test('teacher edits advance revision while sync metadata preserves it', async () => {
  const db = testEnvironment.authenticatedContext(teacherUid).firestore();
  const record = doc(db, 'attendance', courseClassId, 'slots', '1', 'records', 'student-hash-2');
  await assertSucceeds(setDoc(record, {
    ownerUid: teacherUid,
    studentId: 'student-hash-2',
    courseClassId,
    slotKey: '1',
    attendanceStatus: 'present',
    recordSource: 'teacher',
    syncStatus: 'pending',
    revision: 1,
  }));
  await assertFails(setDoc(record, {
    attendanceStatus: 'absent',
    syncStatus: 'pending',
  }, { merge: true }));
  await assertSucceeds(setDoc(record, {
    attendanceStatus: 'absent',
    syncStatus: 'pending',
    revision: 2,
  }, { merge: true }));
  await assertSucceeds(setDoc(record, {
    syncStatus: 'synced',
  }, { merge: true }));
  await assertSucceeds(setDoc(record, {
    syncStatus: 'error',
    syncAttempts: 1,
    nextSyncAttemptAt: futureTime,
  }, { merge: true }));
  await assertSucceeds(setDoc(record, {
    syncStatus: 'synced',
    syncAttempts: 0,
    nextSyncAttemptAt: null,
  }, { merge: true }));
  const snapshot = await getDoc(record);
  if (snapshot.data()?.revision !== 2) throw new Error('Sync changed the record revision.');
});

test('an existing unversioned record can migrate to revision zero', async () => {
  const db = testEnvironment.authenticatedContext(teacherUid).firestore();
  const record = doc(db, 'attendance', courseClassId, 'slots', '1', 'records', 'student-1');
  await assertSucceeds(setDoc(record, {
    revision: 0,
    syncStatus: 'synced',
  }, { merge: true }));
  await assertSucceeds(setDoc(record, {
    revision: 1,
    attendanceStatus: 'absent',
    syncStatus: 'pending',
  }, { merge: true }));
});

test('a rejected import batch does not deactivate the current roster', async () => {
  const db = testEnvironment.authenticatedContext(teacherUid).firestore();
  const student = doc(db, 'courseClasses', courseClassId, 'students', 'student-hash-1');
  const claim = doc(db, 'courseClasses', courseClassId, 'studentCodeClaims', 'SE001');
  await assertSucceeds(updateDoc(student, { active: true, importedBy: teacherUid }));
  const batch = writeBatch(db);
  batch.update(student, { active: false });
  batch.set(claim, { studentId: 'student-hash-2', ownerUid: teacherUid }, { merge: true });

  await assertFails(batch.commit());
  const current = await getDoc(student);
  if (current.data()?.active !== true) throw new Error('Failed import deactivated roster.');
});
