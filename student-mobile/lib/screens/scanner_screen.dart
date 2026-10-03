import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../config/mobile_config.dart';
import '../models/student_models.dart';
import '../repositories/student_repository.dart';

class ScannerScreen extends StatefulWidget {
  const ScannerScreen({super.key, required this.repository});
  final StudentRepository repository;
  @override
  State<ScannerScreen> createState() => _ScannerScreenState();
}

class _ScannerScreenState extends State<ScannerScreen>
    with WidgetsBindingObserver {
  final controller = MobileScannerController(
    autoStart: false,
    formats: [BarcodeFormat.qrCode],
    detectionSpeed: DetectionSpeed.noDuplicates,
  );
  final code = TextEditingController();
  QrPreview? preview;
  AttendanceState? result;
  bool busy = false;
  String? error;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => start());
  }

  Future<void> start() async {
    if (!mounted || busy || preview != null || result != null) return;
    try {
      await controller.start();
    } catch (_) {
      if (mounted) {
        setState(
          () => error = 'Chưa mở được camera. Cho phép Camera trong cài đặt ứng dụng rồi thử lại.',
        );
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!controller.value.hasCameraPermission) return;
    if (state == AppLifecycleState.resumed) {
      start();
    } else {
      controller.stop();
    }
  }

  Future<void> detect(BarcodeCapture capture) async {
    if (busy || preview != null || result != null) return;
    final values = capture.barcodes.map((b) => b.rawValue).whereType<String>();
    if (values.isEmpty) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await controller.stop();
      final token = parseQr(values.first, MobileConfig.publicWebUrl);
      final value = await widget.repository.preview(token);
      if (mounted) setState(() => preview = value);
    } catch (e) {
      if (mounted) setState(() => error = friendlyError(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> submit() async {
    if (busy || preview == null) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final status = await widget.repository.checkIn(preview!.token, code.text);
      if (mounted) setState(() => result = status);
    } catch (e) {
      if (mounted) setState(() => error = friendlyError(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  void reset() {
    if (busy) return;
    setState(() {
      preview = null;
      result = null;
      error = null;
      code.clear();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => start());
  }

  Future<void> settings() async {
    try {
      await const MethodChannel('vn.fapcheckin.student/settings')
          .invokeMethod<void>('openAppSettings');
    } catch (_) {
      if (mounted) {
        setState(
          () =>
              error = 'Mở Cài đặt → Ứng dụng → FAP Sinh viên → Quyền → Camera.',
        );
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    controller.dispose();
    code.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Quét QR điểm danh')),
    body: SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          if (preview == null && result == null) ...[
            const Text(
              'Quét mã QR trên màn hình giảng viên. Sau đó nhập mã xác nhận đang hiển thị.',
            ),
            const SizedBox(height: 16),
            SizedBox(
              height: 320,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(20),
                child: MobileScanner(
                  useAppLifecycleState: false,
                  controller: controller,
                  onDetect: detect,
                  errorBuilder: (context, exception) => Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.no_photography_outlined, size: 48),
                        const Text(
                          'Camera chưa sẵn sàng. Kiểm tra quyền Camera.',
                        ),
                        TextButton(
                          onPressed: settings,
                          child: const Text('Mở cài đặt ứng dụng'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
          if (preview != null) ...[
            Text(
              preview!.label,
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 8),
            Text(
              'Buổi ${preview!.session['slot']} · ${preview!.session['date']}',
            ),
            Text('${preview!.student.name} · ${preview!.student.code}'),
            Text(widget.repository.email),
            const SizedBox(height: 24),
          ],
          if (result == null && preview != null) ...[
            TextField(
              controller: code,
              enabled: !busy,
              textCapitalization: TextCapitalization.characters,
              maxLength: 5,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: 'Mã xác nhận 5 ký tự',
              ),
              onSubmitted: (_) => submit(),
            ),
            FilledButton(
              onPressed: busy ? null : submit,
              child: const Text('Xác nhận điểm danh'),
            ),
          ],
          if (busy)
            const Padding(
              padding: EdgeInsets.all(20),
              child: Center(child: CircularProgressIndicator()),
            ),
          if (result != null)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  children: [
                    Icon(
                      result == AttendanceState.present
                          ? Icons.check_circle_outline
                          : Icons.info_outline,
                      size: 56,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      result!.label,
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    Text(
                      result == AttendanceState.present
                          ? 'Máy chủ đã xác nhận điểm danh của bạn.'
                          : 'Đã có trạng thái từ giảng viên. Liên hệ giảng viên nếu cần điều chỉnh.',
                    ),
                  ],
                ),
              ),
            ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Text(
                error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          const SizedBox(height: 16),
          OutlinedButton(
            onPressed: busy ? null : reset,
            child: const Text('Quét lại'),
          ),
          if (result != null)
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Về ứng dụng'),
            ),
        ],
      ),
    ),
  );
}
