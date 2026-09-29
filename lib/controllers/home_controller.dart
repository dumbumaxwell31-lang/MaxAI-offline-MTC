import 'package:flutter/material.dart';
import 'package:get/get.dart';
import '../services/hive_service.dart';
import '../services/download_service.dart';
import '../services/model_selection_service.dart';
import 'model_controller.dart';
import '../core/constants.dart';

class HomeController extends GetxController {
  static const tabCount = 3;

  final currentTab = 0.obs;
  bool _resumeDialogShown = false;

  void changeTab(int index) {
    currentTab.value = index.clamp(0, tabCount - 1).toInt();
  }

  /// Shows a one-time dialog on startup asking if the user wants to reload
  /// the last used local model. Does not auto-load anything.
  void checkResumeModel(BuildContext context) async {
    if (_resumeDialogShown) return;
    _resumeDialogShown = true;

    final hive = Get.find<HiveService>();
    final downloadService = Get.find<DownloadService>();

    // Check text model
    final textName = hive.getSetting<String>(AppConstants.keyLocalModelName);
    final textPath = hive.getSetting<String>(AppConstants.keyLocalModelPath);
    final selectedModel = Get.find<ModelSelectionService>().selectedModel.value;
    if (selectedModel == null) return;
    bool hasText = textName != null &&
        textName.isNotEmpty &&
        textPath != null &&
        textPath.isNotEmpty &&
        textName == selectedModel.filename &&
        await downloadService.isModelDownloaded(textName);

    if (!hasText) return;
    if (!context.mounted) return;

    final isDark = Theme.of(context).brightness == Brightness.dark;

    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (_) => AlertDialog(
        backgroundColor: isDark ? const Color(0xFF1C1C1E) : Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text('Resume Session?',
            style: TextStyle(
                color: isDark ? Colors.white : Colors.black,
                fontWeight: FontWeight.w600)),
        content: Text('Load your last model?\n\n${selectedModel.name}',
            style: TextStyle(color: isDark ? Colors.white70 : Colors.black87)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text('Skip',
                style:
                    TextStyle(color: isDark ? Colors.white54 : Colors.black54)),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor:
                  isDark ? const Color(0xFF0A84FF) : const Color(0xFF007AFF),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
            ),
            onPressed: () {
              Navigator.of(context).pop();
              if (hasText) {
                Get.find<ModelController>().loadModel(selectedModel.filename);
              }
            },
            child: const Text('Load'),
          ),
        ],
      ),
    );
  }
}
