import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// Kết quả trích xuất một sinh viên từ OCR.
class OcrStudentItem {
  const OcrStudentItem({
    required this.studentCode,
    required this.fullName,
    required this.email,
  });

  factory OcrStudentItem.fromJson(Map<String, dynamic> json) {
    return OcrStudentItem(
      studentCode: (json['studentCode'] ?? json['mssv'] ?? '')
          .toString()
          .trim(),
      fullName: (json['fullName'] ?? json['hoten'] ?? json['name'] ?? '')
          .toString()
          .trim(),
      email: (json['email'] ?? '').toString().trim(),
    );
  }

  final String studentCode;
  final String fullName;
  final String email;

  Map<String, String> toMap() => {
    'studentCode': studentCode,
    'fullName': fullName,
    'email': email,
  };
}

/// Một ô môn học đọc được từ ảnh lịch trong tuần. Các trường có thể thiếu
/// phải được giảng viên kiểm tra trong form tạo môn–lớp.
class OcrTimetableItem {
  const OcrTimetableItem({
    required this.subject,
    required this.classCode,
    this.date,
    this.daySlot,
    this.sessionNumber,
    this.totalSessions,
  });

  final String subject;
  final String classCode;
  final DateTime? date;
  final int? daySlot;
  final int? sessionNumber;
  final int? totalSessions;
}

/// Cấu hình OCR được đọc từ file cục bộ, nằm ngoài bản build và Git.
abstract final class GeminiOcrSettings {
  static String apiKey = '';
  static String model = 'gemini-3.5-flash-lite';
  static File? _loadedFile;
  static const _selectableModels = {
    'gemini-3.5-flash-lite',
    'gemini-3.1-flash-lite',
    'gemini-3.8-flash',
    'gemini-2.5-flash',
  };

  static File get _defaultFile {
    if (File('pubspec.yaml').existsSync()) return File('gemini.local.json');
    if (Platform.isWindows) {
      final appData = Platform.environment['APPDATA'];
      if (appData != null && appData.isNotEmpty) {
        return File('$appData\\FapCheckAttendance\\gemini.local.json');
      }
    }
    final home = Platform.environment['HOME'];
    if (home != null && home.isNotEmpty) {
      return File('$home/.config/fap-check-attendance/gemini.local.json');
    }
    return File('gemini.local.json');
  }

  static Future<void> loadLocalConfig() async {
    final executableFile = File(
      '${File(Platform.resolvedExecutable).parent.path}${Platform.pathSeparator}gemini.local.json',
    );
    for (final file in <File>[
      _defaultFile,
      File('gemini.local.json'),
      executableFile,
    ]) {
      if (!await file.exists()) continue;
      try {
        final data = jsonDecode(await file.readAsString());
        if (data is! Map<String, dynamic>) continue;
        final key = (data['GEMINI_API_KEY'] ?? '').toString().trim();
        if (key.isEmpty || key.startsWith('replace-with-')) continue;
        apiKey = key;
        final selectedModel = (data['GEMINI_MODEL'] ?? '').toString().trim();
        if (_selectableModels.contains(selectedModel)) model = selectedModel;
        _loadedFile = file;
        return;
      } on FormatException {
        // File sai định dạng sẽ được thay bằng cấu hình nhập trong ứng dụng.
      } on FileSystemException {
        // Có thể đọc file khác hoặc nhập lại key trong ứng dụng.
      }
    }
  }

  static Future<void> saveLocalConfig(String key, String selectedModel) async {
    final file = _loadedFile ?? _defaultFile;
    await file.parent.create(recursive: true);
    await file.writeAsString(
      '${jsonEncode({'GEMINI_API_KEY': key.trim(), 'GEMINI_MODEL': selectedModel})}\n',
    );
    apiKey = key.trim();
    model = selectedModel;
    _loadedFile = file;
  }

  static String get localConfigPath =>
      (_loadedFile ?? _defaultFile).absolute.path;
}

/// Service giao tiếp với Google Gemini Vision API để quét và trích xuất
/// danh sách sinh viên từ ảnh chụp màn hình FAP hoặc bảng danh sách lớp.
///
/// Hỗ trợ đa nền tảng: Windows, macOS, Android, iOS, Web.
class GeminiOcrService {
  GeminiOcrService({
    http.Client? client,
    this.apiKey,
    this.defaultModel = 'gemini-3.5-flash-lite',
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null;

  final http.Client _client;
  final bool _ownsClient;
  final String? apiKey;
  final String defaultModel;

  void close() {
    if (_ownsClient) _client.close();
  }

  /// Các model gọn để thử khi model đã chọn bị giới hạn lượt gọi.
  static const List<String> supportedModels = [
    'gemini-3.5-flash-lite',
    'gemini-3.1-flash-lite',
  ];

  static const String _timetablePrompt = '''
Đọc ảnh chụp màn hình "Lịch trong tuần" của ứng dụng điểm danh.
Mỗi ô có thể chứa mã môn, mã lớp, "Buổi x/y". Cột cho biết ngày (thứ/ngày/tháng), hàng cho biết Slot 1–7.
Trả về JSON array, mỗi ô môn học một object:
[{"subject":"PRM393","classCode":"SE1801","date":"2026-09-28","weekday":1,"daySlot":2,"sessionNumber":1,"totalSessions":20}]
Nếu ảnh chỉ ghi ngày/tháng, date dùng "dd/MM" (ví dụ "25/10"); không tự đoán năm. weekday là Thứ 2=1 đến Chủ nhật=7 nếu nhìn thấy, nếu không thì null. Tổng số buổi có thể là 10, 20 hoặc 30; lấy từ mẫu "Buổi x/y" khi nhìn thấy. Chỉ chép dữ liệu nhìn thấy. Nếu không thấy ngày, slot, số buổi hoặc tổng buổi, đặt trường tương ứng null. Không đoán ngày bắt đầu khóa học, học kỳ hay các buổi ngoài ảnh; ứng dụng sẽ tự suy ra từ dữ liệu đọc được. Không lấy ô trống, tiêu đề, nút bấm hoặc nhãn "Chưa xếp slot". Chỉ trả JSON.
''';

  static const String _systemPrompt = '''
Bạn là chuyên gia trích xuất dữ liệu học vụ từ ảnh chụp màn hình FAP (FPT Academic Portal) hoặc bảng danh sách lớp học.
Nhiệm vụ: Trích xuất danh sách sinh viên xuất hiện trong ảnh thành mảng JSON thuần túy.

Định dạng JSON trả về phải là một mảng các đối tượng với đúng các trường sau:
[
  {
    "studentCode": "SE183571",
    "fullName": "Nguyễn Ngọc Tường Vy",
    "email": "VyNNTSE183571@fpt.edu.vn"
  }
]

Quy tắc bắt buộc:
1. "studentCode": Mã số sinh viên (MSSV, RollNumber, StudentID), viết in hoa toàn bộ, không có khoảng trắng thừa (ví dụ: SE183571, SA180123).
2. "fullName": Họ và tên sinh viên đầy đủ, giữ nguyên dấu tiếng Việt chuẩn xác (ví dụ: Nguyễn Ngọc Tường Vy, Đặng Đình Long).
3. "email": Chỉ chép email hiện rõ trong ảnh. Nếu không có cột email hoặc không đọc được, trả chuỗi rỗng; tuyệt đối không suy đoán địa chỉ.
4. Đọc cẩn thận từng dòng trong bảng, không bỏ sót sinh viên nào.
5. Chỉ trả về mã JSON hợp lệ (mảng JSON), KHÔNG viết thêm bất kỳ lời chào, giải thích hoặc định dạng markdown nào khác ngoài JSON.
''';

  /// Quét ảnh và trả về danh sách [OcrStudentItem].
  ///
  /// Nếu [apiKey] không được truyền vào hàm, service sẽ dùng [this.apiKey].
  /// Có hỗ trợ tự động thử model dự phòng nếu model chính bị quá tải / Rate Limit (429).
  Future<List<OcrStudentItem>> scanStudentsFromImage({
    required Uint8List imageBytes,
    String mimeType = 'image/png',
    String? explicitApiKey,
    String? modelName,
    bool enableFallback = true,
  }) async {
    final rawText = await _scanImage(
      imageBytes: imageBytes,
      mimeType: mimeType,
      explicitApiKey: explicitApiKey,
      modelName: modelName,
      enableFallback: enableFallback,
      prompt: _systemPrompt,
    );
    return parseOcrJson(rawText);
  }

  Future<List<OcrTimetableItem>> scanTimetableFromImage({
    required Uint8List imageBytes,
    String mimeType = 'image/png',
    String? explicitApiKey,
    String? modelName,
  }) async {
    final rawText = await _scanImage(
      imageBytes: imageBytes,
      mimeType: mimeType,
      explicitApiKey: explicitApiKey,
      modelName: modelName,
      enableFallback: true,
      prompt: _timetablePrompt,
    );
    return parseTimetableJson(rawText);
  }

  Future<String> _scanImage({
    required Uint8List imageBytes,
    required String mimeType,
    String? explicitApiKey,
    String? modelName,
    required bool enableFallback,
    required String prompt,
  }) async {
    final key = (explicitApiKey ?? apiKey ?? '').trim();
    if (key.isEmpty) {
      throw const FormatException(
        'Chưa có Gemini API key. Hãy nhập key trong phần cấu hình AI.',
      );
    }

    final targetModel = modelName ?? defaultModel;
    final modelsToTry = [
      targetModel,
      if (enableFallback) ...supportedModels.where((m) => m != targetModel),
    ];

    String? lastErrorMessage;

    for (final model in modelsToTry) {
      try {
        final result = await _callGeminiApi(
          imageBytes: imageBytes,
          mimeType: mimeType,
          apiKey: key,
          modelName: model,
          prompt: prompt,
        );
        return result;
      } on GeminiRateLimitException catch (e) {
        lastErrorMessage = e.message;
        // Nếu bị Rate Limit (429) và còn model dự phòng thì tiếp tục thử model tiếp theo
        if (!enableFallback || model == modelsToTry.last) {
          rethrow;
        }
      } catch (e) {
        lastErrorMessage = e.toString();
        // Nếu lỗi không phải do Rate Limit (như ảnh lỗi, mạng hỏng, 401...) thì ném lỗi ngay
        rethrow;
      }
    }

    throw FormatException(
      lastErrorMessage ?? 'Không thể nhận diện dữ liệu từ ảnh.',
    );
  }

  Future<String> _callGeminiApi({
    required Uint8List imageBytes,
    required String mimeType,
    required String apiKey,
    required String modelName,
    required String prompt,
  }) async {
    final url = Uri.parse(
      'https://generativelanguage.googleapis.com/v1beta/models/$modelName:generateContent',
    );

    final base64Image = base64Encode(imageBytes);

    final requestBody = {
      'contents': [
        {
          'parts': [
            {'text': prompt},
            {
              'inline_data': {'mime_type': mimeType, 'data': base64Image},
            },
          ],
        },
      ],
      'generationConfig': {
        'temperature': 0.1,
        'response_mime_type': 'application/json',
      },
    };

    final response = await _client
        .post(
          url,
          headers: {
            'Content-Type': 'application/json',
            'x-goog-api-key': apiKey,
          },
          body: jsonEncode(requestBody),
        )
        .timeout(const Duration(seconds: 60));

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final rawText = _extractTextFromResponse(data);
      return rawText;
    }

    if (response.statusCode == 429) {
      throw GeminiRateLimitException(
        'Model $modelName đã đạt giới hạn yêu cầu (Rate Limit - HTTP 429). Bạn có thể đổi sang model khác hoặc thử lại sau ít phút.',
      );
    }

    if (response.statusCode == 400) {
      throw FormatException(
        'Yêu cầu không hợp lệ hoặc định dạng ảnh không được hỗ trợ (HTTP 400).',
      );
    }

    if (response.statusCode == 401 || response.statusCode == 403) {
      throw const FormatException(
        'Gemini API key không hợp lệ hoặc tài khoản không có quyền truy cập API này (HTTP 401/403).',
      );
    }

    throw FormatException(
      'Lỗi từ máy chủ Gemini (HTTP ${response.statusCode}).',
    );
  }

  String _extractTextFromResponse(Map<String, dynamic> data) {
    final candidates = data['candidates'] as List<dynamic>?;
    if (candidates == null || candidates.isEmpty) {
      throw const FormatException(
        'AI không trả về kết quả nào cho bức ảnh này.',
      );
    }
    final firstCandidate = candidates.first as Map<String, dynamic>;
    final content = firstCandidate['content'] as Map<String, dynamic>?;
    final parts = content?['parts'] as List<dynamic>?;
    if (parts == null || parts.isEmpty) {
      throw const FormatException('Nội dung phản hồi từ AI bị rỗng.');
    }
    final text = parts.first['text'] as String?;
    if (text == null || text.trim().isEmpty) {
      throw const FormatException(
        'Không tìm thấy văn bản trích xuất trong ảnh.',
      );
    }
    return text.trim();
  }

  /// Phân tích chuỗi JSON trả về từ AI thành danh sách [OcrStudentItem].
  static List<OcrStudentItem> parseOcrJson(String rawText) {
    final decoded = _decodeOcrJson(rawText);
    return decoded
        .whereType<Map<String, dynamic>>()
        .map((item) => OcrStudentItem.fromJson(item))
        .where(
          (item) => item.studentCode.isNotEmpty || item.fullName.isNotEmpty,
        )
        .toList();
  }

  static List<OcrTimetableItem> parseTimetableJson(
    String rawText, {
    DateTime? referenceDate,
  }) {
    final rows = _decodeOcrJson(rawText);
    final reference = referenceDate ?? DateTime.now();
    final positions = <String, int>{};
    final result = <OcrTimetableItem>[];
    for (final row in rows.whereType<Map<String, dynamic>>()) {
      final subject = (row['subject'] ?? '').toString().trim().toUpperCase();
      final classCode = (row['classCode'] ?? '')
          .toString()
          .trim()
          .toUpperCase();
      if (subject.isEmpty && classCode.isEmpty) continue;
      final dateText = row['date']?.toString().trim();
      final weekday = int.tryParse('${row['weekday'] ?? ''}');
      final date = _parseTimetableDate(dateText, reference, weekday);
      final slot = int.tryParse('${row['daySlot'] ?? ''}');
      final item = OcrTimetableItem(
        subject: subject,
        classCode: classCode,
        date: date,
        daySlot: slot != null && slot >= 1 && slot <= 7 ? slot : null,
        sessionNumber: int.tryParse('${row['sessionNumber'] ?? ''}'),
        totalSessions: int.tryParse('${row['totalSessions'] ?? ''}'),
      );
      if (subject.isNotEmpty && classCode.isNotEmpty) {
        final key = '$subject|$classCode';
        final previousIndex = positions[key];
        if (previousIndex != null) {
          final previous = result[previousIndex];
          final useCurrent =
              (previous.date == null && item.date != null) ||
              (previous.date == null &&
                  item.date == null &&
                  previous.daySlot == null &&
                  item.daySlot != null) ||
              ((previous.date == null) == (item.date == null) &&
                  item.sessionNumber != null &&
                  (previous.sessionNumber == null ||
                      item.sessionNumber! < previous.sessionNumber!));
          final selected = useCurrent ? item : previous;
          result[previousIndex] = OcrTimetableItem(
            subject: selected.subject,
            classCode: selected.classCode,
            date: selected.date,
            daySlot: selected.daySlot,
            sessionNumber: selected.sessionNumber,
            totalSessions:
                selected.totalSessions ??
                (useCurrent ? previous.totalSessions : item.totalSessions),
          );
          continue;
        }
        positions[key] = result.length;
      }
      result.add(item);
    }
    return result;
  }

  static DateTime? _parseTimetableDate(
    String? text,
    DateTime reference,
    int? weekday,
  ) {
    if (text == null || text.isEmpty) return null;
    final iso = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(text);
    if (iso != null) {
      return _validTeachingDate(
        int.parse(iso[1]!),
        int.parse(iso[2]!),
        int.parse(iso[3]!),
      );
    }
    final short = RegExp(r'^(\d{1,2})/(\d{1,2})$').firstMatch(text);
    if (short == null) return null;
    final day = int.parse(short[1]!);
    final month = int.parse(short[2]!);
    final candidates = <DateTime>[
      for (final year in [
        reference.year - 1,
        reference.year,
        reference.year + 1,
      ])
        ?_validTeachingDate(year, month, day),
    ];
    final choices = weekday != null && weekday >= 1 && weekday <= 7
        ? candidates.where((date) => date.weekday == weekday).toList()
        : candidates;
    if (choices.isEmpty) return null;
    choices.sort((left, right) {
      final leftDistance = left.difference(reference).inDays.abs();
      final rightDistance = right.difference(reference).inDays.abs();
      return leftDistance.compareTo(rightDistance);
    });
    return choices.first;
  }

  static DateTime? _validTeachingDate(int year, int month, int day) {
    if (year < 2020 ||
        year > 2100 ||
        month < 1 ||
        month > 12 ||
        day < 1 ||
        day > 31) {
      return null;
    }
    final date = DateTime(year, month, day);
    return date.year == year &&
            date.month == month &&
            date.day == day &&
            date.weekday != DateTime.sunday
        ? date
        : null;
  }

  static List<dynamic> _decodeOcrJson(String rawText) {
    var cleaned = rawText.trim();
    // Bỏ code block markdown nếu có ```json ... ```
    if (cleaned.startsWith('```')) {
      final startIndex = cleaned.indexOf('[');
      final endIndex = cleaned.lastIndexOf(']');
      if (startIndex != -1 && endIndex != -1 && endIndex > startIndex) {
        cleaned = cleaned.substring(startIndex, endIndex + 1);
      } else {
        cleaned = cleaned.replaceAll(RegExp(r'^```[a-zA-Z]*\n?'), '');
        cleaned = cleaned.replaceAll(RegExp(r'\n?```$'), '');
      }
    }

    dynamic decoded;
    try {
      decoded = jsonDecode(cleaned);
    } catch (_) {
      // Tìm mảng JSON bên trong chuỗi
      final start = cleaned.indexOf('[');
      final end = cleaned.lastIndexOf(']');
      if (start != -1 && end != -1 && end > start) {
        decoded = jsonDecode(cleaned.substring(start, end + 1));
      } else {
        throw const FormatException(
          'AI không trả về đúng định dạng danh sách JSON.',
        );
      }
    }

    final List<dynamic> itemsList;
    if (decoded is List) {
      itemsList = decoded;
    } else if (decoded is Map<String, dynamic>) {
      // Một số trường hợp AI bọc trong {"students": [...]}
      final possibleKey = decoded.keys.firstWhere(
        (k) => decoded[k] is List,
        orElse: () => '',
      );
      if (possibleKey.isNotEmpty) {
        itemsList = decoded[possibleKey] as List<dynamic>;
      } else {
        throw const FormatException(
          'Không tìm thấy danh sách sinh viên trong JSON phản hồi.',
        );
      }
    } else {
      throw const FormatException('Định dạng JSON trích xuất không hợp lệ.');
    }

    return itemsList;
  }
}

class GeminiRateLimitException implements Exception {
  const GeminiRateLimitException(this.message);
  final String message;

  @override
  String toString() => message;
}
