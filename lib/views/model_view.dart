import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:google_fonts/google_fonts.dart';

import '../controllers/model_controller.dart';
import '../core/colors.dart';
import '../services/automatic_model_download_service.dart';
import '../services/download_service.dart';
import '../services/inference_service.dart';

class ModelView extends GetView<ModelController> {
  const ModelView({super.key});

  @override
  Widget build(BuildContext context) {
    final downloads = Get.find<AutomaticModelDownloadService>();
    final inference = Get.find<InferenceService>();

    return Scaffold(
      appBar: AppBar(
        title: Text('Local AI', style: GoogleFonts.inter(fontWeight: FontWeight.w700)),
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          await downloads.ensureSelectedModel();
          await controller.refreshDownloaded();
        },
        child: Obx(() {
          final selected = downloads.selectedModel;
          final state = downloads.state.value;
          final isReady = downloads.isReady && selected != null;
          final isLoading = inference.isLoadingModel.value;
          final isLoaded = inference.isModelLoaded.value;

          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(
                'ON-DEVICE MODEL',
                style: GoogleFonts.inter(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: Theme.of(context).hintColor,
                  letterSpacing: 1.2,
                ),
              ),
              const SizedBox(height: 8),
              _statusCard(
                context,
                selectedName: selected?.name ?? 'Checking device requirements',
                subtitle: selected == null
                    ? downloads.statusMessage.value
                    : '${selected.quantization} GGUF - ${selected.expectedFileSizeLabel}',
                color: _stateColor(state, isLoaded),
                icon: _stateIcon(state, isLoaded),
                status: isLoaded
                    ? 'Loaded and ready to chat'
                    : downloads.statusMessage.value,
              ),
              if (selected != null) ...[
                const SizedBox(height: 16),
                _detailsCard(context, selected),
              ],
              if (state == AutomaticModelDownloadState.downloading &&
                  selected != null) ...[
                const SizedBox(height: 16),
                _downloadProgress(context, downloads, selected.expectedFileSizeBytes),
              ],
              if (isLoading) ...[
                const SizedBox(height: 16),
                _loadProgress(context, inference),
              ],
              if (downloads.failureMessage.value.isNotEmpty) ...[
                const SizedBox(height: 16),
                _messageCard(
                  context,
                  downloads.failureMessage.value,
                  color: AppColors.error,
                ),
              ],
              const SizedBox(height: 20),
              if (isLoaded)
                FilledButton.icon(
                  onPressed: isLoading ? null : controller.unloadModel,
                  icon: const Icon(Icons.eject_outlined),
                  label: const Text('Unload Model'),
                )
              else if (isReady)
                FilledButton.icon(
                  onPressed: isLoading
                      ? null
                      : () => controller.loadModel(selected.filename),
                  icon: const Icon(Icons.play_arrow_rounded),
                  label: const Text('Load Model'),
                )
              else if (downloads.canRetry)
                FilledButton.icon(
                  onPressed: controller.retrySelectedModelDownload,
                  icon: const Icon(Icons.refresh_rounded),
                  label: const Text('Retry Setup'),
                ),
              const SizedBox(height: 16),
              Text(
                'MaxAI chooses this model automatically from device memory and storage. The file remains on this device after setup for local chat without an internet connection.',
                style: GoogleFonts.inter(
                  fontSize: 13,
                  height: 1.45,
                  color: Theme.of(context).hintColor,
                ),
              ),
            ],
          );
        }),
      ),
    );
  }

  Widget _statusCard(
    BuildContext context, {
    required String selectedName,
    required String subtitle,
    required Color color,
    required IconData icon,
    required String status,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 25),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(selectedName,
                    style: GoogleFonts.inter(fontSize: 16, fontWeight: FontWeight.w700)),
                const SizedBox(height: 4),
                Text(subtitle,
                    style: GoogleFonts.inter(
                        fontSize: 12, color: Theme.of(context).hintColor)),
                const SizedBox(height: 10),
                Text(status,
                    style: GoogleFonts.inter(fontSize: 13, color: color)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _detailsCard(BuildContext context, dynamic model) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Theme.of(context).dividerColor.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _detailRow(context, 'Selection', model.description),
          _detailRow(context, 'Source', model.sourceRepository),
          _detailRow(context, 'License', model.licenseSummary),
        ],
      ),
    );
  }

  Widget _detailRow(BuildContext context, String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label,
            style: GoogleFonts.inter(
                fontSize: 11, fontWeight: FontWeight.w700, color: Theme.of(context).hintColor)),
        const SizedBox(height: 2),
        Text(value, style: GoogleFonts.inter(fontSize: 13)),
      ]),
    );
  }

  Widget _downloadProgress(
    BuildContext context,
    AutomaticModelDownloadService downloads,
    int expectedBytes,
  ) {
    final total = downloads.totalBytes.value > 0
        ? downloads.totalBytes.value
        : expectedBytes;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        LinearProgressIndicator(value: downloads.progress.value, minHeight: 5),
        const SizedBox(height: 10),
        Text(
          '${DownloadService.formatBytes(downloads.downloadedBytes.value)} of ${DownloadService.formatBytes(total)} (${(downloads.progress.value * 100).toStringAsFixed(0)}%)',
          style: GoogleFonts.inter(fontSize: 12, color: Theme.of(context).hintColor),
        ),
      ]),
    );
  }

  Widget _loadProgress(BuildContext context, InferenceService inference) {
    final progress = inference.modelLoadProgress.value;
    return _messageCard(
      context,
      'Loading model into memory (${(progress * 100).toStringAsFixed(0)}%).',
      color: AppColors.primary,
      progress: progress,
    );
  }

  Widget _messageCard(
    BuildContext context,
    String message, {
    required Color color,
    double? progress,
  }) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(message, style: GoogleFonts.inter(fontSize: 13, color: color)),
        if (progress != null) ...[
          const SizedBox(height: 10),
          LinearProgressIndicator(value: progress, color: color, minHeight: 4),
        ],
      ]),
    );
  }

  Color _stateColor(AutomaticModelDownloadState state, bool isLoaded) {
    if (isLoaded || state == AutomaticModelDownloadState.ready) {
      return AppColors.success;
    }
    if (state == AutomaticModelDownloadState.failed ||
        state == AutomaticModelDownloadState.ineligible ||
        state == AutomaticModelDownloadState.insufficientStorage) {
      return AppColors.error;
    }
    if (state == AutomaticModelDownloadState.waitingForNetwork) {
      return AppColors.warning;
    }
    return AppColors.primary;
  }

  IconData _stateIcon(AutomaticModelDownloadState state, bool isLoaded) {
    if (isLoaded) return Icons.memory_rounded;
    if (state == AutomaticModelDownloadState.ready) return Icons.verified_outlined;
    if (state == AutomaticModelDownloadState.downloading) {
      return Icons.downloading_outlined;
    }
    if (state == AutomaticModelDownloadState.waitingForNetwork) {
      return Icons.wifi_off_outlined;
    }
    if (state == AutomaticModelDownloadState.failed ||
        state == AutomaticModelDownloadState.ineligible ||
        state == AutomaticModelDownloadState.insufficientStorage) {
      return Icons.error_outline;
    }
    return Icons.memory_outlined;
  }
}
