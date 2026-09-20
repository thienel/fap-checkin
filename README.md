# FAP Check Attendance — Firebase Spark

Ứng dụng chạy hoàn toàn không cần Cloud Functions và dùng được với Firebase Spark:

- Flutter Desktop điều khiển môn–lớp, phiên điểm danh và QR xoay vòng.
- Firebase Hosting phục vụ trang sinh viên đăng nhập Google.
- Firestore lưu lịch, phiên, QR và lượt điểm danh. Security Rules dùng thời gian máy chủ để kiểm tra hạn QR.
- Google Apps Script nhận các lượt hợp lệ từ desktop và ghi vào Google Sheets.

Mỗi tab Google Sheets có tên `<MÔN>_<LỚP>`, ví dụ `PRM393_SE1910`. Dữ liệu được sắp theo `Slot → Date → Check-in time` khi ngừng phiên.

## 1. Cấu hình Firebase

Trong [Firebase Console](https://console.firebase.google.com/):

1. Chọn project `fap-checkin`.
2. Authentication → Sign-in method: bật **Google** và **Email/Password**.
3. Firestore Database → Create database. Chọn location gần người dùng, ví dụ Singapore.
4. Project settings → Your apps → tạo một **Web App**, rồi điền cấu hình đó vào `web-checkin/.env`.
5. Tạo tài khoản giảng viên ở Authentication → Users → Add user.
6. Lấy UID của tài khoản vừa tạo và thêm document `teachers/<UID>` trong Firestore:

```json
{
  "active": true
}
```

Đăng nhập Firebase CLI bằng đúng Google account sở hữu project:

```bash
firebase login
firebase use fap-checkin
firebase projects:list
```

## 2. Cấu hình trang check-in

```bash
cp web-checkin/.env.example web-checkin/.env
```

Điền các giá trị Firebase Web App vào `web-checkin/.env`. Đây là cấu hình public của Firebase client, không phải service-account secret.

## 3. Tạo Google Apps Script để ghi Sheets

1. Tạo một Google Spreadsheet và lấy ID nằm giữa `/d/` và `/edit` trong URL.
2. Mở [script.google.com](https://script.google.com/) → **New project**.
3. Sao chép nội dung `apps-script/Code.gs` trong repository vào file `Code.gs` của project.
4. Project Settings → Script Properties → thêm:
   - `SPREADSHEET_ID`: ID của Google Spreadsheet.
   - `SYNC_SECRET`: một chuỗi ngẫu nhiên dài, ví dụ tạo bằng `openssl rand -hex 32`.
5. Deploy → New deployment → loại **Web app**:
   - Execute as: **Me**.
   - Who has access: **Anyone**.
6. Authorize quyền Google Sheets và sao chép URL kết thúc bằng `/exec`.

Apps Script chỉ nhận request có `SYNC_SECRET`. Với bản MVP chạy trên máy giảng viên, secret được đóng gói trong cấu hình desktop; không nên phát hành file cấu hình này công khai.

## 4. Cấu hình Flutter Desktop

```bash
cp firebase.desktop.example.json firebase.desktop.json
```

Điền cấu hình Firebase desktop cùng ba giá trị sau:

```json
{
  "PUBLIC_WEB_URL": "https://fap-checkin.web.app",
  "APPS_SCRIPT_URL": "https://script.google.com/macros/s/.../exec",
  "APPS_SCRIPT_SECRET": "giống-SYNC_SECRET-trong-Apps-Script"
}
```

`firebase.desktop.json`, `web-checkin/.env` và các secret không được commit lên Git.

## 5. Cài đặt và deploy trên Spark

```bash
flutter pub get
npm --prefix web-checkin install
firebase deploy --only firestore,hosting
```

Không chạy `--only functions` vì Cloud Functions cần Blaze. `firebase.json` hiện không còn cấu hình deploy Functions; thư mục `functions/` chỉ được giữ làm mã legacy để đối chiếu và có thể xóa sau.

URL check-in cố định:

```text
https://fap-checkin.web.app/check-in?t=<QR_TOKEN>
```

## 6. Chạy desktop

macOS:

```bash
flutter run -d macos --dart-define-from-file=firebase.desktop.json
```

Firebase Auth trên macOS cần **Keychain Sharing** và chữ ký Apple Development.
Project hiện dùng Personal Team trong `macos/Runner/Configs/AppInfo.xcconfig`.
Nếu chạy trên một máy/Xcode account khác, thay `DEVELOPMENT_TEAM` bằng Team ID
của tài khoản đang đăng nhập trong Xcode trước khi build.

Windows:

```powershell
.\tool\run_windows.ps1
```

Build file `.exe` trên ổ D:

```powershell
.\tool\build_windows.ps1 -Mode release
```

Hai script trên yêu cầu project nằm ở ổ `D:` và đặt Pub/TEMP/npm cache cục bộ
trong project. File chạy được tạo tại
`build\windows\x64\runner\<Mode>\fap_check_attendance.exe`, không dùng ổ C
cho output hoặc cache riêng của project.

Nếu chưa cấu hình Apps Script, app vẫn điểm danh và lưu Firestore nhưng sẽ hiển thị cảnh báo rằng Google Sheets chưa được đồng bộ. Khi cấu hình xong và mở lại app, tối đa 100 bản ghi pending/error sẽ được thử gửi lại mỗi lần khởi động.

## Quy tắc bảo mật và dữ liệu

- Thời hạn QR được tính từ `serverTimestamp()` của Firestore, không tin đồng hồ điện thoại hay desktop.
- Security Rules từ chối đọc QR sau thời hạn và từ chối ghi khi session đã dừng.
- Document check-in có đường dẫn `attendance/<môn-lớp>/slots/<slot>/checkIns/<firebase-uid>`, nên một tài khoản Google chỉ được ghi lần đầu cho cùng môn–lớp–slot.
- Apps Script kiểm tra `Record ID` trước khi append, nên retry không tạo dòng trùng trong Google Sheets.
- Firestore là dữ liệu gốc. Google Sheets là bản đồng bộ do desktop thực hiện khi máy đang mở.

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
npm --prefix web-checkin run build
firebase emulators:exec --only firestore "true"
```
