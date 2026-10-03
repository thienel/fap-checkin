import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import 'screens/configuration_error_screen.dart';
import 'screens/dashboard_screen.dart';
import 'screens/login_screen.dart';
import 'services/attendance_api.dart';
import 'theme/app_theme.dart';

class AttendanceApp extends StatelessWidget {
  const AttendanceApp({super.key, required this.configurationError});

  final Object? configurationError;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'FAP Check Attendance',
      theme: buildAppTheme(),
      home: configurationError != null
          ? ConfigurationErrorScreen(error: configurationError!)
          : _AuthGate(api: AttendanceApi()),
    );
  }
}

class _AuthGate extends StatelessWidget {
  const _AuthGate({required this.api});

  final AttendanceApi api;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        if (snapshot.data == null) return const LoginScreen();
        return DashboardScreen(api: api, user: snapshot.data!);
      },
    );
  }
}
