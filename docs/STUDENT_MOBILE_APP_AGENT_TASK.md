# Giao việc cho AI agent: ứng dụng mobile sinh viên FAP Check-in

Ngày review: 03/10/2026. Mã nguồn tham chiếu: commit `29721fe` và working tree tại thời điểm review.

Đây là đặc tả để triển khai tiếp, chưa phải báo cáo tính năng đã được xây dựng. Các nhận xét bên dưới dựa trên đọc mã nguồn; chưa chạy app, kiểm thử hoặc đối chiếu dữ liệu production trong lần review này.

## 1. Mục tiêu và phạm vi

Xây dựng ứng dụng Flutter cho sinh viên, dùng chung Firebase/Firestore với desktop giáo viên và trang web sinh viên hiện tại. Giáo viên thêm sinh viên vào môn–lớp bằng email; khi sinh viên đăng nhập đúng email Google, app tự hiển thị các môn được phân công mà không cần nhập mã lớp hoặc mở link riêng từng môn.

Các chức năng bắt buộc:

1. Đăng nhập Google, xem tài khoản, đổi tài khoản và đăng xuất.
2. Xem danh sách môn–lớp của mình, phân biệt học kỳ và giáo viên sở hữu lớp.
3. Xem thời khóa biểu hôm nay và theo tuần, mở chi tiết buổi học.
4. Quét QR điểm danh và nhập mã xác nhận đang hiển thị trên desktop giáo viên.
5. Xem trạng thái điểm danh từng buổi, thống kê và cảnh báo vắng theo từng môn.
6. Gửi và theo dõi đơn xin nghỉ, nhận trạng thái/phản hồi của giáo viên.

Giả định triển khai: Flutter app riêng trong `student-mobile/`, Android là nền tảng nghiệm thu đầu tiên; chuẩn bị cấu hình iOS nhưng chỉ xác nhận build/test iOS khi có macOS/Xcode. “Gửi đơn” ở MVP là **đơn xin nghỉ theo buổi** đã có trong hệ thống. Các loại đơn khác, tệp minh chứng, thông báo push, điểm số và tích hợp FAP chính thức nằm ngoài MVP.

## 2. Kết quả review mã nguồn

| Nguồn cần đọc | Hiện trạng và ý nghĩa khi triển khai |
| --- | --- |
| `README.md`, `firebase.json` | Luồng đang sử dụng là Flutter desktop + Firebase Auth/Firestore Rules + Hosting + Apps Script. `functions/` là legacy và không được cấu hình deploy. Tiếp tục hỗ trợ Spark, không lấy Cloud Functions làm backend mặc định. |
| `lib/main.dart`, `lib/app.dart`, `lib/firebase_options.dart` | Bootstrap hiện dành cho giáo viên; `DesktopFirebaseOptions.currentPlatform` chỉ chấp nhận Windows/macOS. Không thể lấy entrypoint này chạy Android trực tiếp. |
| `lib/screens/login_screen.dart` | Desktop đăng nhập Email/Password. Sinh viên hiện dùng Google; cần auth flow mobile riêng. |
| `lib/services/attendance_api.dart` | API chủ yếu yêu cầu giáo viên; có thêm/import/kích hoạt roster, tạo/dời lịch, mở/dừng phiên, duyệt đơn, chỉnh điểm danh và đồng bộ Sheets. Không dùng nguyên service này làm API sinh viên. |
| `lib/domain/roster_import.dart` | Email được trim và lowercase; MSSV được trim và uppercase. |
| `lib/domain/schedule.dart` | Có preset lịch, `ScheduledSlot`, khung giờ trong ngày và quy tắc học kỳ. `slot.number` là thứ tự buổi của môn; `daySlot` là khung giờ trong ngày. |
| `lib/domain/class_overview.dart`, `test/class_overview_test.dart` | Có quy tắc tổng hợp trạng thái, tỷ lệ tham dự và cảnh báo vắng; đây là chuẩn nghiệp vụ cần đối chiếu. |
| `web-checkin/src/main.js`, `duplicate_status.js` | Tham chiếu transaction điểm danh canonical, hash email, QR + checkout code, xử lý trùng và trạng thái đã được giáo viên ghi trước. |
| `web-checkin/src/leave.js` | Tham chiếu luồng xin nghỉ, tạo `studentAccess`, payload đơn và lịch sử đơn. Không port nguyên cách đọc tuần tự các document có thể chưa tồn tại. |
| `firestore.rules`, `firestore.indexes.json` | Điểm thiếu lớn nhất: sinh viên chưa có quyền discovery môn–lớp và chưa được query lịch sử phiên đã đóng. |
| `web-checkin/test/firestore.rules.test.mjs` | Có framework emulator allow/deny; phải mở rộng kiểm thử quyền cho mobile tại đây hoặc file test được script test thu nhận. |
| `apps-script/Code.gs`, `lib/services/apps_script_sheet_service.dart` | Firestore là dữ liệu gốc. Desktop đồng bộ Sheets, app sinh viên không gọi Apps Script và không chứa sync secret. |

### Các khoảng trống phải xử lý

- `courseClasses` chỉ cho giáo viên `list`; `students` hiện cũng chỉ cho giáo viên `list`. Sinh viên chỉ `get` được roster của mình khi đã biết lớp. App chưa có cách tự tìm môn theo email.
- Đọc course cho sinh viên hiện cần `courseClasses/{id}/studentAccess/{uid}` và roster còn active. `studentAccess` là liên kết UID với roster, **không phải nguồn cấp quyền độc lập** và không phải danh sách môn toàn cục.
- `attendanceSessions` chỉ cho sinh viên đọc trực tiếp phiên `active`; list và lịch sử phiên đã đóng chưa được cấp. Thiếu dữ liệu này không thể suy ra chính xác buổi chưa mở/chờ điểm danh/đã kết thúc.
- Canonical `records` cho sinh viên `get` theo email roster, nhưng không cho sinh viên `list`. Ưu tiên đọc đúng document của mình theo từng slot; không mở quyền đọc cả lớp.
- Rule `leaveRequests.get` dựa vào `resource.data.firebaseUid`. Đọc document chưa tồn tại có thể bị từ chối thay vì trả về “chưa có đơn”; web hiện đọc từng ID của mọi slot. Mobile nên query đơn của UID trong lớp, không dựa vào việc đọc các ID vắng mặt.
- Roster/check-in hiện so sánh `emailNormalized` với email nguyên gốc trong auth token, trong khi client normalize email. Phải thống nhất chuẩn hóa ở client và Rules; kiểm thử token có chữ hoa, không chỉ sửa UI.
- Một số quyền đọc trực tiếp hiện chưa kiểm tra `active`. Nếu chính sách mobile là thu hồi truy cập khi giáo viên ngừng học, phải cập nhật các nhánh Rules liên quan và kiểm tra OR giữa các match; thêm rule chặt hơn không tự vô hiệu rule rộng hiện có.
- Chưa có thư mục nền tảng Android/iOS trong repo đang review. Cần tạo app và cấu hình Firebase mobile riêng.

## 3. Quy tắc định danh và liên kết môn

```text
emailNormalized = trim(email).toLowerCase()
studentId = SHA256(UTF8(emailNormalized)).toString()  // hex lowercase 64 ký tự

courseClasses/{courseClassId}/students/{studentId}
```

Giữ công thức này tương thích với `AttendanceApi.importRoster`, `addCourseStudent` và web. Email là khóa nối roster với tài khoản Google; UID là định danh phiên đăng nhập/audit. MSSV và tên lấy từ roster giáo viên, không cho sinh viên tự nhập để nhận quyền.

- Giáo viên có thể thêm email trước khi sinh viên tạo tài khoản hoặc đăng nhập lần đầu.
- Một email được học nhiều môn, nhiều lớp, nhiều học kỳ và với nhiều giáo viên.
- ID lớp mới là auto ID, có `academicTerm`; lớp cũ có thể dùng ID kiểu `SUBJECT_CLASS`. Không suy ID lớp từ mã môn hoặc MSSV.
- `active: false` loại môn khỏi danh sách đang học và chặn thao tác mới. MVP thu hồi quyền dữ liệu lớp cho sinh viên inactive; lịch sử vẫn được giữ để giáo viên xem. Nếu muốn cho sinh viên xem lớp đã nghỉ, cần thiết kế quyền riêng, không bỏ kiểm tra active.
- Không bỏ dấu chấm hoặc phần `+tag` của email, không tự suy domain trường, không kết nối bằng display name.
- Đổi email là đổi khóa roster. Không tự đổi document ID hoặc chuyển attendance cũ; đây là migration riêng cần bảo toàn lịch sử.
- Khi gặp document legacy không tuân công thức hash, báo lỗi dữ liệu và đưa ra phương án migration; không đổi ID ngầm.

## 4. Kiến trúc và dữ liệu

### 4.1. Tách app sinh viên

Tạo cấu trúc tối thiểu:

```text
student-mobile/
  lib/
    main.dart
    app.dart
    config/
    models/
    repositories/
    services/
    screens/
    widgets/
  test/
  integration_test/
  android/
  ios/
  pubspec.yaml
  README.md
```

Dùng repository/service có thể inject Auth/Firestore và thay thế trong test. UI không trực tiếp dựng payload Firestore. Tách auth, discovery môn, lịch, điểm danh, đơn xin nghỉ. Chọn cách quản lý state đơn giản phù hợp repo; không thêm framework nếu không có nhu cầu.

Tái sử dụng quy tắc thuần Dart ở domain khi phù hợp. Nếu tách package chung, chỉ đưa logic không phụ thuộc desktop/IO vào đó và chạy lại test root; tránh refactor diện rộng chỉ để khởi tạo app mobile. Nếu sao chép một phần nhỏ cho MVP, ghi nguồn tham chiếu và thêm test đối chiếu quy tắc quan trọng.

Các cấu hình mobile chỉ chứa Firebase client config và URL công khai. Không đưa `firebase.desktop.json`, Apps Script secret hoặc Gemini key vào asset/build mobile. Bổ sung `.gitignore` cho output/cache/cấu hình local của app lồng trong repo; rule `/build/` hiện chỉ phủ build ở root.

### 4.2. Discovery môn theo roster hiện có

Hướng triển khai mặc định: collection-group query trên `students`, lọc đồng thời email của tài khoản và `active == true`. Không thêm bảng enrollment song song ở MVP vì roster đã là nguồn phân công môn.

```dart
firestore.collectionGroup('students')
  .where('emailNormalized', isEqualTo: emailNormalized)
  .where('active', isEqualTo: true)
```

Sau mỗi kết quả:

1. Kiểm tra document thuộc đúng dạng `courseClasses/{courseId}/students/{studentId}` và đúng studentId theo email.
2. Lấy courseId từ parent path; roster hiện không có sẵn trường `courseClassId`.
3. Đọc/tạo `studentAccess/{currentUid}` bằng dữ liệu roster đã xác minh và `serverTimestamp()` nếu chưa tồn tại.
4. Đọc course theo quyền hiện có; tổng hợp subject, classCode, academicTerm và schedule.
5. Nếu đã có access nhưng sai email/studentId, trả lỗi rõ ràng; không ghi đè vì Rules hiện chỉ cho create.

Đây là **thay đổi cần triển khai**, query chưa được Rules hiện tại cho phép. Bổ sung rule recursive phục vụ collection group với điều kiện Google user, email trùng token đã normalize và roster active. Chỉ cấp `list` cần thiết; không thêm write hoặc read toàn cục. Các collection tên `students` khác sẽ nằm trong phạm vi collection group: review namespace, chứng minh không lộ dữ liệu và không có đường ghi giả mạo; không coi kiểm tra path ở client là bảo mật. Nếu không bảo đảm được phạm vi bằng Rules/query, thay bằng chỉ mục enrollment do giáo viên ghi có schema/transaction/backfill rõ ràng, rồi cập nhật tài liệu quyết định trước khi code tiếp.

Khai báo index collection-group phục vụ cặp `emailNormalized + active` trong `firestore.indexes.json`. Kiểm tra index thực tế cần thiết thay vì chờ production báo thiếu index.

Đăng nhập lần đầu phải tìm được roster giáo viên đã thêm trước đó. Listener discovery phải nhận được môn mới và loại bỏ môn inactive. Hủy subscription, state và kết quả async cũ khi đổi tài khoản; không để dữ liệu của người trước hiển thị sang người sau.

### 4.3. Data contract giữ nguyên

| Path | Cách sử dụng cho mobile |
| --- | --- |
| `courseClasses/{courseId}` | Metadata môn–lớp và mảng `schedule`; đọc sau xác minh membership. |
| `courseClasses/{courseId}/students/{studentId}` | Email, MSSV, họ tên, active, attendancePolicy; sinh viên chỉ đọc chính mình. |
| `courseClasses/{courseId}/studentAccess/{uid}` | Bootstrap quyền đọc course, kiểm chứng lại roster active ở mỗi quyền phụ thuộc. |
| `attendanceSessions/{sessionId}` | Trạng thái mở/đóng, courseClassId, slot, slotKey, date; bổ sung đọc lịch sử trong lớp của mình. |
| `qrTokens/{token}` | Đọc trực tiếp token còn hạn; không list toàn bộ token. |
| `attendanceCheckoutCodes/{sessionId}` | Dữ liệu riêng giáo viên; sinh viên tuyệt đối không đọc. |
| `attendance/{courseId}/slots/{slotKey}/records/{studentId}` | Trạng thái cuối canonical, một document cho mỗi sinh viên/buổi. |
| `attendance/{courseId}/slots/{slotKey}/checkIns/{uid}` | Legacy chỉ đọc đúng UID để fallback khi canonical chưa có; không ghi mới. |
| `courseClasses/{courseId}/leaveRequests/{studentId}_{slot}` | Một đơn cho mỗi buổi; nhiều buổi tạo nhiều document. |

Không đổi tên collection, ID lớp, ID slot, công thức studentId, audit hoặc canonical records để phục vụ mobile. `slotKey` hiện là chuỗi số buổi (`"1"`, `"2"`...), không phải ngày hay daySlot.

## 5. Yêu cầu tính năng và giao diện

### 5.1. Đăng nhập và trang chính

- Google Sign-In với Firebase Auth và persistence phù hợp mobile. Người hủy đăng nhập quay về màn hình bình thường; thiếu cấu hình phải báo rõ.
- Hiển thị email đang dùng và khả năng đổi tài khoản; sinh viên không thấy màn hình quản trị giáo viên.
- Trang chính có lịch hôm nay, lối vào quét QR, các môn và đơn gần đây. Dùng điều hướng dưới phù hợp điện thoại: Trang chủ, Lịch học, Môn học, Đơn; quét QR là hành động nổi bật.
- Có loading, empty, error/retry, trạng thái mất mạng; không dùng dữ liệu mock làm kết quả thật.
- Chưa có môn: “Email này chưa được giảng viên thêm vào lớp” và nút tải lại/đổi tài khoản, không yêu cầu sinh viên tự tạo lớp.

### 5.2. Môn học và TKB

- Danh sách môn hiển thị mã môn, mã lớp, học kỳ và số buổi; tên môn/giáo viên/phòng học không có trong schema hiện tại thì không bịa ra.
- Lọc theo học kỳ; lớp cũ thiếu academicTerm hiển thị “Chưa có thông tin học kỳ”. Không gộp hai courseId vì trùng subject/classCode.
- TKB lấy từ `course.schedule` giáo viên đã lưu, không tự generate lại lịch từ preset. Việc dời buổi trên desktop phải phản ánh trên mobile.
- Hiển thị đúng ngày theo `Asia/Ho_Chi_Minh`, tuần từ thứ Hai đến Chủ nhật, phân biệt “Buổi 3/20” với “Slot 2”. Không để múi giờ thiết bị làm lệch ngày chuỗi `YYYY-MM-DD`.
- Nếu daySlot thiếu hoặc slot 6/7 chưa có giờ trong domain, hiển thị “Chưa có giờ cụ thể”. `slotDurationMinutes` và nhãn khung giờ có thể khác nhau, đặc biệt preset 90 phút; chỉ hiện giờ cụ thể đã xác định, không suy kết thúc bằng nhãn sai.
- Hai môn trùng khung giờ vẫn hiển thị cả hai và có dấu hiệu trùng lịch; không tự xóa hoặc gộp buổi.

### 5.3. Quét QR điểm danh

Luồng bắt buộc: mở camera → quét QR → xác minh token/phiên/roster → hiện môn và buổi → nhập mã xác nhận 5 ký tự → transaction ghi attendance → hiện kết quả từ server.

- Parse URL tương thích QR desktop `/check-in?t=<QR_TOKEN>`. Chỉ nhận HTTPS với host được cấu hình, path hợp lệ, đúng một token không rỗng và không chứa dấu `/`; không tự mở URL bất kỳ. Nếu thêm deep link ngoài camera, phải kiểm tra lại cùng parser.
- Chống callback camera lặp: tạm dừng scanner trong khi xử lý, khóa submit, cho quét lại khi QR hết hạn.
- Mã xác nhận trim/uppercase, pattern `^[A-Z0-9]{5}$`. Sinh viên nhập mã; không đọc document checkout để kiểm tra phía client.
- Port đúng transaction `writeCheckIn` trong web: đọc token, session, roster, canonical record; nếu tồn tại thì trả trạng thái hiện có, nếu chưa có mới create.
- Payload phải khớp whitelist trong `validStudentCheckIn`: ownerUid/firebaseUid/studentId/email/emailNormalized/studentCode/fullName/sessionId/courseClassId/subject/classCode/slot/slotKey/date/qrToken/checkoutCode, timestamps, updatedBy, `syncStatus: pending`, `attendanceStatus: present`, `recordSource: qr`, `revision: 1`.
- Tất cả trường danh tính lấy từ Auth/roster và lớp/buổi từ session đã đọc; timestamps dùng serverTimestamp. Không dùng đồng hồ thiết bị làm bằng chứng QR còn hạn.
- Rules quyết định TTL, generation và checkout code. Giữ cửa sổ chấp nhận mã trước 10 giây theo Rules hiện tại, không tự mở rộng.
- Không cập nhật record đã tồn tại. Nếu giáo viên đã ghi absent/excused, hiển thị đúng trạng thái và hướng liên hệ giáo viên; không báo “điểm danh thành công” hoặc ghi đè present.
- Lỗi ghi permission-denied có thể do phiên vừa đóng, QR hết hạn, code sai hoặc roster đổi: phân loại theo dữ liệu có thể kiểm chứng và dùng thông báo tổng quát khi chưa biết; không khẳng định mọi permission-denied là sai code.
- Mất mạng phải báo chưa xác nhận. Không xếp hàng điểm danh offline, không báo thành công do optimistic cache; retry đọc record để xử lý trường hợp server đã ghi nhưng client chưa nhận ACK.
- Xin camera permission đúng lúc, xử lý từ chối/vĩnh viễn từ chối, resume/background và giải phóng camera khi rời màn hình.

### 5.4. Điểm danh theo môn

Bổ sung quyền query `attendanceSessions` theo **một courseClassId được phép**, gồm cả active và stopped. Helper membership dựa trên studentAccess + email + roster active; không cấp list mọi phiên chỉ vì có Google login. Index/query và Rules phải được kiểm tra bằng emulator với truy vấn thật của app.

Với mỗi buổi, đọc canonical document của studentId; chỉ fallback legacy document của UID hiện tại nếu canonical không tồn tại. Canonical luôn thắng khi cả hai tồn tại. Không query cả roster hoặc toàn bộ records để lọc phía client.

| Dữ liệu | Trạng thái hiển thị |
| --- | --- |
| Có canonical record | present → Có mặt; absent → Vắng; excused → Có phép. |
| Chưa có canonical, có legacy check-in của UID | Có mặt theo dữ liệu legacy, không nhân đôi với canonical. |
| Không record, có phiên active cho buổi | Chờ điểm danh. |
| Không record, từng có phiên và tất cả đã đóng | Vắng theo suy luận nghiệp vụ của desktop, không tự tạo record vắng từ mobile. |
| Không record, chưa có phiên | Chưa mở điểm danh, kể cả ngày trên lịch đã qua. |
| Thiếu quyền/mất mạng/không tải được session | Chưa xác định; không suy ra Vắng hoặc Chưa mở. |

Khi có nhiều phiên cùng slot: bất kỳ phiên active nào làm slot active; nếu không active và có lịch sử phiên thì completed. Chính sách `alwaysExcused` hoặc đơn approved chưa được desktop materialize không được mobile biến thành record excused; hiển thị chính sách/đơn riêng và chờ dữ liệu canonical.

Thống kê bám `CourseOverview`:

- Đếm present/absent/excused chính thức trên các buổi completed; buổi active hiển thị trạng thái nhưng chưa vào thống kê chính thức.
- Tỷ lệ tham dự = present / (completed − excused); nếu mẫu số bằng 0, hiển thị “Chưa có dữ liệu tính tỷ lệ”.
- Tỷ lệ vắng = absent / tổng số buổi trong lịch môn; cảnh báo khi absent × 10 ≥ tổng số buổi, nguy cơ khi absent × 5 > tổng số buổi. Đây là quy tắc app hiện có, không khẳng định là quyết định cấm thi của trường.
- Roster inactive/alwaysExcused không áp dụng cảnh báo vắng theo quy tắc hiện tại.
- Không dùng tỷ lệ tham dự dưới 80% thay thế quy tắc cảnh báo theo tổng số buổi; trong desktop hai chỉ số có mục đích khác nhau.

Chỉ subscribe dữ liệu môn đang mở và số lượng cần cho trang chính; giới hạn số request đồng thời, giải phóng listener khi chuyển môn. Lỗi một môn không làm biến mất mọi môn khác. Không ghi thông tin QR/code riêng vào log phân tích hoặc UI lịch sử.

### 5.5. Gửi và theo dõi đơn

- Chọn môn của mình, một/nhiều buổi tương lai, lý do trim 10–1000 ký tự.
- Giữ chính sách UI web hiện tại: chỉ buổi có `date` lớn hơn ngày hôm nay tại Việt Nam. Rule hiện kiểm tra `slotDate = date + T00:00:00Z` và `slotDate > request.time`; không diễn giải slotDate là giờ bắt đầu thực của buổi và không âm thầm đổi semantics UTC.
- Payload như `leave.js`: ownerUid, courseClassId, studentId, firebaseUid, emailNormalized, slot, date, slotDate, reason, `status: pending`, createdAt serverTimestamp.
- ID `${studentId}_${slot}`; một buổi chỉ có một đơn, kể cả đơn bị từ chối. MVP không thêm sửa/xóa/rút/gửi lại đơn khi Rules chưa hỗ trợ.
- Gửi nhiều buổi bằng batch khi còn trong giới hạn hoặc chia chunk có kết quả rõ ràng. Không báo tất cả thành công nếu chỉ ghi một phần; tránh ghi đè đơn đã tồn tại khi retry.
- Query theo `firebaseUid == currentUid` trong `leaveRequests` của lớp đã được phép; đồng thời siết quyền với membership active. Có thể sort lịch sử trên client để giảm index cho MVP.
- Tổng hợp đơn giữa các lớp bằng query từng lớp đã discovery, tránh mở collection group leaveRequests toàn cục nếu chưa cần.
- Hiển thị pending/approved/rejected, lý do, buổi/ngày, phản hồi và thời điểm quyết định nếu có. Cập nhật khi giáo viên duyệt hoặc từ chối.
- Approved là quyết định đơn, không tự sửa điểm danh: desktop chỉ materialize excused khi mở buổi và giữ record thực tế nếu đã có xung đột.

## 6. Firestore Rules và kiểm thử quyền

Rules là một phần bắt buộc của task. Liệt kê mọi query mobile, điều kiện filter và nhánh rule/index tương ứng; Rules không phải bộ lọc kết quả.

Giữ quyền giáo viên và quyền web hiện tại trong phạm vi cần thiết. Đặc biệt kiểm tra helper chuẩn hóa email được dùng nhất quán ở discovery, access, course get, session list, attendance create/get và leave create/list; yêu cầu Google provider như hiện có. Không mở Email/Password cho sinh viên chỉ để tránh cấu hình Google.

Các test allow/deny tối thiểu:

1. Discovery chỉ trả roster active của email đang đăng nhập; fail khi query thiếu filter, query email khác, tài khoản anonymous hoặc provider không được phép.
2. Email hoa/thường, khoảng trắng nhập roster và hash cho kết quả nhất quán; không normalize vượt trim/lowercase.
3. Sinh viên có môn do nhiều giáo viên thêm, thêm trước lần đăng nhập đầu; danh sách và access bootstrap đúng.
4. Không đọc roster người khác, whole-class attendance, import, code claims, checkout codes, audit riêng giáo viên hoặc lớp ngoài membership.
5. studentAccess giả mạo email/studentId/UID hoặc liên kết roster inactive bị chặn; access cũ không duy trì quyền khi roster inactive.
6. Query session đúng course được phép đọc lịch sử; course khác và query toàn bộ phiên bị chặn.
7. Điểm danh hợp lệ thành công; QR hết hạn, session stopped, code sai/hết hạn, token không khớp session, giả mạo danh tính bị chặn; previous code đúng cửa sổ được xử lý như Rules hiện tại.
8. Hai request điểm danh đồng thời chỉ tạo một record; sinh viên không update/delete record; absent/excused có trước được giữ nguyên.
9. Đơn hợp lệ thành công; lý do ngắn/dài, slot/date sai, ngày không hợp lệ, duplicate, quyết định giả mạo đều bị chặn. Query lịch sử không cần đọc document chưa có.
10. Ngừng học trong khi app đang mở chặn các lần đọc/ghi mới; hủy listener và xóa state UI của lớp. Cache cũ không được coi là chứng minh còn quyền.
11. Quyền giáo viên tạo môn/import roster/dời lịch/mở-dừng phiên/duyệt đơn/chỉnh điểm danh/sync Sheets không bị hồi quy.

Không đổi TTL QR, quyền checkout hoặc audit để làm test mobile dễ pass. Viết fixture có schedule/roster/session đầy đủ, kiểm thử query đúng SDK thay vì chỉ get một document.

## 7. Thứ tự thực hiện

### Task A — Chốt data contract và quyền đọc

- [ ] Đọc lại các file ở mục 2 và ghi khác biệt so với bản review nếu repo đã thay đổi.
- [ ] Thêm test discovery và membership, chuẩn hóa email, quyền lịch sử phiên và đơn.
- [ ] Triển khai Rules/indexes tương ứng, giữ dữ liệu/ID cũ.
- [ ] Kiểm tra group query trước khi dựng UI phụ thuộc; không cần backfill roster nếu dùng hướng mặc định và dữ liệu đúng schema.

Hoàn thành khi emulator chứng minh query app được allow đúng phạm vi và truy cập chéo bị deny.

### Task B — App nền tảng, đăng nhập và môn học

- [ ] Tạo `student-mobile`, cấu hình Firebase mobile và Google login.
- [ ] Viết repository discovery + access bootstrap, màn hình empty/error/account switch.
- [ ] Danh sách môn và chi tiết dùng dữ liệu thật; listener nhận thêm/ngừng môn.
- [ ] Bổ sung cấu hình ví dụ không có secret, `.gitignore` và hướng dẫn thiết lập.

Hoàn thành khi giáo viên thêm email trước lần đăng nhập đầu và sinh viên thấy đúng các môn khi đăng nhập.

### Task C — TKB và lịch sử điểm danh

- [ ] TKB ngày/tuần, học kỳ, lịch đã dời, thiếu daySlot và trùng lịch.
- [ ] Query phiên được phép, đọc records của mình, fallback legacy có kiểm soát.
- [ ] Trạng thái buổi và thống kê/cảnh báo khớp domain desktop.

Hoàn thành khi dữ liệu mobile và desktop đối chiếu đúng cả buổi active, completed, chưa mở và excused.

### Task D — Quét và ghi điểm danh

- [ ] Camera permission/lifecycle và parser URL.
- [ ] Xác minh QR + nhập checkout code + transaction canonical.
- [ ] Chặn scan/submit lặp, xử lý lỗi/race/mất ACK và record có trước.

Hoàn thành khi dùng QR desktop thật ghi một record đúng, desktop nhận realtime và giữ luồng sync Sheets hiện có.

### Task E — Đơn xin nghỉ

- [ ] Form chọn buổi, validation, ghi đơn và lịch sử riêng.
- [ ] Trạng thái/phản hồi cập nhật từ giáo viên; xử lý duplicate và submit nhiều buổi.
- [ ] Kiểm chứng approved chỉ materialize theo desktop khi mở phiên.

Hoàn thành khi sinh viên gửi đơn, giáo viên desktop duyệt/từ chối và mobile hiện đúng kết quả.

### Task F — Nghiệm thu và bàn giao

- [ ] Unit test nghiệp vụ/hash/parser/thống kê/timezone.
- [ ] Widget test auth/empty/error/đổi tài khoản/trạng thái điểm danh/đơn.
- [ ] Emulator integration test Rules và test repository với query thực tế.
- [ ] Android analyze/test/build và kiểm tra thiết bị camera/Google login.
- [ ] Chạy kiểm tra root/web liên quan; ghi chính xác phần chưa chạy.
- [ ] Hướng dẫn thiết lập/build/test/deploy, thay đổi schema/index và rollout.

## 8. Tiêu chí nghiệm thu đầu cuối

Dùng ít nhất hai giáo viên, hai sinh viên và ba môn–lớp ở hai học kỳ; có môn trùng mã nhưng khác courseId.

1. Giáo viên thêm/import email A vào hai môn, email B vào môn còn lại. A/B đăng nhập chỉ thấy môn tương ứng, kể cả roster tồn tại trước tài khoản.
2. Giáo viên thêm môn hoặc dời lịch khi app mở: danh sách/TKB cập nhật. Tắt active của A trong một lớp: lớp bị gỡ khỏi UI và thao tác mới bị từ chối.
3. Sinh viên A quét QR của lớp mình, nhập code đúng, desktop thấy attendance canonical. Quét lần nữa không tạo thêm record; quét lớp của B bị từ chối.
4. QR hết hạn, code sai, session vừa đóng và máy mất mạng đều không hiện thành công giả.
5. Sinh viên xem present/absent/excused/pending/chưa mở đúng từng buổi, không đọc dữ liệu B; thống kê đúng khi có buổi excused và khi chưa completed buổi nào.
6. Sinh viên gửi đơn nhiều buổi, giáo viên quyết định, mobile thấy phản hồi. Record excused được desktop tạo đúng lúc và không ghi đè attendance thực tế.
7. Đổi Google account trong app không giữ môn/lịch/đơn của tài khoản cũ.
8. Bản Android chạy được trên thiết bị; đăng nhập và camera hoạt động sau resume. Phần iOS chưa xác minh được phải được nêu rõ.

## 9. Lệnh kiểm tra và cấu hình triển khai

Tại root, dùng Flutter/Firebase CLI thực tế trong môi trường (Windows có thể cần `flutter.bat`, `firebase.cmd`, `npm.cmd`):

```powershell
flutter.bat analyze
flutter.bat test
npm.cmd --prefix web-checkin run build
firebase.cmd emulators:exec --only firestore --project demo-fap-checkin-rules "npm.cmd --prefix web-checkin run test:rules"
```

Tại `student-mobile/` sau khi triển khai:

```powershell
flutter.bat pub get
flutter.bat analyze
flutter.bat test
flutter.bat build apk --debug
```

Agent bổ sung lệnh cấu hình mobile và emulator integration phù hợp với implementation cuối. Chỉ chốt version package Google login/scanner sau khi kiểm tra tài liệu chính thức và khả năng tương thích SDK của môi trường; không suy version từ web hoặc dùng API nhớ từ phiên bản cũ.

Firebase cần đăng ký Android/iOS app đúng package/bundle ID, Google Sign-In provider, Android SHA fingerprints và iOS URL scheme/config tương ứng. Nếu thiếu quyền Console hoặc signing config, vẫn hoàn thiện code, sample config và emulator tests; báo đúng thông tin còn thiếu, không coi Google login đã được nghiệm thu. Không lấy appId desktop làm appId Android.

Khi rollout được cho phép, dùng `tool/deploy_firestore.ps1` cho Rules/indexes; script này **có deploy production**, không dùng như lệnh test trong quá trình phát triển. Nghiệm thu emulator trước, deploy Rules/indexes tương thích trước khi phát hành mobile. Không tự nâng billing, deploy production, publish store hoặc migration dữ liệu chỉ từ tài liệu này.

## 10. Yêu cầu bàn giao của agent

Agent phải triển khai từng task đến mức chạy/kiểm tra được, không dừng ở skeleton hoặc mock UI. Bàn giao mã app, Rules/indexes/tests cần thiết, README setup mobile và báo cáo ngắn gồm:

- Chức năng đã hoàn thành và file chính.
- Quyết định discovery/membership và ảnh hưởng đến desktop/web.
- Lệnh đã chạy, kết quả thật, thiết bị đã kiểm tra.
- Cấu hình Firebase/signing cần người sở hữu project cung cấp.
- Giới hạn còn lại, đặc biệt iOS, data legacy và chức năng ngoài MVP.

Prompt dùng trực tiếp:

> Đọc `docs/STUDENT_MOBILE_APP_AGENT_TASK.md` và các file nguồn được chỉ ra. Triển khai app Flutter sinh viên trong `student-mobile/` theo thứ tự Task A–F, dùng Firestore hiện có và email roster làm khóa nối. Hoàn thành đăng nhập Google, discovery môn, TKB, QR + checkout code, lịch sử điểm danh theo môn và đơn xin nghỉ. Giữ canonical records, quyền giáo viên và web tương thích; bổ sung Rules/indexes cùng test allow/deny bằng emulator. Kiểm tra Android, báo rõ các cấu hình hoặc kiểm tra chưa thực hiện được. Không deploy production hoặc publish app store khi chưa được giao việc đó.
