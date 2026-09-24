import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      await FirebaseAuth.instance.signInWithEmailAndPassword(
        email: _emailController.text.trim(),
        password: _passwordController.text,
      );
    } on FirebaseAuthException catch (error, stack) {
      debugPrint('LOGIN FirebaseAuthException: code=${error.code}, message=${error.message}, plugin=${error.plugin}\n$stack');
      setState(
        () => _error = switch (error.code) {
          'invalid-credential' => 'Email hoặc mật khẩu không đúng. [invalid-credential]',
          'user-not-found' => 'Tài khoản email này chưa được tạo trong Firebase Auth. [user-not-found]',
          'wrong-password' => 'Mật khẩu không đúng. [wrong-password]',
          'invalid-email' => 'Địa chỉ email không hợp lệ. [invalid-email]',
          'user-disabled' => 'Tài khoản đã bị vô hiệu hóa. [user-disabled]',
          'too-many-requests' => 'Thử lại sau vì có quá nhiều lần đăng nhập. [too-many-requests]',
          'keychain-error' =>
            'macOS chưa cấp quyền Keychain cho ứng dụng. Hãy kiểm tra '
                'Keychain Sharing và cấu hình ký ứng dụng.',
          'internal-error' =>
            'Lỗi nội bộ Firebase (Internal error). Vui lòng kiểm tra Email/Password Sign-in method đã bật trong Firebase Console chưa.',
          'channel-error' => 'Vui lòng nhập đầy đủ email và mật khẩu.',
          _ => '[${error.code}] ${error.message ?? 'Không thể đăng nhập.'}',
        },
      );
    } catch (error, stack) {
      debugPrint('LOGIN Generic Exception: $error\n$stack');
      setState(() => _error = 'Lỗi không xác định: $error');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Row(
        children: [
          Expanded(
            child: Container(
              color: const Color(0xFF164E63),
              padding: const EdgeInsets.all(56),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(
                    Icons.qr_code_2_rounded,
                    color: Colors.white,
                    size: 72,
                  ),
                  const SizedBox(height: 28),
                  Text(
                    'Điểm danh nhanh.\nDữ liệu rõ ràng.',
                    style: Theme.of(context).textTheme.displaySmall?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                      height: 1.1,
                    ),
                  ),
                  const SizedBox(height: 18),
                  const Text(
                    'QR thay đổi liên tục, xác thực Google và đồng bộ Google Sheets.',
                    style: TextStyle(color: Color(0xFFD7E8ED), fontSize: 17),
                  ),
                ],
              ),
            ),
          ),
          SizedBox(
            width: 480,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 56),
              child: Form(
                key: _formKey,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'Đăng nhập giảng viên',
                      style: Theme.of(context).textTheme.headlineMedium
                          ?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Dùng tài khoản đã được cấp quyền trong Firebase.',
                    ),
                    const SizedBox(height: 28),
                    TextFormField(
                      controller: _emailController,
                      decoration: const InputDecoration(
                        labelText: 'Email',
                        prefixIcon: Icon(Icons.mail_outline),
                      ),
                      validator: (value) =>
                          value == null || !value.contains('@')
                          ? 'Nhập email hợp lệ'
                          : null,
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: _passwordController,
                      obscureText: true,
                      onFieldSubmitted: (_) => _login(),
                      decoration: const InputDecoration(
                        labelText: 'Mật khẩu',
                        prefixIcon: Icon(Icons.lock_outline),
                      ),
                      validator: (value) => value == null || value.length < 6
                          ? 'Mật khẩu phải có ít nhất 6 ký tự'
                          : null,
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 14),
                      Text(
                        _error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ],
                    const SizedBox(height: 20),
                    FilledButton.icon(
                      onPressed: _submitting ? null : _login,
                      icon: _submitting
                          ? const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.login),
                      label: const Padding(
                        padding: EdgeInsets.symmetric(vertical: 14),
                        child: Text('Đăng nhập'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
