import 'package:flutter/material.dart';

import '../domain/class_overview.dart';
import '../theme/app_theme.dart';

enum AppTone { info, success, warning, error }

extension AppToneColors on AppTone {
  Color get foreground => switch (this) {
    AppTone.info => AppColors.info,
    AppTone.success => AppColors.success,
    AppTone.warning => AppColors.warning,
    AppTone.error => AppColors.error,
  };

  Color get background => switch (this) {
    AppTone.info => AppColors.infoSurface,
    AppTone.success => AppColors.successSurface,
    AppTone.warning => AppColors.warningSurface,
    AppTone.error => AppColors.errorSurface,
  };
}

class AppPageHeader extends StatelessWidget {
  const AppPageHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.actions = const [],
  });

  final String title;
  final String? subtitle;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final heading = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Theme.of(context).textTheme.headlineMedium),
        if (subtitle != null) ...[
          const SizedBox(height: AppSpace.xs),
          Text(subtitle!, style: const TextStyle(color: AppColors.textMuted)),
        ],
      ],
    );
    if (actions.isEmpty) return heading;
    final toolbar = Wrap(
      spacing: AppSpace.sm,
      runSpacing: AppSpace.sm,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: actions,
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 1000) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              heading,
              const SizedBox(height: AppSpace.lg),
              toolbar,
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(child: heading),
            const SizedBox(width: AppSpace.xl),
            toolbar,
          ],
        );
      },
    );
  }
}

class AppNotice extends StatelessWidget {
  const AppNotice({
    super.key,
    required this.message,
    this.tone = AppTone.info,
    this.icon,
    this.action,
  });

  final String message;
  final AppTone tone;
  final IconData? icon;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.symmetric(
      horizontal: AppSpace.lg,
      vertical: AppSpace.md,
    ),
    decoration: BoxDecoration(
      color: tone.background,
      borderRadius: BorderRadius.circular(AppRadii.control),
      border: Border.all(color: tone.foreground.withValues(alpha: 0.25)),
    ),
    child: Row(
      children: [
        Icon(icon ?? Icons.info_outline, size: 20, color: tone.foreground),
        const SizedBox(width: AppSpace.md),
        Expanded(
          child: Text(message, style: TextStyle(color: tone.foreground)),
        ),
        if (action != null) ...[const SizedBox(width: AppSpace.md), action!],
      ],
    ),
  );
}

class AppEmptyState extends StatelessWidget {
  const AppEmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.description,
    this.action,
  });

  final IconData icon;
  final String title;
  final String? description;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 440),
      child: Padding(
        padding: const EdgeInsets.all(AppSpace.xxl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 40, color: AppColors.textMuted),
            const SizedBox(height: AppSpace.lg),
            Text(title, style: Theme.of(context).textTheme.titleLarge),
            if (description != null) ...[
              const SizedBox(height: AppSpace.sm),
              Text(
                description!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppColors.textMuted),
              ),
            ],
            if (action != null) ...[
              const SizedBox(height: AppSpace.xl),
              action!,
            ],
          ],
        ),
      ),
    ),
  );
}

class AppMetricTile extends StatelessWidget {
  const AppMetricTile({
    super.key,
    required this.label,
    required this.value,
    required this.icon,
    this.tone = AppTone.info,
  });

  final String label;
  final String value;
  final IconData icon;
  final AppTone tone;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(AppSpace.lg),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: tone.background,
              borderRadius: BorderRadius.circular(AppRadii.control),
            ),
            child: Icon(icon, size: 19, color: tone.foreground),
          ),
          const SizedBox(width: AppSpace.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.textMuted,
                  ),
                ),
                Text(value, style: Theme.of(context).textTheme.titleLarge),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

class AppAttendanceBadge extends StatelessWidget {
  const AppAttendanceBadge({
    super.key,
    required this.status,
    this.iconOnly = false,
    this.source,
    this.pendingLabel = 'Chưa mở',
  });

  final AttendanceStatus status;
  final bool iconOnly;
  final String? source;
  final String pendingLabel;

  @override
  Widget build(BuildContext context) {
    final (label, icon, tone) = switch (status) {
      AttendanceStatus.present => (
        'Có mặt',
        Icons.check_circle_outline,
        AppTone.success,
      ),
      AttendanceStatus.absent => ('Vắng', Icons.cancel_outlined, AppTone.error),
      AttendanceStatus.excused => (
        'Có phép',
        Icons.event_available_outlined,
        AppTone.info,
      ),
      AttendanceStatus.notYetOpen => (
        pendingLabel,
        Icons.schedule_outlined,
        AppTone.warning,
      ),
      AttendanceStatus.pending => (
        'Chưa điểm danh',
        Icons.schedule_outlined,
        AppTone.warning,
      ),
    };
    final sourceLabel = switch (source) {
      'teacher' => 'Giảng viên chỉnh tay',
      'policy' => 'Miễn theo chính sách',
      'qr' => 'QR',
      _ => null,
    };
    return Tooltip(
      message: sourceLabel == null ? label : '$label · $sourceLabel',
      child: iconOnly
          ? Stack(
              clipBehavior: Clip.none,
              children: [
                Icon(icon, size: 20, color: tone.foreground),
                if (source == 'teacher' || source == 'policy')
                  Positioned(
                    right: -5,
                    bottom: -4,
                    child: Icon(
                      source == 'teacher' ? Icons.edit : Icons.policy,
                      size: 10,
                      color: tone.foreground,
                    ),
                  ),
              ],
            )
          : Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
              decoration: BoxDecoration(
                color: tone.background,
                borderRadius: BorderRadius.circular(AppRadii.control),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 15, color: tone.foreground),
                  const SizedBox(width: AppSpace.xs),
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: tone.foreground,
                      ),
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}
