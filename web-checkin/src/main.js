import { initializeApp } from 'firebase/app';
import {
  doc,
  getDoc,
  getFirestore,
  runTransaction,
  serverTimestamp,
} from 'firebase/firestore';
import './style.css';

const firebaseConfig = {
  apiKey:            import.meta.env.VITE_FIREBASE_API_KEY,
  authDomain:        import.meta.env.VITE_FIREBASE_AUTH_DOMAIN,
  projectId:         import.meta.env.VITE_FIREBASE_PROJECT_ID,
  storageBucket:     import.meta.env.VITE_FIREBASE_STORAGE_BUCKET,
  messagingSenderId: import.meta.env.VITE_FIREBASE_MESSAGING_SENDER_ID,
  appId:             import.meta.env.VITE_FIREBASE_APP_ID,
};

// ─── DOM Elements ────────────────────────────────────────────
const stepLoading       = document.querySelector('#step-loading');
const stepStudentForm   = document.querySelector('#step-student-form');
const stepDoneSuccess   = document.querySelector('#step-done-success');
const stepDoneDuplicate = document.querySelector('#step-done-duplicate');
const stepDoneExpired   = document.querySelector('#step-done-expired');

const sessionInfoTextEl = document.querySelector('#session-info-text');

// Form elements
const checkinForm      = document.querySelector('#checkin-form');
const studentCodeInput = document.querySelector('#student-code');
const fullNameInput    = document.querySelector('#full-name');
const studentEmailInput = document.querySelector('#student-email');
const secretKeyInput   = document.querySelector('#secret-key');
const notesInput       = document.querySelector('#notes');
const btnSubmitCheckin = document.querySelector('#btn-submit-checkin');
const formErrorBanner  = document.querySelector('#form-error-banner');

const studentCodeError  = document.querySelector('#student-code-error');
const fullNameError     = document.querySelector('#full-name-error');
const studentEmailError = document.querySelector('#student-email-error');
const secretKeyError    = document.querySelector('#secret-key-error');

// Result elements
const resStudentCode  = document.querySelector('#res-student-code');
const resStudentName  = document.querySelector('#res-student-name');
const resClassSubject = document.querySelector('#res-class-subject');
const resTime         = document.querySelector('#res-time');

const dupStudentCode  = document.querySelector('#dup-student-code');
const dupStudentName  = document.querySelector('#dup-student-name');
const dupClassSubject = document.querySelector('#dup-class-subject');

const expiredDescEl   = document.querySelector('#expired-desc');
const btnCloseSuccess = document.querySelector('#btn-close-success');
const btnCloseDup     = document.querySelector('#btn-close-duplicate');
const btnRetryQr      = document.querySelector('#btn-retry-qr');

// ─── State ───────────────────────────────────────────────────
const params   = new URLSearchParams(window.location.search);
const urlToken = params.get('t');
if (urlToken) sessionStorage.setItem('attendanceQrToken', urlToken);
const token = urlToken || sessionStorage.getItem('attendanceQrToken');

let db;
let currentSession = null;
let submitStarted  = false;

// ─── Step Management ─────────────────────────────────────────
function showStep(targetStep) {
  [
    stepLoading,
    stepStudentForm,
    stepDoneSuccess,
    stepDoneDuplicate,
    stepDoneExpired,
  ].forEach((s) => {
    if (s) s.classList.add('hidden');
  });
  if (targetStep) targetStep.classList.remove('hidden');
}

// ─── SHA-256 email → student ID ──────────────────────────────
async function studentIdForEmail(email) {
  const bytes  = new TextEncoder().encode(email.trim().toLowerCase());
  const digest = await crypto.subtle.digest('SHA-256', bytes);
  return Array.from(new Uint8Array(digest), (b) => b.toString(16).padStart(2, '0')).join('');
}

// ─── Readable errors ─────────────────────────────────────────
function readableError(error, userEmail = '') {
  const msg  = error?.message || String(error || '');
  const code = String(error?.code || '');
  if (msg.includes('student-not-in-roster'))
    return `Email (${userEmail}) chưa có trong danh sách điểm danh lớp này. Liên hệ giảng viên.`;
  if (msg.includes('student-inactive'))
    return `Tài khoản sinh viên (${userEmail}) đang tạm khóa trong lớp.`;
  if (msg.includes('student-email-mismatch'))
    return `Email (${userEmail}) không khớp thông tin đăng ký.`;
  if (msg.includes('student-code-mismatch'))
    return 'Mã số sinh viên (MSSV) nhập chưa chính xác với hồ sơ.';
  if (msg.includes('qr-not-found'))
    return 'Mã QR không hợp lệ hoặc đã hết hạn. Vui lòng quét lại mã QR mới trên TV/Máy chiếu.';
  if (msg.includes('session-not-found'))
    return 'Phiên điểm danh không tồn tại hoặc đã kết thúc.';
  if (msg.includes('session-stopped'))
    return 'Giảng viên đã kết thúc phiên điểm danh này.';
  if (msg.includes('checkout-key-invalid'))
    return 'Secret Key (Mã điểm danh) không chính xác. Vui lòng nhìn màn hình giảng viên và nhập lại.';
  if (code.includes('permission-denied'))
    return 'Thông tin MSSV hoặc Secret Key không khớp với phiên điểm danh. Vui lòng kiểm tra lại.';
  return error?.message || 'Có lỗi xảy ra khi điểm danh. Vui lòng thử lại.';
}

// ─── Form validation ─────────────────────────────────────────
function validateForm() {
  let valid = true;

  const code = studentCodeInput.value.trim();
  if (!code) {
    studentCodeError.classList.remove('hidden');
    studentCodeInput.classList.add('field-input--invalid');
    valid = false;
  } else {
    studentCodeError.classList.add('hidden');
    studentCodeInput.classList.remove('field-input--invalid');
  }

  const name = fullNameInput.value.trim();
  if (!name) {
    fullNameError.classList.remove('hidden');
    fullNameInput.classList.add('field-input--invalid');
    valid = false;
  } else {
    fullNameError.classList.add('hidden');
    fullNameInput.classList.remove('field-input--invalid');
  }

  const email = studentEmailInput.value.trim();
  const emailOk = email && /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email);
  if (!emailOk) {
    studentEmailError.classList.remove('hidden');
    studentEmailInput.classList.add('field-input--invalid');
    valid = false;
  } else {
    studentEmailError.classList.add('hidden');
    studentEmailInput.classList.remove('field-input--invalid');
  }

  const key = secretKeyInput.value.trim();
  if (key.length < 4) {
    secretKeyError.classList.remove('hidden');
    secretKeyInput.classList.add('field-input--invalid');
    valid = false;
  } else {
    secretKeyError.classList.add('hidden');
    secretKeyInput.classList.remove('field-input--invalid');
  }

  return valid;
}

// ─── Submit Check-In ─────────────────────────────────────────
async function submitCheckIn(studentCode, fullName, emailRaw, secretKey, notes) {
  if (submitStarted || !token || !currentSession) return;
  submitStarted = true;

  btnSubmitCheckin.disabled  = true;
  btnSubmitCheckin.textContent = 'Đang xác nhận...';
  formErrorBanner.classList.add('hidden');

  try {
    const emailNormalized = emailRaw.trim().toLowerCase();
    const studentId       = await studentIdForEmail(emailNormalized);
    const scodeNorm       = studentCode.trim().toUpperCase();
    const keyNorm         = secretKey.trim().toUpperCase();

    // Re-verify session
    const sessionRef  = doc(db, 'attendanceSessions', currentSession.id);
    const sessionSnap = await getDoc(sessionRef);
    if (!sessionSnap.exists()) throw new Error('session-not-found');
    const session = sessionSnap.data();
    if (session.status !== 'active') throw new Error('session-stopped');

    // Secret Key check
    const currentKey  = (session.checkoutKey || '').toUpperCase();
    const previousKey = (session.previousCheckoutKey || '').toUpperCase();
    if (keyNorm !== currentKey && keyNorm !== previousKey) {
      throw new Error('checkout-key-invalid');
    }

    // Student in roster
    const studentRef  = doc(db, 'courseClasses', session.courseClassId, 'students', studentId);
    const studentSnap = await getDoc(studentRef);
    if (!studentSnap.exists()) throw new Error('student-not-in-roster');
    const student = studentSnap.data();
    if (student.emailNormalized !== emailNormalized) throw new Error('student-email-mismatch');
    if (student.active !== true) throw new Error('student-inactive');

    if (student.studentCode && student.studentCode.toUpperCase() !== scodeNorm) {
      throw new Error('student-code-mismatch');
    }

    // Atomic write
    const result = await runTransaction(db, async (tx) => {
      const ref = doc(
        db, 'attendance', session.courseClassId,
        'slots', session.slotKey, 'records', studentId,
      );
      const existing = await tx.get(ref);
      if (existing.exists()) {
        return {
          status: 'duplicate',
          email: emailNormalized,
          attendanceStatus: existing.data().attendanceStatus,
        };
      }
      tx.set(ref, {
        ownerUid:         session.ownerUid,
        firebaseUid:      studentId,
        studentId,
        email:            emailNormalized,
        emailNormalized,
        studentCode:      scodeNorm,
        fullName:         fullName.trim() || student.fullName,
        selfReportedName: fullName.trim(),
        notes:            notes.trim(),
        sessionId:        sessionSnap.id,
        courseClassId:    session.courseClassId,
        subject:          session.subject,
        classCode:        session.classCode,
        slot:             session.slot,
        slotKey:          session.slotKey,
        date:             session.date,
        qrToken:          token,
        checkedInAt:      serverTimestamp(),
        createdAt:        serverTimestamp(),
        syncStatus:       'pending',
        attendanceStatus: 'present',
        recordSource:     'qr',
        checkoutKey:      keyNorm,
        updatedAt:        serverTimestamp(),
        updatedBy:        studentId,
      });
      return { status: 'valid', email: emailNormalized };
    });

    sessionStorage.removeItem('attendanceQrToken');
    const nowTimeStr = new Date().toLocaleTimeString('vi-VN', { hour: '2-digit', minute: '2-digit' }) +
                       ' - ' + new Date().toLocaleDateString('vi-VN');

    if (result.status === 'duplicate') {
      dupStudentCode.textContent  = scodeNorm;
      dupStudentName.textContent  = fullName.trim() || student.fullName;
      dupClassSubject.textContent = `${session.classCode} · ${session.subject}`;
      showStep(stepDoneDuplicate);
    } else {
      resStudentCode.textContent  = scodeNorm;
      resStudentName.textContent  = fullName.trim() || student.fullName;
      resClassSubject.textContent = `${session.classCode} · ${session.subject}`;
      resTime.textContent         = nowTimeStr;
      showStep(stepDoneSuccess);
    }
  } catch (error) {
    console.error(error);
    submitStarted = false;
    btnSubmitCheckin.disabled  = false;
    btnSubmitCheckin.textContent = 'Xác nhận điểm danh';
    formErrorBanner.textContent = readableError(error, emailRaw);
    formErrorBanner.classList.remove('hidden');
  }
}

// ─── Bootstrap ───────────────────────────────────────────────
async function bootstrap() {
  showStep(stepLoading);

  if (!token) {
    if (expiredDescEl) {
      expiredDescEl.textContent = 'Thiếu mã QR điểm danh. Hãy quét mã QR trên màn hình giảng viên để tiếp tục.';
    }
    showStep(stepDoneExpired);
    return;
  }

  if (!firebaseConfig.apiKey || !firebaseConfig.projectId) {
    if (expiredDescEl) {
      expiredDescEl.textContent = 'Hệ thống chưa được cấu hình biến môi trường Firebase.';
    }
    showStep(stepDoneExpired);
    return;
  }

  const app = initializeApp(firebaseConfig);
  db = getFirestore(app);

  // Fetch QR Token & Session
  try {
    const tokenRef  = doc(db, 'qrTokens', token);
    const tokenSnap = await getDoc(tokenRef);
    if (!tokenSnap.exists()) {
      showStep(stepDoneExpired);
      return;
    }
    const tokenData = tokenSnap.data();

    const sessionRef  = doc(db, 'attendanceSessions', tokenData.sessionId);
    const sessionSnap = await getDoc(sessionRef);
    if (!sessionSnap.exists() || sessionSnap.data().status !== 'active') {
      showStep(stepDoneExpired);
      return;
    }

    currentSession = { id: sessionSnap.id, ...sessionSnap.data() };

    if (sessionInfoTextEl) {
      sessionInfoTextEl.textContent = `Lớp ${currentSession.classCode} · Môn ${currentSession.subject}`;
    }

    // Direct to Form
    showStep(stepStudentForm);
  } catch (err) {
    console.error('Error fetching session:', err);
    showStep(stepDoneExpired);
  }

  // Form Submit Listener
  checkinForm.addEventListener('submit', (e) => {
    e.preventDefault();
    if (!validateForm()) return;
    submitCheckIn(
      studentCodeInput.value.trim(),
      fullNameInput.value.trim(),
      studentEmailInput.value.trim(),
      secretKeyInput.value.trim(),
      notesInput.value.trim(),
    );
  });

  [studentCodeInput, fullNameInput, studentEmailInput, secretKeyInput].forEach((inp) => {
    inp.addEventListener('input', () => {
      inp.classList.remove('field-input--invalid');
      formErrorBanner.classList.add('hidden');
    });
  });

  [btnCloseSuccess, btnCloseDup].forEach((btn) => {
    btn?.addEventListener('click', () => {
      window.close();
    });
  });

  btnRetryQr?.addEventListener('click', () => {
    window.location.reload();
  });
}

bootstrap().catch((err) => {
  console.error(err);
  showStep(stepDoneExpired);
});
