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
import { getFunctions, httpsCallable } from 'firebase/functions';
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
const params = new URLSearchParams(window.location.search);
const urlToken = params.get('t');
if (urlToken) sessionStorage.setItem('attendanceQrToken', urlToken);
const token = urlToken || sessionStorage.getItem('attendanceQrToken');

let auth;
let functions;
let submitStarted = false;

function showStatus(kind, heading, detail) {
  title.textContent = heading;
  message.textContent = detail;
  status.className = `status ${kind}`;
  status.textContent = kind === 'success' ? '✓' : kind === 'error' ? '!' : '…';
  signInButton.classList.add('hidden');
}

function readableError(error) {
  const code = String(error?.code || '');
  if (code.includes('deadline-exceeded')) return 'Mã QR đã hết hạn. Hãy quay lại và quét mã mới.';
  if (code.includes('not-found')) return 'Mã QR không hợp lệ.';
  if (code.includes('failed-precondition')) return 'Phiên điểm danh đã kết thúc.';
  if (code.includes('permission-denied')) return 'Bạn cần đăng nhập bằng tài khoản Google.';
  return 'Không thể hoàn tất điểm danh. Vui lòng quét lại mã QR.';
}

async function submitCheckIn(user) {
  if (submitStarted || !token) return;
  submitStarted = true;
  showStatus('loading', 'Đang xác nhận…', `Đang kiểm tra ${user.email ?? 'tài khoản Google'}.`);

  try {
    const checkIn = httpsCallable(functions, 'checkIn');
    const result = await checkIn({ token });
    const data = result.data;
    sessionStorage.removeItem('attendanceQrToken');
    if (data.status === 'duplicate') {
      showStatus('success', 'Bạn đã điểm danh', `${data.email} đã được ghi nhận trước đó cho slot này.`);
    } else {
      showStatus('success', 'Điểm danh thành công', `${data.email} đã được ghi nhận.`);
    }
    await signOut(auth);
  } catch (error) {
    console.error(error);
    showStatus('error', 'Không thể điểm danh', readableError(error));
    await signOut(auth).catch(() => undefined);
  }
}

async function bootstrap() {
  if (!token) {
    showStatus('error', 'Thiếu mã QR', 'Hãy quét mã QR đang hiển thị trên máy giảng viên.');
    return;
  }

  if (!firebaseConfig.apiKey || !firebaseConfig.projectId) {
    showStatus('error', 'Chưa cấu hình hệ thống', 'Firebase Hosting đang thiếu biến môi trường.');
    return;
  }

  const app = initializeApp(firebaseConfig);
  auth = getAuth(app);
  functions = getFunctions(app, 'asia-southeast1');
  await setPersistence(auth, browserSessionPersistence);

  onAuthStateChanged(auth, (user) => {
    if (user) submitCheckIn(user);
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
      showStatus('error', 'Không mở được đăng nhập', 'Vui lòng quét lại QR và thử lại.');
    }
  });
}

bootstrap().catch((error) => {
  console.error(error);
  showStatus('error', 'Lỗi khởi tạo', 'Không thể kết nối tới hệ thống điểm danh.');
});
