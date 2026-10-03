import 'dart:io';

import 'package:firebase_core/firebase_core.dart';

abstract final class MobileConfig {
  static const apiKey = String.fromEnvironment('FIREBASE_API_KEY');
  static const appId = String.fromEnvironment('FIREBASE_APP_ID');
  static const projectId = String.fromEnvironment('FIREBASE_PROJECT_ID');
  static const senderId = String.fromEnvironment(
    'FIREBASE_MESSAGING_SENDER_ID',
  );
  static const serverClientId = String.fromEnvironment(
    'GOOGLE_SERVER_CLIENT_ID',
  );
  static const iosClientId = String.fromEnvironment('GOOGLE_IOS_CLIENT_ID');
  static const emulatorHost = String.fromEnvironment('EMULATOR_HOST');
  static const configuredUrl = String.fromEnvironment('PUBLIC_WEB_URL');
  static String get publicWebUrl =>
      configuredUrl.isEmpty ? 'https://$projectId.web.app' : configuredUrl;
  static bool get configured =>
      apiKey.isNotEmpty &&
      appId.isNotEmpty &&
      projectId.isNotEmpty &&
      senderId.isNotEmpty;
  static FirebaseOptions get options => FirebaseOptions(
    apiKey: apiKey,
    appId: appId,
    messagingSenderId: senderId,
    projectId: projectId,
    iosBundleId: Platform.isIOS ? 'vn.fapcheckin.fapStudent' : null,
  );
}
