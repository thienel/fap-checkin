package vn.fapcheckin.fap_student

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.content.Intent
import android.net.Uri
import android.provider.Settings

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "vn.fapcheckin.student/settings")
            .setMethodCallHandler { call, result ->
                if (call.method == "openAppSettings") {
                    try {
                        startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                            Uri.parse("package:$packageName")))
                        result.success(null)
                    } catch (e: Exception) {
                        result.error("settings-unavailable", "Could not open app settings", null)
                    }
                } else { result.notImplemented() }
            }
    }
}
