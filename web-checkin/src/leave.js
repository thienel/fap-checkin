import { initializeApp } from 'firebase/app';
import {
  browserSessionPersistence, getAuth, inMemoryPersistence,
  onAuthStateChanged, setPersistence, signOut,
} from 'firebase/auth';
import { collection, doc, getDoc, getDocs, getFirestore, query, serverTimestamp, setDoc, where } from 'firebase/firestore';
import { googleSignInError, signInWithGoogle } from './google_sign_in.js';

const title = document.querySelector('#title');
const message = document.querySelector('#message');
const announcement = document.querySelector('#announcement');
const signInButton = document.querySelector('#sign-in');
const browserHelp = document.querySelector('#browser-help');
const panel = document.querySelector('#leave-panel');
const slotsElement = document.querySelector('#leave-slots');
const historyElement = document.querySelector('#leave-history');
const form = document.querySelector('#leave-form');

function notice(heading, detail) {
  title.textContent = heading;
  message.textContent = detail;
  announcement.textContent = `${heading}. ${detail}`;
}

async function studentIdFor(email) {
  const bytes = new TextEncoder().encode(email);
  const digest = await crypto.subtle.digest('SHA-256', bytes);
  return [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, '0')).join('');
}

function requestLabel(data) {
  const status = {
    pending: 'Đang chờ duyệt', approved: 'Đã duyệt', rejected: 'Đã từ chối',
  }[data.status] || data.status;
  return `Buổi ${data.slot} · ${data.date}: ${status}${data.response ? ` — ${data.response}` : ''}`;
}

export async function startLeave(config, courseClassId) {
  if (!config.apiKey || !config.projectId) throw new Error('Firebase chưa cấu hình');
  if (!courseClassId || courseClassId.includes('/')) throw new Error('Mã lớp không hợp lệ');
  const app = initializeApp(config);
  const auth = getAuth(app);
  const db = getFirestore(app);
  try {
    await setPersistence(auth, browserSessionPersistence);
  } catch (error) {
    console.warn('Session auth persistence unavailable; using memory:', error);
    await setPersistence(auth, inMemoryPersistence);
  }
  let currentStudentId;
  let course;
  let requests = new Map();
  let loading = false;

  async function load(user) {
    if (!user.email) throw new Error('Tài khoản Google không cung cấp email.');
    const email = user.email.trim().toLowerCase();
    currentStudentId = await studentIdFor(email);
    const base = ['courseClasses', courseClassId];
    const student = await getDoc(doc(db, ...base, 'students', currentStudentId));
    if (!student.exists() || student.data().active !== true) {
      throw new Error('Email này không có trong danh sách sinh viên đang học của lớp.');
    }
    const access = doc(db, ...base, 'studentAccess', user.uid);
    if (!(await getDoc(access)).exists()) {
      await setDoc(access, {
        studentId: currentStudentId, emailNormalized: email, createdAt: serverTimestamp(),
      });
    }
    const courseDoc = await getDoc(doc(db, ...base));
    if (!courseDoc.exists()) throw new Error('Không tìm thấy lớp học.');
    course = courseDoc.data();
    const schedule = Array.isArray(course.schedule) ? course.schedule : [];
    requests = new Map();
    const history = await getDocs(query(collection(db, ...base, 'leaveRequests'),
      where('firebaseUid', '==', user.uid)));
    for (const request of history.docs) requests.set(request.data().slot, request.data());
    slotsElement.replaceChildren();
    historyElement.replaceChildren();
    const today = new Date().toLocaleDateString('sv-SE', { timeZone: 'Asia/Ho_Chi_Minh' });
    const future = schedule.filter((slot) => typeof slot.date === 'string' && slot.date > today)
      .sort((a, b) => a.number - b.number);
    for (const slot of future) {
      const label = document.createElement('label');
      label.className = 'leave-choice';
      const input = document.createElement('input');
      input.type = 'checkbox';
      input.name = 'slot';
      input.value = String(slot.number);
      input.disabled = requests.has(slot.number);
      label.append(input, document.createTextNode(`Buổi ${slot.number} · ${slot.date}${requests.has(slot.number) ? ' · Đã gửi đơn' : ''}`));
      slotsElement.append(label);
    }
    if (future.length === 0) slotsElement.textContent = 'Lớp chưa có buổi học tương lai.';
    const entries = [...requests.values()].sort((a, b) => a.slot - b.slot);
    if (entries.length === 0) historyElement.textContent = 'Chưa có đơn xin nghỉ.';
    for (const request of entries) {
      const row = document.createElement('p');
      row.textContent = requestLabel(request);
      historyElement.append(row);
    }
    document.querySelector('#leave-account').textContent = `${course.subject} · ${course.classCode} · ${email}`;
    signInButton.classList.add('hidden');
    browserHelp.classList.add('hidden');
    panel.classList.remove('hidden');
    notice('Xin phép nghỉ', 'Chọn các buổi tương lai, nhập lý do và gửi đơn để giảng viên xem xét.');
  }

  signInButton.addEventListener('click', async () => {
    signInButton.disabled = true;
    try {
      await signInWithGoogle(auth);
    } catch (error) {
      notice('Không thể đăng nhập', googleSignInError(error));
      browserHelp.classList.remove('hidden');
      signInButton.disabled = false;
    }
  });
  document.querySelector('#leave-switch-account').addEventListener('click', () => signOut(auth));
  document.querySelector('#leave-refresh').addEventListener('click', async () => {
    if (!auth.currentUser) return;
    try {
      await load(auth.currentUser);
      notice('Đã cập nhật', 'Trạng thái đơn mới nhất đang hiển thị bên dưới.');
    } catch (error) {
      notice('Không thể tải trạng thái', error.message);
    }
  });
  form.addEventListener('submit', async (event) => {
    event.preventDefault();
    if (loading || !auth.currentUser || !course) return;
    const selected = [...form.querySelectorAll('input[name="slot"]:checked')].map((input) => Number(input.value));
    const reason = document.querySelector('#leave-reason').value.trim();
    if (!selected.length) {
      notice('Chưa chọn buổi', 'Hãy chọn ít nhất một buổi học tương lai.');
      return;
    }
    if (reason.length < 10 || reason.length > 1000) {
      notice('Lý do chưa hợp lệ', 'Lý do cần từ 10 đến 1000 ký tự.');
      return;
    }
    loading = true;
    document.querySelector('#leave-submit').disabled = true;
    try {
      for (const number of selected) {
        const slot = course.schedule.find((item) => item.number === number);
        const reference = doc(db, 'courseClasses', courseClassId, 'leaveRequests', `${currentStudentId}_${number}`);
        if (requests.has(number) || !slot) throw new Error('Buổi này đã có đơn hoặc không còn trong lịch.');
        await setDoc(reference, {
          ownerUid: course.ownerUid, courseClassId, studentId: currentStudentId,
          firebaseUid: auth.currentUser.uid, emailNormalized: auth.currentUser.email.trim().toLowerCase(),
          slot: number, date: slot.date, slotDate: new Date(`${slot.date}T00:00:00Z`),
          reason, status: 'pending', createdAt: serverTimestamp(),
        });
      }
      document.querySelector('#leave-reason').value = '';
      await load(auth.currentUser);
      notice('Đã gửi đơn', `Đã gửi yêu cầu cho ${selected.length} buổi. Trạng thái sẽ hiện ở bên dưới.`);
    } catch (error) {
      console.error(error);
      await load(auth.currentUser).catch(() => undefined);
      notice('Không thể gửi đơn', error.code === 'permission-denied'
        ? 'Bạn không còn quyền gửi đơn hoặc buổi học không còn hợp lệ. Hãy tải lại trang.'
        : error.message);
    } finally {
      loading = false;
      document.querySelector('#leave-submit').disabled = false;
    }
  });

  onAuthStateChanged(auth, async (user) => {
    panel.classList.add('hidden');
    if (!user) {
      signInButton.disabled = false;
      signInButton.classList.remove('hidden');
      browserHelp.classList.remove('hidden');
      notice('Xin phép nghỉ', 'Đăng nhập bằng email Google đã đăng ký trong lớp để gửi và theo dõi đơn.');
      return;
    }
    notice('Đang tải lớp học', 'Đang xác minh email và lịch học của bạn.');
    try {
      await load(user);
    } catch (error) {
      console.error(error);
      notice('Không thể mở lớp', error.code === 'permission-denied'
        ? 'Email này không được phép xem lớp học. Hãy liên hệ giảng viên.'
        : error.message);
      signInButton.classList.remove('hidden');
    }
  });
}
