import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:google_fonts/google_fonts.dart';

import '../controllers/model_controller.dart';
import '../core/colors.dart';
import '../services/automatic_model_download_service.dart';
import '../services/download_service.dart';
import '../services/inference_service.dart';
import '../services/model_selection_service.dart';

class ModelView extends GetView<ModelController> {
  const ModelView({super.key});

  @override
  Widget build(BuildContext context) {
    final downloads = Get.find<AutomaticModelDownloadService>();
    final downloadService = Get.find<DownloadService>();
    final selection = Get.find<ModelSelectionService>();
    final inference = Get.find<InferenceService>();

    return Scaffold(
      appBar: AppBar(
        title: Text(
          'Local AI',
          style: GoogleFonts.inter(fontWeight: FontWeight.w700),
        ),
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          await selection.refreshSelection();
          await controller.refreshModelStatuses();
        },
        child: Obx(() {
          final totalRam = selection.totalRamGb.value;
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
            children: [
              Text(
                'ON-DEVICE MODELS',
                style: GoogleFonts.inter(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: Theme.of(context).hintColor,
                ),
              ),
              const SizedBox(height: 8),
              _hardwareSummary(context, totalRam),
              const SizedBox(height: 20),
              ...controller.models.map((model) => Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Obx(() {
                      final state = downloads.statusFor(model);
                      final compatible = controller.isCompatible(model);
                      final selected = controller.isSelected(model);
                      final loaded = controller.isLoaded(model);
                      final isLoading =
                          inference.isLoadingModel.value && selected;
                      final active =
                          downloadService.activeDownloads[model.filename];
                      final downloaded =
                          controller.isDownloaded(model.filename);

                      return _modelCard(
                        context,
                        model: model,
                        state: state,
                        status: compatible
                            ? downloads.statusMessageFor(model)
                            : controller.compatibilityMessage(model),
                        failure: downloads.failureMessageFor(model),
                        progress: active?.progress.value ??
                            downloads.progressFor(model),
                        downloadedBytes: active?.downloadedBytes.value ?? 0,
                        totalBytes:
                            active != null && active.totalBytes.value > 0
                                ? active.totalBytes.value
                                : model.expectedFileSizeBytes,
                        downloaded: downloaded,
                        compatible: compatible,
                        selected: selected,
                        loaded: loaded,
                        isLoading: isLoading,
                        onSelect: () => controller.selectModel(model),
                        onDownload: () => controller.downloadModel(model),
                        onRetry: () =>
                            controller.downloadModel(model, retry: true),
                        onLoad: () => controller.loadModel(model.filename),
                        onUnload: controller.unloadModel,
                      );
                    }),
                  )),
              const SizedBox(height: 4),
              Text(
                'Models stay in app storage after download for offline use. Downloads require at least twice the model file size in free storage.',
                style: GoogleFonts.inter(
                  fontSize: 12,
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

  Widget _hardwareSummary(BuildContext context, double? totalRam) {
    final isVerified = totalRam != null && totalRam.isFinite;
    final message = isVerified
        ? 'Physical memory: ${totalRam.toStringAsFixed(1)} GB. MaxPro models require at least 4 GB.'
        : 'Physical memory could not be verified. MaxPro models stay locked; Maxlite models remain available.';
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            isVerified ? Icons.memory_rounded : Icons.info_outline_rounded,
            size: 20,
            color: isVerified ? AppColors.primary : AppColors.warning,
          ),
          const SizedBox(width: 10),
          Expanded(
              child: Text(message, style: GoogleFonts.inter(fontSize: 12))),
        ],
      ),
    );
  }

  Widget _modelCard(
    BuildContext context, {
    required SelectedLocalModel model,
    required AutomaticModelDownloadState state,
    required String status,
    required String failure,
    required double progress,
    required int downloadedBytes,
    required int totalBytes,
    required bool downloaded,
    required bool compatible,
    required bool selected,
    required bool loaded,
    required bool isLoading,
    required VoidCallback onSelect,
    required VoidCallback onDownload,
    required VoidCallback onRetry,
    required VoidCallback onLoad,
    required VoidCallback onUnload,
  }) {
    final statusColor = !compatible
        ? AppColors.warning
        : loaded || state == AutomaticModelDownloadState.ready
            ? AppColors.success
            : state == AutomaticModelDownloadState.failed ||
                    state == AutomaticModelDownloadState.insufficientStorage
                ? AppColors.error
                : AppColors.primary;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: selected
              ? statusColor.withValues(alpha: 0.55)
              : Theme.of(context).dividerColor.withValues(alpha: 0.7),
          width: selected ? 1.4 : 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                loaded
                    ? Icons.memory_rounded
                    : state == AutomaticModelDownloadState.ready
                        ? Icons.verified_outlined
                        : compatible
                            ? Icons.smart_toy_outlined
                            : Icons.lock_outline_rounded,
                color: statusColor,
                size: 22,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      model.name,
                      style: GoogleFonts.inter(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '${model.quantization} GGUF · ${model.expectedFileSizeLabel}',
                      style: GoogleFonts.inter(
                        fontSize: 12,
                        color: Theme.of(context).hintColor,
                      ),
                    ),
                  ],
                ),
              ),
              if (selected)
                Icon(Icons.check_circle, color: statusColor, size: 20),
            ],
          ),
          const SizedBox(height: 9),
          Text(
            status,
            style: GoogleFonts.inter(
              fontSize: 12,
              color: statusColor,
            ),
          ),
          if (state == AutomaticModelDownloadState.downloading &&
              compatible) ...[
            const SizedBox(height: 10),
            LinearProgressIndicator(value: progress, minHeight: 4),
            const SizedBox(height: 6),
            Text(
              '${DownloadService.formatBytes(downloadedBytes)} of ${DownloadService.formatBytes(totalBytes)} (${(progress * 100).toStringAsFixed(0)}%)',
              style: GoogleFonts.inter(
                fontSize: 11,
                color: Theme.of(context).hintColor,
              ),
            ),
          ],
          if (failure.isNotEmpty && compatible) ...[
            const SizedBox(height: 6),
            Text(
              failure,
              style: GoogleFonts.inter(fontSize: 12, color: AppColors.error),
            ),
          ],
          const SizedBox(height: 8),
          Text(
            '${model.description} License: ${model.licenseSummary}.',
            style: GoogleFonts.inter(
              fontSize: 12,
              height: 1.4,
              color: Theme.of(context).hintColor,
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              if (!compatible)
                OutlinedButton.icon(
                  onPressed: onSelect,
                  icon: const Icon(Icons.info_outline, size: 16),
                  label: const Text('Compatibility'),
                )
              else if (!selected)
                OutlinedButton(
                  onPressed: onSelect,
                  child: const Text('Use model'),
                )
              else
                const OutlinedButton(
                  onPressed: null,
                  child: Text('Selected'),
                ),
              if (!compatible)
                const SizedBox.shrink()
              else if (isLoading)
                FilledButton.icon(
                  onPressed: null,
                  icon: const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  label: const Text('Loading'),
                )
              else if (loaded)
                FilledButton.icon(
                  onPressed: onUnload,
                  icon: const Icon(Icons.eject_outlined),
                  label: const Text('Unload'),
                )
              else if (state == AutomaticModelDownloadState.ready && downloaded)
                FilledButton.icon(
                  onPressed: selected ? onLoad : onSelect,
                  icon: Icon(selected ? Icons.play_arrow_rounded : Icons.check),
                  label: Text(selected ? 'Load model' : 'Use model'),
                )
              else if (state == AutomaticModelDownloadState.downloading)
                FilledButton.icon(
                  onPressed: null,
                  icon: const Icon(Icons.downloading_outlined),
                  label: const Text('Downloading'),
                )
              else
                FilledButton.icon(
                  onPressed: state == AutomaticModelDownloadState.checking
                      ? null
                      : state == AutomaticModelDownloadState.failed ||
                              state ==
                                  AutomaticModelDownloadState
                                      .insufficientStorage ||
                              state ==
                                  AutomaticModelDownloadState.waitingForNetwork
                          ? onRetry
                          : onDownload,
                  icon: Icon(
                    state == AutomaticModelDownloadState.failed ||
                            state ==
                                AutomaticModelDownloadState
                                    .insufficientStorage ||
                            state ==
                                AutomaticModelDownloadState.waitingForNetwork
                        ? Icons.refresh_rounded
                        : Icons.download_rounded,
                  ),
                  label: Text(
                    state == AutomaticModelDownloadState.failed ||
                            state ==
                                AutomaticModelDownloadState
                                    .insufficientStorage ||
                            state ==
                                AutomaticModelDownloadState.waitingForNetwork
                        ? 'Retry'
                        : downloaded
                            ? 'Repair file'
                            : 'Download',
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
