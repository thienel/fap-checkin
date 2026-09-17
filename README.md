# FAP Check Attendance

Ứng dụng điểm danh gồm ba phần:

- Flutter Desktop: tạo môn–lớp, tìm slot hôm nay, bắt đầu/ngừng phiên và hiển thị QR xoay vòng.
- Firebase Hosting: trang di động để sinh viên đăng nhập Google.
- Cloud Functions + Firestore: xác thực hạn QR bằng thời gian máy chủ, chống trùng và đồng bộ Google Sheets.

Mỗi tab Google Sheets có tên `<MÔN>_<LỚP>`, ví dụ `PRM393_SE1910`. Dòng dữ liệu được sắp theo `Slot → Date → Check-in time` khi giảng viên ngừng phiên.

## 1. Yêu cầu

- Flutter stable.
- Node.js 22 để khớp runtime Cloud Functions.
- Một Firebase project có Firestore database.
- Một Google Spreadsheet.
- Firebase CLI (`npm install -g firebase-tools`) hoặc chạy bằng `npx firebase-tools`.

## 2. Cấu hình Firebase

Trong Firebase Console:

1. Bật Authentication → Sign-in method → **Google** và **Email/Password**.
2. Tạo Firestore database.
3. Thêm một Firebase Web App cho `web-checkin`.
4. Thêm ứng dụng macOS/Windows tương ứng với desktop app.
5. Trong Google Cloud Console, bật **Google Sheets API**.

Sao chép file project alias:

```bash
cp .firebaserc.example .firebaserc
```

Thay `YOUR_FIREBASE_PROJECT_ID` trong `.firebaserc`.

## 3. Cấu hình trang check-in

```bash
cp web-checkin/.env.example web-checkin/.env
```

Điền các giá trị của Firebase Web App vào `web-checkin/.env`.

## 4. Cấu hình Cloud Functions và Google Sheets

Tạo `functions/.env.<project-id>`:

```dotenv
GOOGLE_SHEETS_ID=id-lấy-từ-url-google-sheet
PUBLIC_WEB_URL=https://<project-id>.web.app
```

Ví dụ spreadsheet URL là:

```text
https://docs.google.com/spreadsheets/d/1AbCdEf.../edit
```

thì `GOOGLE_SHEETS_ID` là `1AbCdEf...`.

Cloud Functions Gen 2 ghi Sheets bằng runtime service account. Sau lần deploy đầu, mở function trong Google Cloud Console, xem **Runtime service account**, rồi chia sẻ spreadsheet cho email đó với quyền Editor.

Không đưa service-account JSON vào Flutter app hoặc repository.

## 5. Tạo tài khoản giảng viên

1. Firebase Console → Authentication → Users → Add user bằng email/password.
2. Sao chép UID của user.
3. Tạo document Firestore `teachers/<UID>` với dữ liệu:

```json
{
  "active": true
}
```

Chỉ tài khoản có document này mới được tạo môn–lớp hoặc điều khiển điểm danh.

## 6. Cài đặt và deploy

```bash
flutter pub get
npm --prefix functions install
npm --prefix web-checkin install
npx firebase-tools login
npx firebase-tools deploy --only firestore,functions,hosting
```

Sau deploy, URL check-in cố định là:

```text
https://<project-id>.web.app/check-in?t=<QR_TOKEN>
```

## 7. Chạy Flutter Desktop

```bash
cp firebase.desktop.example.json firebase.desktop.json
```

Điền cấu hình ứng dụng desktop, sau đó chạy:

```bash
flutter run -d macos --dart-define-from-file=firebase.desktop.json
```

Hoặc trên Windows:

```powershell
flutter run -d windows --dart-define-from-file=firebase.desktop.json
```

## Quy tắc lịch

- `20 slot / 10 tuần` và `10 slot / 5 tuần`: cộng 3 ngày học, bỏ Chủ nhật.
- `10 slot / 10 tuần`: cộng 7 ngày.
- `20 slot / 3 tuần` và `10 slot / 3 tuần`: học các ngày liên tiếp, bỏ Chủ nhật.
- Ngày bắt đầu là slot 1 và không được là Chủ nhật.
- Số tuần là nhãn preset; việc sinh lịch dừng khi đủ số slot.

## Kiểm thử

```bash
flutter analyze
flutter test
npm --prefix functions test
npm --prefix web-checkin run build
```

## Ghi chú vận hành

- Backend dùng thời gian Cloud Functions để kiểm tra hạn QR, không tin thời gian trên điện thoại hoặc desktop.
- Một email chỉ được ghi lần đầu cho cùng `môn–lớp–slot`.
- Nhấn **Ngừng điểm danh** làm toàn bộ QR của session mất hiệu lực ngay.
- Nếu Google Sheets tạm lỗi, lượt điểm danh vẫn được giữ trong Firestore và job định kỳ sẽ thử đồng bộ lại.
