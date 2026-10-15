import 'package:flutter/material.dart';

/// Dedicated Stremio destination. This is intentionally separate from Addons:
/// Addons manages installed marketplace manifests; Stremio is the app-facing
/// Stremio TV/catalog experience.
class StremioScreen extends StatelessWidget {
  const StremioScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Stremio', style: theme.textTheme.titleLarge),
        const SizedBox(height: 8),
        Text(
          'واجهة Stremio مستقلة عن Addons. إدارة الإضافات وتثبيتها موجودة في خانة Addons.',
          style: theme.textTheme.bodyMedium,
        ),
        const SizedBox(height: 18),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.live_tv_outlined, size: 28),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Stremio TV', style: theme.textTheme.titleMedium),
                      const SizedBox(height: 6),
                      Text(
                        'واجهة Stremio TV الأصلية من Debrify لم تُنقل إلى Eagle X بعد. '
                        'هذه الصفحة منفصلة عمدًا ولا تخلط وظائفها مع Addons.',
                        style: theme.textTheme.bodyMedium,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
