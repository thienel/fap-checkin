import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';

import 'app.dart';
import 'config/mobile_config.dart';
import 'services/student_auth.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    if (!MobileConfig.configured) {
      throw StateError(
        'Thiếu cấu hình Firebase mobile. Xem student-mobile/README.md để build đúng bản.',
      );
    }
    await Firebase.initializeApp(options: MobileConfig.options);
    // Do not persist another account's timetable or roster on shared phones.
    FirebaseFirestore.instance.settings = const Settings(
      persistenceEnabled: false,
    );
    if (MobileConfig.emulatorHost.isNotEmpty) {
      FirebaseFirestore.instance.useFirestoreEmulator(
        MobileConfig.emulatorHost,
        8080,
      );
      await FirebaseAuth.instance.useAuthEmulator(
        MobileConfig.emulatorHost,
        9099,
      );
    }
    runApp(StudentApp(auth: StudentAuth()));
  } catch (_) {
    runApp(
      MaterialApp(
        theme: studentTheme(),
        home: const Scaffold(
          body: SafeArea(
            child: Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'Chưa khởi tạo được ứng dụng. Kiểm tra cấu hình Firebase mobile rồi build lại theo README.',
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
