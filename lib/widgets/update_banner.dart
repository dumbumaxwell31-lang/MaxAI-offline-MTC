import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:google_fonts/google_fonts.dart';

import '../core/colors.dart';
import '../services/app_update_service.dart';

/// Small, dismissible card shown when a newer MaxAI release exists.
class UpdateBanner extends StatelessWidget {
  const UpdateBanner({super.key});

  @override
  Widget build(BuildContext context) {
    if (!Get.isRegistered<AppUpdateService>()) return const SizedBox.shrink();
    final updates = Get.find<AppUpdateService>();
    return Obx(() {
      final release = updates.visibleUpdate.value;
      if (release == null) return const SizedBox.shrink();
      return UpdateCard(
        release: release,
        currentVersion: updates.currentVersion.value,
        onUpdate: () async {
          final opened = await updates.openStoreListing();
          if (!opened) {
            Get.snackbar(
              'Google Play unavailable',
              'Open Google Play to update MaxAI.',
              snackPosition: SnackPosition.BOTTOM,
              margin: const EdgeInsets.all(12),
            );
          }
        },
        onLater: updates.dismiss,
      );
    });
  }
}

class UpdateCard extends StatelessWidget {
  const UpdateCard({
    super.key,
    required this.release,
    required this.currentVersion,
    required this.onUpdate,
    required this.onLater,
  });

  final AppRelease release;
  final String currentVersion;
  final VoidCallback onUpdate;
  final VoidCallback onLater;

  static const _maxNoteLines = 3;

  List<String> get _noteLines => release.notes
      .split('\n')
      .map((line) => line.trim().replaceFirst(RegExp(r'^[-*•]\s*'), ''))
      .where((line) => line.isNotEmpty && !line.startsWith('#'))
      .take(_maxNoteLines)
      .toList();

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final hint = Theme.of(context).hintColor;
    final notes = _noteLines;
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 6),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1C1C1E) : const Color(0xFFF2F6FF),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.primary.withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(children: [
            const Icon(Icons.system_update_outlined,
                size: 20, color: AppColors.primary),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'MaxAI ${release.version} is available',
                style: GoogleFonts.inter(
                    fontSize: 14, fontWeight: FontWeight.w700),
              ),
            ),
          ]),
          if (currentVersion.isNotEmpty) ...[
            const SizedBox(height: 2),
            Padding(
              padding: const EdgeInsets.only(left: 28),
              child: Text('Your version: $currentVersion',
                  style: GoogleFonts.inter(fontSize: 12, color: hint)),
            ),
          ],
          if (notes.isNotEmpty) ...[
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.only(left: 28),
              child: Text(
                "What's new:\n${notes.map((n) => '• $n').join('\n')}",
                maxLines: _maxNoteLines + 1,
                overflow: TextOverflow.ellipsis,
                style: GoogleFonts.inter(fontSize: 12, height: 1.4),
              ),
            ),
          ],
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(onPressed: onLater, child: const Text('LATER')),
              FilledButton(onPressed: onUpdate, child: const Text('UPDATE')),
            ],
          ),
        ],
      ),
    );
  }
}
