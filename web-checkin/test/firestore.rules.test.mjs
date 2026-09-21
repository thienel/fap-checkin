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
  getDocs,
  query,
  setDoc,
  where,
} from 'firebase/firestore';

const projectId = 'demo-fap-checkin-rules';
const teacherUid = 'teacher-1';
const otherTeacherUid = 'teacher-2';
const courseClassId = 'TEST_DEMO_20260920';
let testEnvironment;

before(async () => {
  testEnvironment = await initializeTestEnvironment({
    projectId,
    firestore: {
      rules: readFileSync(new URL('../../firestore.rules', import.meta.url), 'utf8'),
    },
  });

  await testEnvironment.withSecurityRulesDisabled(async (context) => {
    const db = context.firestore();
    await setDoc(doc(db, 'teachers', teacherUid), { active: true });
    await setDoc(doc(db, 'teachers', otherTeacherUid), { active: true });
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
  });
});

after(async () => {
  await testEnvironment?.cleanup();
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
