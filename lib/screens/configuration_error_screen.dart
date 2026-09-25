import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

class ConfigurationErrorScreen extends StatelessWidget {
  const ConfigurationErrorScreen({super.key, required this.error});

  final Object error;

  @override
  Widget build(BuildContext context) {
    final device = Theme.of(context).platform == TargetPlatform.windows
        ? 'windows'
        : 'macos';
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(AppSpace.xxl),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.settings_suggest_outlined,
                    size: 48,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(height: 20),
                  Text(
                    'Cần cấu hình Firebase',
                    style: Theme.of(context).textTheme.headlineMedium,
                  ),
                  const SizedBox(height: 12),
                  Text('$error'),
                  const SizedBox(height: 20),
                  const Text(
                    'Tạo Firebase project, deploy backend, sau đó chạy app bằng cấu hình trong README.md.',
                  ),
                  const SizedBox(height: 12),
                  DecoratedBox(
                    decoration: const BoxDecoration(
                      color: AppColors.surfaceMuted,
                      borderRadius: BorderRadius.all(
                        Radius.circular(AppRadii.control),
                      ),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: SelectableText(
                        'flutter run -d $device --dart-define-from-file=firebase.desktop.json',
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
}
