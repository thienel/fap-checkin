import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';

import 'app.dart';
import 'firebase_options.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  Object? configurationError;
  if (DesktopFirebaseOptions.isConfigured) {
    try {
      await Firebase.initializeApp(
        options: DesktopFirebaseOptions.currentPlatform,
      );
    } catch (error) {
      configurationError = error;
    }
  } else {
    configurationError = const FirebaseConfigurationException();
  }

  runApp(AttendanceApp(configurationError: configurationError));
}

class FirebaseConfigurationException implements Exception {
  const FirebaseConfigurationException();

  @override
  String toString() =>
      'Thiếu cấu hình Firebase. Hãy chạy app với các --dart-define được mô tả trong README.md.';
}
