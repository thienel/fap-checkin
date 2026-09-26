import { readFileSync } from 'node:fs';
import { after, before, test } from 'node:test';

import {
  assertFails,
  assertSucceeds,
  initializeTestEnvironment,
} from '@firebase/rules-unit-testing';
import {
  collection,
  collectionGroup,
  doc,
  getDoc,
  getDocs,
  query,
  setDoc,
  where,
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
