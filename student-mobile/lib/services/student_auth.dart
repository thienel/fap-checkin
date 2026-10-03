import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';

import '../config/mobile_config.dart';

class StudentAuth {
  StudentAuth({FirebaseAuth? auth}) : auth = auth ?? FirebaseAuth.instance;
  final FirebaseAuth auth;
  Future<void>? _initialization;
  Future<void> signIn() async {
    if (MobileConfig.serverClientId.isEmpty) {
      throw StateError('Chưa cấu hình Google đăng nhập cho bản mobile.');
    }
    final google = GoogleSignIn.instance;
    await (_initialization ??= google.initialize(
      serverClientId: MobileConfig.serverClientId,
      clientId: MobileConfig.iosClientId.isEmpty
          ? null
          : MobileConfig.iosClientId,
    ));
    final account = await google.authenticate();
    final token = account.authentication.idToken;
    if (token == null) {
      throw StateError('Google chưa cung cấp token đăng nhập.');
    }
    await auth.signInWithCredential(
      GoogleAuthProvider.credential(idToken: token),
    );
  }

  Future<void> signOut() async {
    await auth.signOut();
    if (_initialization != null) await GoogleSignIn.instance.signOut();
  }
}
