import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:google_sign_in/google_sign_in.dart';

import 'repositories/student_repository.dart';
import 'screens/student_home.dart';
import 'services/student_auth.dart';

ThemeData studentTheme() => ThemeData(
  useMaterial3: true,
  colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF146B62)),
  scaffoldBackgroundColor: const Color(0xFFF4F7F6),
  appBarTheme: const AppBarTheme(backgroundColor: Color(0xFFF4F7F6)),
  inputDecorationTheme: const InputDecorationTheme(
    border: OutlineInputBorder(),
  ),
);

class StudentApp extends StatelessWidget {
  const StudentApp({super.key, required this.auth});
  final StudentAuth auth;
  @override
  Widget build(BuildContext context) => StreamBuilder<User?>(
    stream: auth.auth.authStateChanges(),
    builder: (context, snapshot) {
      final user = snapshot.data;
      // Recreating the Navigator removes ALL old detail/scanner routes when
      // changing accounts, not merely the authenticated home screen.
      return MaterialApp(
        key: ValueKey(user?.uid),
        title: 'FAP Sinh viên',
        debugShowCheckedModeBanner: false,
        theme: studentTheme(),
        home: snapshot.connectionState == ConnectionState.waiting
            ? const Scaffold(body: Center(child: CircularProgressIndicator()))
            : user == null
            ? StudentLogin(onSignIn: auth.signIn)
            : StudentHome(
                repository: StudentRepository(
                  uid: user.uid,
                  email: user.email ?? '',
                ),
                onSignOut: auth.signOut,
              ),
      );
    },
  );
}

class StudentLogin extends StatefulWidget {
  const StudentLogin({super.key, required this.onSignIn});
  final Future<void> Function() onSignIn;
  @override
  State<StudentLogin> createState() => _StudentLoginState();
}

class _StudentLoginState extends State<StudentLogin> {
  bool busy = false;
  String? error;
  Future<void> login() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.onSignIn();
    } on GoogleSignInException catch (e) {
      if (e.code != GoogleSignInExceptionCode.canceled && mounted) {
        setState(
          () => error = 'Google chưa đăng nhập được. Kiểm tra cấu hình ứng dụng và thử lại.',
        );
      }
    } catch (e) {
      if (mounted) setState(() => error = friendlyError(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(28),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Icon(
                  Icons.school_outlined,
                  size: 72,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(height: 28),
                Text(
                  'Việc học, trong tầm tay.',
                  style: Theme.of(context).textTheme.headlineLarge,
                ),
                const SizedBox(height: 14),
                const Text(
                  'Điểm danh, xem lịch học và gửi đơn xin nghỉ bằng email đã được giảng viên thêm vào lớp.',
                ),
                const SizedBox(height: 32),
                FilledButton.icon(
                  onPressed: busy ? null : login,
                  icon: busy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.login),
                  label: const Text('Đăng nhập với Google'),
                ),
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: Text(
                      error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
