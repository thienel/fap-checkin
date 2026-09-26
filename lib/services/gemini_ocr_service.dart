import 'dart:convert';
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
      studentCode: (json['studentCode'] ?? json['mssv'] ?? '').toString().trim(),
      fullName: (json['fullName'] ?? json['hoten'] ?? json['name'] ?? '').toString().trim(),
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

/// Service giao tiếp với Google Gemini Vision API để quét và trích xuất
/// danh sách sinh viên từ ảnh chụp màn hình FAP hoặc bảng danh sách lớp.
///
/// Hỗ trợ đa nền tảng: Windows, macOS, Android, iOS, Web.
class GeminiOcrService {
  GeminiOcrService({
    http.Client? client,
    this.apiKey,
    this.defaultModel = 'gemini-3.5-flash-lite',
  }) : _client = client ?? http.Client();

  final http.Client _client;
  final String? apiKey;
  final String defaultModel;

  /// Danh sách các model Gemini được hỗ trợ và có Free Tier tại Google AI Studio.
  static const List<String> supportedModels = [
    'gemini-3.5-flash-lite',
    'gemini-3.1-flash-lite',
    'gemini-3.8-flash',
    'gemini-3.5-flash',
    'gemini-2.5-flash',
    'gemini-2.5-flash-lite',
  ];

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
3. "email": 
   - Nếu trong ảnh có cột email (dù là đuôi @fpt.edu.vn hay @gmail.com hay domain khác), hãy lấy CHÍNH XÁC email đó.
   - Nếu trong ảnh KHÔNG có cột email, hãy tự suy luận email FPT theo cú pháp: <Tên + Chữ lót viết tắt><MSSV>@fpt.edu.vn (ví dụ họ tên: "Nguyễn Ngọc Tường Vy", MSSV: "SE183571" -> "VyNNTSE183571@fpt.edu.vn").
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
    final key = (explicitApiKey ?? apiKey ?? '').trim();
    if (key.isEmpty) {
      throw const FormatException(
        'Chưa cấu hình GEMINI_API_KEY. Vui lòng cung cấp API key trong cài đặt hoặc firebase.desktop.json.',
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
      lastErrorMessage ?? 'Không thể nhận diện danh sách từ ảnh.',
    );
  }

  Future<List<OcrStudentItem>> _callGeminiApi({
    required Uint8List imageBytes,
    required String mimeType,
    required String apiKey,
    required String modelName,
  }) async {
    final url = Uri.parse(
      'https://generativelanguage.googleapis.com/v1beta/models/$modelName:generateContent?key=$apiKey',
    );

    final base64Image = base64Encode(imageBytes);

    final requestBody = {
      'contents': [
        {
          'parts': [
            {'text': _systemPrompt},
            {
              'inline_data': {
                'mime_type': mimeType,
                'data': base64Image,
              },
            },
          ],
        },
      ],
      'generationConfig': {
        'temperature': 0.1,
        'response_mime_type': 'application/json',
      },
    };

    final response = await _client.post(
      url,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(requestBody),
    );

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final rawText = _extractTextFromResponse(data);
      return parseOcrJson(rawText);
    }

    if (response.statusCode == 429) {
      throw GeminiRateLimitException(
        'Model $modelName đã đạt giới hạn yêu cầu (Rate Limit - HTTP 429). Bạn có thể đổi sang model khác hoặc thử lại sau ít phút.',
      );
    }

    if (response.statusCode == 400) {
      throw FormatException(
        'Yêu cầu không hợp lệ hoặc định dạng ảnh không được hỗ trợ (HTTP 400): ${response.body}',
      );
    }

    if (response.statusCode == 401 || response.statusCode == 403) {
      throw const FormatException(
        'GEMINI_API_KEY không hợp lệ hoặc tài khoản không có quyền truy cập API này (HTTP 401/403).',
      );
    }

    throw FormatException(
      'Lỗi từ máy chủ Gemini (HTTP ${response.statusCode}): ${response.body}',
    );
  }

  String _extractTextFromResponse(Map<String, dynamic> data) {
    final candidates = data['candidates'] as List<dynamic>?;
    if (candidates == null || candidates.isEmpty) {
      throw const FormatException('AI không trả về kết quả nào cho bức ảnh này.');
    }
    final firstCandidate = candidates.first as Map<String, dynamic>;
    final content = firstCandidate['content'] as Map<String, dynamic>?;
    final parts = content?['parts'] as List<dynamic>?;
    if (parts == null || parts.isEmpty) {
      throw const FormatException('Nội dung phản hồi từ AI bị rỗng.');
    }
    final text = parts.first['text'] as String?;
    if (text == null || text.trim().isEmpty) {
      throw const FormatException('Không tìm thấy văn bản trích xuất trong ảnh.');
    }
    return text.trim();
  }

  /// Phân tích chuỗi JSON trả về từ AI thành danh sách [OcrStudentItem].
  static List<OcrStudentItem> parseOcrJson(String rawText) {
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
        throw const FormatException('AI không trả về đúng định dạng danh sách JSON.');
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
        throw const FormatException('Không tìm thấy danh sách sinh viên trong JSON phản hồi.');
      }
    } else {
      throw const FormatException('Định dạng JSON trích xuất không hợp lệ.');
    }

    return itemsList
        .whereType<Map<String, dynamic>>()
        .map((item) => OcrStudentItem.fromJson(item))
        .where((item) => item.studentCode.isNotEmpty || item.fullName.isNotEmpty)
        .toList();
  }
}

class GeminiRateLimitException implements Exception {
  const GeminiRateLimitException(this.message);
  final String message;

  @override
  String toString() => message;
}
