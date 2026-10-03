# FAP Sinh viên — Android module

App Flutter riêng cho sinh viên, cùng project Firestore với desktop giáo viên. Bao gồm Google login, môn theo email roster, TKB ngày/tuần, QR + mã xác nhận, lịch sử điểm danh theo môn và đơn xin nghỉ. Đặc tả gốc: [STUDENT_MOBILE_APP_AGENT_TASK.md](../docs/STUDENT_MOBILE_APP_AGENT_TASK.md).

## Cài APK để test với desktop

1. Lấy `artifacts/fap-student-debug.apk` tại thư mục gốc repo sau khi build; copy sang điện thoại Android và mở file. Cho phép cài từ nguồn đang dùng nếu Android yêu cầu.
2. Kiểm tra Rules/indexes mới đã được triển khai vào `fap-checkin-c8c8d`. Nếu chưa, tính năng tự tìm môn/lịch sử sẽ bị từ chối. Việc deploy được thực hiện riêng ở phần bên dưới.
3. Trên desktop, thêm email Google của bạn vào roster một môn–lớp và giữ `active: true`; nhập MSSV/họ tên đúng. App mobile nhận phân công theo email, không cần tài khoản sinh viên được tạo trước.
4. Mở **FAP Sinh viên**, đăng nhập Google đúng email. Kiểm tra môn và TKB; vào môn để xem trạng thái từng buổi.
5. Desktop mở phiên điểm danh. Trên điện thoại chọn **Quét QR**, cho phép Camera, quét QR desktop và nhập mã xác nhận 5 ký tự đang hiển thị. Desktop phải nhận được đúng một lượt canonical.
6. Quét lại để kiểm tra không nhân đôi; thử QR hết hạn, mã sai và QR lớp không chứa email của bạn. App chỉ báo xác nhận khi server trả thành công.
7. Vào **Đơn**, chọn môn, buổi từ ngày mai và lý do 10–1000 ký tự. Desktop duyệt/từ chối; app hiển thị phản hồi. Đơn approved chưa tự tạo attendance excused trước khi desktop mở buổi.
8. Kiểm tra đổi tài khoản và ngừng active trên desktop: dữ liệu lớp phải bị gỡ/chặn khỏi tài khoản không còn quyền.

APK debug là bản để cài thử, không phải bản phát hành store. Hiện chưa nghiệm thu trên điện thoại vật lý; cần kiểm tra Camera và Google account thực tế theo checklist trên. iOS có project và quyền camera nhưng chưa đăng ký Firebase app riêng/build/sign trên macOS.

## Build trên máy hiện tại

Từ root repo:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tool/build_student_android.ps1
```

Script giữ Pub/Gradle/TEMP và output trong project trên D:, sinh khóa debug local nếu chưa có, kiểm tra project mobile trùng desktop rồi copy APK sang `artifacts/fap-student-debug.apk`.

Cài bằng USB sau khi bật **Developer options → USB debugging**, cắm điện thoại và chấp nhận RSA của máy tính:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tool/build_student_android.ps1 -Install
```

Nếu có nhiều thiết bị, thêm `-DeviceId <serial>`. Bản mới cùng khóa debug có thể cài đè. Nếu mất khóa hoặc APK cũ được ký bằng khóa khác, Android sẽ từ chối cài đè; gỡ bản cũ trước khi cài bản mới.

## Cấu hình Firebase và Google login

File local `firebase.mobile.json` được truyền qua `--dart-define-from-file`, đã bị gitignore. Không dùng `firebase.desktop.json` để build mobile vì có secret và appId của nền tảng khác.

Android app đăng ký cho module này:

```text
Project:     fap-checkin-c8c8d
Package:     vn.fapcheckin.fap_student
Firebase ID: 1:77988315843:android:13f078924be4df35d89876
```

Trên máy mới:

1. Copy `firebase.mobile.example.json` thành `firebase.mobile.json`.
2. Chuẩn bị khóa debug, lấy fingerprint:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tool/build_student_android.ps1 -PrepareOnly
```

3. Đăng ký SHA-1 in ra trong Firebase Console → Project settings → Android app này. Hoặc dùng `firebase apps:android:sha:create <appId> <SHA1> --project fap-checkin-c8c8d` nếu được phép cập nhật project.
4. Tải config Android mới:

```powershell
firebase.cmd apps:sdkconfig ANDROID 1:77988315843:android:13f078924be4df35d89876 --project fap-checkin-c8c8d --out student-mobile/android/app/google-services.json
```

5. Điền `FIREBASE_API_KEY`, Android `FIREBASE_APP_ID`, projectId/projectNumber từ config. `GOOGLE_SERVER_CLIENT_ID` là OAuth client có `client_type: 3` (Web client), **không phải Android OAuth client**. Cấu hình Google provider phải được bật trong Firebase Auth.

Module initialize Firebase bằng Dart options và Google Sign-In bằng serverClientId. `google-services.json` là nguồn để cấu hình local, không cần áp dụng Gradle google-services plugin cho luồng này. Không commit key signing, config local hoặc tài khoản service. SHA-1 đã đăng ký cho APK máy hiện tại:

```text
2D:69:4E:97:E1:C9:0C:14:68:FC:C2:94:B1:81:C2:88:81:D4:3E:3C
```

Khóa `.tool-cache/android/student-debug.keystore` chỉ dùng debug; lưu giữ local để các bản test sau có cùng chữ ký. Máy mới có khóa khác phải đăng ký SHA mới. [Hướng dẫn chính thức Google Sign-In Android](https://pub.dev/packages/google_sign_in_android) giải thích serverClientId và fingerprints; [Firebase Flutter Google login](https://firebase.google.com/docs/auth/flutter/federated-auth) mô tả nối Google credential vào Firebase Auth.

## Quyền đọc và query

| Chức năng | Query/path | Rule |
| --- | --- | --- |
| Tìm môn | Group `students`, emailNormalized = email normalize của Auth, active = true | Recursive list cùng hai điều kiện; không cấp get/write ngoài namespace roster. |
| Bootstrap môn | `courseClasses/{id}/studentAccess/{uid}` | Chỉ caller tạo liên kết đúng roster active; course get xác minh lại membership. |
| Lịch/metadata | Get/listener đúng courseId | Chủ lớp hoặc membership active. |
| Lịch sử phiên | `attendanceSessions.where(courseClassId == id)` | Membership qua studentAccess + roster active; không list toàn bộ phiên. |
| Attendance | Get/listener `records/{studentId}` từng slot | Email trùng roster active. Không list records sinh viên khác. |
| Legacy fallback | Get/listener `checkIns/{uid}` từng slot | Membership + đúng UID. Canonical luôn thắng legacy. |
| Đơn | `leaveRequests.where(firebaseUid == uid)` trong từng lớp | Membership + đúng UID. Không đọc ID chưa tồn tại. |
| Điểm danh mới | Transaction QR → active session → roster → canonical | Whitelist payload + TTL/generation + checkout code do server kiểm chứng. |

Index mới: group `students` theo emailNormalized + active. Rule mới dùng lowercase email Auth nhất quán. Chưa có session cho buổi thì hiển thị chưa mở; không suy vắng từ ngày đã qua. Một buổi đã kết thúc không có record mới suy Vắng, khớp desktop. Không tự ghi record absent/excused từ mobile.

Các phiên active vẫn có quyền direct-get cho Google user như web check-in cũ để bootstrap QR trước khi biết courseId; query lịch sử yêu cầu membership. Document checkout code luôn riêng giáo viên. Discovery dùng roster đang có, không migration hoặc bảng enrollment mới.

## Kiểm tra và deploy

Trong `student-mobile/`, dùng Pub cache chung với root:

```powershell
$env:PUB_CACHE = 'D:\projects\fap-checkin\.pub-cache'
flutter.bat analyze --no-pub
flutter.bat test --no-pub
```

Tại root:

```powershell
firebase.cmd emulators:exec --only firestore --project demo-fap-checkin-rules "npm.cmd --prefix web-checkin run test:rules"
flutter.bat test --no-pub
npm.cmd --prefix web-checkin run build
```

Sau khi được cho phép cập nhật production:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tool/deploy_firestore.ps1
```

Script kiểm tra project, chạy emulator tests rồi deploy đồng thời Rules/indexes. Không skip test cho lần rollout đầu. Chờ index group `students` sẵn sàng trước khi nghiệm thu tìm môn. Không cần deploy Cloud Functions hoặc thay desktop build cho mobile; Firestore và Apps Script tiếp tục là luồng dữ liệu hiện có. Thay đổi `leave.js` trong nhánh sửa đọc lịch sử web bằng query riêng; nếu muốn áp dụng sửa này lên trang web phải build/deploy Hosting riêng.

Có thể thêm `EMULATOR_HOST` vào config debug để trỏ Firestore/Auth tới emulator (Android emulator: `10.0.2.2`, điện thoại: IP LAN của máy). Phải dùng config project demo và auth emulator phù hợp; không đổi sang production để vượt lỗi fixtures. Test allow/deny và transaction chạy qua JS Firebase SDK thật trong Firestore Emulator; unit/widget mobile kiểm tra parser/hash/thống kê/login. Chưa có bài integration chạy repository Dart trên thiết bị trong lần bàn giao này.

## Giới hạn và xử lý lỗi

- App chưa đăng ký tự mở deep link từ trình duyệt; camera nhận URL QR desktop.
- Cache Firestore trên đĩa tắt để tránh giữ roster của người khác trên máy dùng chung; đăng xuất thay Navigator và dừng listeners. Firebase Auth vẫn lưu đăng nhập mobile.
- Điểm danh dùng transaction online, không xếp hàng offline. Đơn dùng atomic batch; chỉ báo gửi thành công sau ACK. Nếu mất mạng khi gửi đơn, đợi server hoặc mở lại lịch sử để kiểm chứng trước khi gửi lại.
- Rules không lọc kết quả thay client: thiếu filter sẽ bị từ chối. Nếu app báo thiếu quyền, kiểm tra đã deploy Rules/index, email Google, roster active và config đúng project.
- Permission-denied khi submit QR không chứng minh duy nhất rằng code sai; quét lại QR mới và kiểm tra cả phiên/roster/code.
- Không có tên giáo viên/phòng/tên môn đầy đủ trong schema hiện tại, nên UI dùng mã môn–lớp/học kỳ. Slot 6/7 và lịch 90 phút không bịa giờ học.
- Không đổi email roster hoặc migrate ID tự động. Roster legacy lệch hash báo lỗi để giáo viên xử lý riêng.
- Nghiệp vụ thống kê tham chiếu `lib/domain/class_overview.dart` ở desktop. Unit test kiểm tra giới hạn cảnh báo 10%/trên 20%, không dùng tỷ lệ này để tự tuyên bố cấm thi.
- iOS cần Firebase app đúng bundle `vn.fapcheckin.fapStudent`, `GOOGLE_IOS_CLIENT_ID`, URL scheme và signing bằng Xcode trước khi sử dụng; bản APK hiện tại chỉ cho Android.
