import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'firebase_options.dart';
import 'services/attendance_api.dart';
import 'domain/models.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  
  final api = AttendanceApi();
  try {
    print("Testing startAttendance...");
    // Mock data for test
    final slot = TodaySlot(
      courseClassId: 'mock-class-id',
      slot: 1,
      slotCount: 2,
      daySlot: 1,
      date: '2026-09-23',
    );
    final session = await api.startAttendance(
      slot: slot,
      rotationSeconds: 5,
      validitySeconds: 20,
    );
    print("Success: ${session.id}");
  } catch (e) {
    print("ERROR CAUGHT: $e");
  }
}
