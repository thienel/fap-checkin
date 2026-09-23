# Hướng dẫn Setup Dự án (Cho thành viên mới / Khi Pull Code về)

Tài liệu này hướng dẫn chi tiết các bước thiết lập môi trường để chạy ứng dụng sau khi `git pull` mã nguồn từ GitHub.

---

## 📋 1. Cài đặt các thư viện phụ thuộc (Dependencies)

Sau khi pull code về, chạy các lệnh sau từ thư mục gốc của dự án:

### a. Cài đặt thư viện cho Flutter Desktop App:
```bash
flutter pub get
```

### b. Cài đặt thư viện cho Web Check-in App:
```bash
npm --prefix web-checkin install
```

---

## ⚙️ 2. Tạo các file Cấu hình Môi trường (Environment Setup)

Do các file chứa API Key và credentials được bảo mật trong `.gitignore`, bạn cần copy từ các file mẫu `*.example` có sẵn trong repository:

### a. Cấu hình cho Flutter Desktop (`firebase.desktop.json`):
```bash
cp firebase.desktop.example.json firebase.desktop.json
```
*Sau khi copy, điền thông tin project Firebase vào file `firebase.desktop.json`:*
```json
{
  "FIREBASE_API_KEY": "AIzaSy...",
  "FIREBASE_APP_ID": "1:...",
  "FIREBASE_MESSAGING_SENDER_ID": "...",
  "FIREBASE_PROJECT_ID": "fap-checkin-f7d35",
  "FIREBASE_STORAGE_BUCKET": "fap-checkin-f7d35.firebasestorage.app",
  "FIREBASE_IOS_BUNDLE_ID": "com.example.fapCheckAttendance",
  "PUBLIC_WEB_URL": "https://fap-checkin-f7d35.web.app",
  "APPS_SCRIPT_URL": "",
  "APPS_SCRIPT_SECRET": ""
}
```

### b. Cấu hình cho Web Check-in (`web-checkin/.env`):
```bash
cp web-checkin/.env.example web-checkin/.env
```
*Điền thông tin Firebase Web App vào `web-checkin/.env`:*
```env
VITE_FIREBASE_API_KEY="AIzaSy..."
VITE_FIREBASE_AUTH_DOMAIN="fap-checkin-f7d35.firebaseapp.com"
VITE_FIREBASE_PROJECT_ID="fap-checkin-f7d35"
VITE_FIREBASE_STORAGE_BUCKET="fap-checkin-f7d35.firebasestorage.app"
VITE_FIREBASE_MESSAGING_SENDER_ID="..."
VITE_FIREBASE_APP_ID="1:..."
```

---

## 🚀 3. Khởi chạy Ứng dụng (Running Locally)

### a. Chạy App Desktop Giảng viên:
```powershell
flutter run -d windows --dart-define-from-file=firebase.desktop.json
```
*Hoặc sử dụng script hỗ trợ có sẵn trên Windows:*
```powershell
.\tool\run_windows.ps1
```

### b. Chạy Web Sinh viên (Local Development):
```bash
npm --prefix web-checkin run dev
```

---

## 📦 4. Chạy File Executable Đã Build Sẵn (.exe)

Nếu bạn muốn gửi phiên bản chạy trực tiếp cho bạn bè / giảng viên sử dụng trên Windows mà **không cần cài Flutter hay NodeJS**:

- **Vị trí file chạy**: `build\windows\x64\runner\Release\`
- **File thực thi**: `fap_check_attendance.exe`

*(Lưu ý: Cần copy toàn bộ thư mục `Release/` khi chia sẻ ứng dụng).*

---

## 🧪 5. Kiểm thử & Deploy

- **Chạy toàn bộ kiểm thử Flutter**: `flutter test`
- **Build Web production**: `npm --prefix web-checkin run build`
- **Deploy Firestore Rules**: `powershell -NoProfile -ExecutionPolicy Bypass -File tool/deploy_firestore.ps1`
