import { initializeApp } from 'firebase/app';
import {
  browserSessionPersistence,
  getAuth,
  GoogleAuthProvider,
  onAuthStateChanged,
  setPersistence,
  signInWithRedirect,
  signOut,
} from 'firebase/auth';
import {
  doc,
  getFirestore,
  runTransaction,
  serverTimestamp,
} from 'firebase/firestore';
import './style.css';

const firebaseConfig = {
  apiKey: import.meta.env.VITE_FIREBASE_API_KEY,
  authDomain: import.meta.env.VITE_FIREBASE_AUTH_DOMAIN,
  projectId: import.meta.env.VITE_FIREBASE_PROJECT_ID,
  storageBucket: import.meta.env.VITE_FIREBASE_STORAGE_BUCKET,
  messagingSenderId: import.meta.env.VITE_FIREBASE_MESSAGING_SENDER_ID,
  appId: import.meta.env.VITE_FIREBASE_APP_ID,
};

const title = document.querySelector('#title');
const message = document.querySelector('#message');
const status = document.querySelector('#status');
const signInButton = document.querySelector('#sign-in');
const checkoutForm = document.querySelector('#checkout-form');
const checkoutCodeInput = document.querySelector('#checkout-code');
const checkoutSubmitButton = document.querySelector('#checkout-submit');
const params = new URLSearchParams(window.location.search);
const urlToken = params.get('t');
if (urlToken) sessionStorage.setItem('attendanceQrToken', urlToken);
const token = urlToken || sessionStorage.getItem('attendanceQrToken');

let auth;
let db;
let submitStarted = false;

function showStatus(kind, heading, detail, { allowCheckout = false, allowSignIn = false } = {}) {
  title.textContent = heading;
  message.textContent = detail;
  status.className = `status ${kind}`;
  status.textContent = kind === 'success' ? '✓' : kind === 'error' ? '!' : '…';
  signInButton.classList.toggle('hidden', !allowSignIn);
  checkoutForm.classList.toggle('hidden', !allowCheckout);
}

function promptCheckoutCode(user) {
  title.textContent = 'Nhập checkout code';
  message.textContent = `Đã đăng nhập bằng ${user.email ?? 'tài khoản Google'}. Nhập code giảng viên cung cấp để xác nhận điểm danh.`;
  status.className = 'status hidden';
  status.textContent = '';
  signInButton.classList.add('hidden');
  checkoutForm.classList.remove('hidden');
  checkoutCodeInput.focus();
}

function readableError(error, userEmail = '') {
  const msg = error?.message || String(error || '');
  if (msg === 'student-not-in-roster' || msg.includes('student-not-in-roster')) {
    return `Email (${userEmail || 'Google'}) không thuộc danh sách sinh viên của lớp này. Vui lòng liên hệ giảng viên để kiểm tra và thêm bạn vào danh sách lớp.`;
  }
  if (msg === 'student-inactive' || msg.includes('student-inactive')) {
    return `Tài khoản sinh viên (${userEmail || ''}) đã bị tạm khóa trong danh sách lớp này. Vui lòng liên hệ giảng viên.`;
  }
  if (msg === 'student-email-mismatch' || msg.includes('student-email-mismatch')) {
    return `Email Google (${userEmail || ''}) không khớp với email đã đăng ký trong danh sách lớp.`;
  }
  if (msg === 'qr-not-found' || msg.includes('qr-not-found')) {
    return 'Mã QR không hợp lệ hoặc đã bị vô hiệu hóa. Vui lòng quét mã QR mới.';
  }
  if (msg === 'session-not-found' || msg.includes('session-not-found')) {
    return 'Phiên điểm danh không tồn tại hoặc đã kết thúc.';
  }
  if (msg === 'session-stopped' || msg.includes('session-stopped')) {
    return 'Giảng viên đã kết thúc phiên điểm danh này.';
  }
  if (msg === 'google-account-has-no-email' || msg.includes('google-account-has-no-email')) {
    return 'Tài khoản Google của bạn không cung cấp địa chỉ email.';
  }
  if (msg.includes('checkout-code-invalid')) {
    return 'Checkout code chưa đúng. Hãy kiểm tra lại với giảng viên rồi thử lại.';
  }
  if (msg.includes('checkout-code-expired')) {
    return 'Checkout code vừa hết hạn. Hãy lấy mã mới nhất trên màn hình giảng viên.';
  }
  if (msg.includes('qr-expired')) {
    return 'QR đã hết hạn. Hãy quét lại mã mới nhất trên màn hình giảng viên.';
  }
  if (msg.includes('student-email-mismatch')) {
    return `Email Google (${userEmail || ''}) không khớp với email đã đăng ký trong danh sách lớp.`;
  }

  const code = String(error?.code || '');
  if (code.includes('not-found')) return 'Mã QR không hợp lệ hoặc đã hết hạn.';
  if (code.includes('permission-denied')) {
    return 'Tài khoản của bạn chưa đủ điều kiện điểm danh. Hãy kiểm tra email đăng nhập hoặc liên hệ giảng viên.';
  }
  return error?.message || 'Không thể hoàn tất điểm danh. Vui lòng quét lại mã QR.';
}

async function submitCheckIn(user, code) {
  if (submitStarted || !token) return;
  submitStarted = true;
  checkoutSubmitButton.disabled = true;
  showStatus('loading', 'Đang xác nhận…', 'Đang kiểm tra checkout code và ghi nhận điểm danh.');

  try {
    if (!user.email) throw new Error('google-account-has-no-email');
    const result = await writeCheckIn(user, code);

    sessionStorage.removeItem('attendanceQrToken');
    if (result.status === 'duplicate') {
      const detail = result.attendanceStatus === 'excused'
        ? `${result.email} đang được ghi nhận có phép cho slot này.`
        : `${result.email} đã được ghi nhận trước đó cho slot này.`;
      showStatus('success', 'Đã có trạng thái điểm danh', detail);
    } else {
      showStatus('success', 'Điểm danh thành công', `${result.email} đã được ghi nhận.`);
    }
    await signOut(auth);
  } catch (error) {
    console.error(error);
    const errorMessage = String(error?.message || error);
    if (errorMessage.includes('checkout-code-invalid')
      || errorMessage.includes('checkout-code-expired')) {
      submitStarted = false;
      checkoutCodeInput.value = '';
      showStatus(
        'error',
        errorMessage.includes('checkout-code-expired')
          ? 'Checkout code đã đổi'
          : 'Checkout code chưa đúng',
        readableError(error, user?.email),
        {
          allowCheckout: true,
        },
      );
      checkoutCodeInput.focus();
      return;
    }
    if (errorMessage.includes('qr-expired')) {
      sessionStorage.removeItem('attendanceQrToken');
      showStatus('error', 'QR đã hết hạn', readableError(error, user?.email));
      await signOut(auth).catch(() => undefined);
      return;
    }
    showStatus('error', 'Không thể điểm danh', readableError(error, user?.email), {
      allowSignIn: true,
    });
    await signOut(auth).catch(() => undefined);
  } finally {
    checkoutSubmitButton.disabled = false;
  }
}

async function studentDocumentId(email) {
  const normalizedEmail = email.trim().toLowerCase();
  const digest = await crypto.subtle.digest(
    'SHA-256',
    new TextEncoder().encode(normalizedEmail),
  );
  return Array.from(new Uint8Array(digest), (byte) =>
    byte.toString(16).padStart(2, '0'),
  ).join('');
}

async function writeCheckIn(user, checkoutCode) {
  const email = user.email.trim().toLowerCase();
  const normalizedCode = checkoutCode.trim().toUpperCase();
  if (!/^[A-Z0-9]{5}$/.test(normalizedCode)) {
    throw new Error('checkout-code-invalid');
  }

  const studentId = await studentDocumentId(email);
  let validationStage = 'qr';
  try {
    return await runTransaction(db, async (transaction) => {
      const qrReference = doc(db, 'qrTokens', token);
      const qrSnapshot = await transaction.get(qrReference);
      if (!qrSnapshot.exists()) throw new Error('qr-not-found');
      const qr = qrSnapshot.data();
      if (typeof qr.sessionId !== 'string') throw new Error('qr-not-found');

      validationStage = 'session';
      const sessionReference = doc(db, 'attendanceSessions', qr.sessionId);
      const sessionSnapshot = await transaction.get(sessionReference);
      if (!sessionSnapshot.exists()) throw new Error('session-not-found');
      const session = sessionSnapshot.data();
      if (session.status !== 'active') throw new Error('session-stopped');

      validationStage = 'roster';
      const studentReference = doc(
        db,
        'courseClasses',
        session.courseClassId,
        'students',
        studentId,
      );
      const studentSnapshot = await transaction.get(studentReference);
      if (!studentSnapshot.exists()) throw new Error('student-not-in-roster');
      const student = studentSnapshot.data();
      if (student.emailNormalized !== email) {
        throw new Error('student-email-mismatch');
      }
      if (student.active !== true) throw new Error('student-inactive');

      validationStage = 'record';
      const recordReference = doc(
        db,
        'attendance',
        session.courseClassId,
        'slots',
        String(session.slotKey),
        'records',
        studentId,
      );
      const recordSnapshot = await transaction.get(recordReference);
      if (recordSnapshot.exists()) {
        return {
          status: 'duplicate',
          email,
          attendanceStatus: recordSnapshot.data().attendanceStatus ?? 'present',
        };
      }

      validationStage = 'checkout';
      const now = serverTimestamp();
      transaction.set(recordReference, {
        ownerUid: session.ownerUid,
        firebaseUid: user.uid,
        studentId,
        email: student.email,
        emailNormalized: email,
        studentCode: student.studentCode,
        fullName: student.fullName,
        sessionId: qr.sessionId,
        courseClassId: session.courseClassId,
        subject: session.subject,
        classCode: session.classCode,
        slot: session.slot,
        slotKey: String(session.slotKey),
        date: session.date,
        qrToken: token,
        checkoutCode: normalizedCode,
        checkedInAt: now,
        createdAt: now,
        updatedAt: now,
        updatedBy: user.uid,
        syncStatus: 'pending',
        revision: 1,
        attendanceStatus: 'present',
        recordSource: 'qr',
      });
      return { status: 'valid', email };
    });
  } catch (error) {
    if (error?.code === 'permission-denied') {
      if (validationStage === 'qr') throw new Error('qr-expired');
      if (validationStage === 'session') throw new Error('session-stopped');
      if (validationStage === 'roster') throw new Error('student-not-in-roster');
      if (validationStage === 'checkout') throw new Error('checkout-code-invalid');
    }
    throw error;
  }
}

async function bootstrap() {
  if (!token) {
    showStatus('error', 'Thiếu mã QR', 'Hãy quét mã QR đang hiển thị trên màn hình giảng viên.');
    return;
  }

  if (!firebaseConfig.apiKey || !firebaseConfig.projectId) {
    showStatus('error', 'Chưa cấu hình hệ thống', 'Firebase Hosting đang thiếu biến môi trường.');
    return;
  }

  const app = initializeApp(firebaseConfig);
  auth = getAuth(app);
  db = getFirestore(app);
  await setPersistence(auth, browserSessionPersistence);

  onAuthStateChanged(auth, (user) => {
    if (user) promptCheckoutCode(user);
  });

  checkoutForm.addEventListener('submit', async (event) => {
    event.preventDefault();
    const user = auth.currentUser;
    if (user) await submitCheckIn(user, checkoutCodeInput.value);
  });

  signInButton.addEventListener('click', async () => {
    signInButton.disabled = true;
    signInButton.textContent = 'Đang mở Google…';
    try {
      const provider = new GoogleAuthProvider();
      provider.setCustomParameters({ prompt: 'select_account' });
      await signInWithRedirect(auth, provider);
    } catch (error) {
      console.error(error);
      signInButton.disabled = false;
      signInButton.textContent = 'Tiếp tục với Google';
      showStatus('error', 'Không mở được đăng nhập', 'Vui lòng thử đăng nhập lại.', {
        allowSignIn: true,
      });
    }
  });
}

bootstrap().catch((error) => {
  console.error(error);
  showStatus('error', 'Lỗi khởi tạo', 'Không thể kết nối tới hệ thống điểm danh.');
});
