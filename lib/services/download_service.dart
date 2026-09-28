import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import '../controllers/model_controller.dart';
import 'device_eligibility_service.dart';

import 'download_native.dart' as platform_dl;

/// State for an individual download.
class DownloadProgress {
  final String filename;
  final RxDouble progress = 0.0.obs;
  final RxInt downloadedBytes = 0.obs;
  final RxInt totalBytes = 0.obs;
  final RxDouble bytesPerSecond = 0.0.obs;
  final RxBool isPaused = false.obs;
  final DateTime startedAt = DateTime.now();

  DownloadProgress({required this.filename});

  Duration? get eta {
    final speed = bytesPerSecond.value;
    final total = totalBytes.value;
    if (speed <= 0 || total <= 0) return null;
    final remaining = total - downloadedBytes.value;
    if (remaining <= 0) return Duration.zero;
    return Duration(seconds: (remaining / speed).ceil());
  }
}

/// Android service for downloading GGUF model files with progress tracking.
class DownloadService extends GetxService with WidgetsBindingObserver {
  /// Currently active downloads.
  final activeDownloads = <String, DownloadProgress>{}.obs;
  final failedDownloads = <String, String>{}.obs;
  final downloadUpdateSequence = 0.obs;
  final _nativeDownloadIds = <String, int>{};

  bool get isDownloadingAny => activeDownloads.isNotEmpty;

  /// Whether this Android build can download models.
  bool get supportsDownload => Platform.isAndroid;

  Future<String> get modelsDir async => await platform_dl.getModelsDir();

  Future<String> modelPath(String filename) async {
    return '${await modelsDir}/$filename';
  }

  Future<bool> isModelDownloaded(String filename) async {
    if (!Platform.isAndroid) return false;
    return await platform_dl.isModelDownloaded(await modelPath(filename));
  }

  Future<List<String>> getDownloadedModels() async {
    if (!Platform.isAndroid) return [];
    return await platform_dl.getDownloadedModels(await modelsDir);
  }

  Future<int> getModelSize(String filename) async {
    if (!Platform.isAndroid) return 0;
    return await platform_dl.getModelSize(await modelPath(filename));
  }

  Future<int?> getAvailableStorageBytes() async {
    if (!Platform.isAndroid) return null;
    try {
      return await platform_dl.getAvailableStorageBytes(await modelsDir);
    } catch (_) {
      return null;
    }
  }

  Future<int> getRemoteFileSize(String url, {String? authToken}) async {
    if (!Platform.isAndroid) return 0;
    return await platform_dl.getRemoteFileSize(url, authToken: authToken);
  }

  @override
  void onInit() {
    super.onInit();

    if (Platform.isAndroid) {
      WidgetsBinding.instance.addObserver(this);

      // Initial reconciliation on startup
      reconcileActiveDownloads();

      // Permanent channel progress listener
      const MethodChannel('com.maxai/model_download')
          .setMethodCallHandler((call) async {
        if (call.method == 'downloadProgress') {
          final data = Map<String, dynamic>.from(call.arguments as Map);
          final filename = data['filename'] as String;
          final downloaded = (data['copiedBytes'] as num).toInt();
          final total = (data['totalBytes'] as num).toInt();
          final speed = (data['bytesPerSecond'] as num).toDouble();
          final status = data['status'] as String;

          var progress = activeDownloads[filename];
          if (progress == null &&
              (status == 'Downloading...' ||
                  status == 'Downloading to phone...' ||
                  status.startsWith('Importing'))) {
            progress = DownloadProgress(filename: filename);
            activeDownloads[filename] = progress;
          }
          if (progress != null) {
            progress.downloadedBytes.value = downloaded;
            progress.totalBytes.value = total;
            progress.bytesPerSecond.value = speed;
            if (total > 0) {
              progress.progress.value = downloaded / total;
            }

            if (status == 'Download complete') {
              activeDownloads.remove(filename);
              _nativeDownloadIds.remove(filename);
              failedDownloads.remove(filename);
              // Trigger reload
              try {
                Get.find<ModelController>().refreshDownloaded();
              } catch (_) {}
            } else if (status.startsWith('Download failed') ||
                status == 'Download cancelled') {
              activeDownloads.remove(filename);
              _nativeDownloadIds.remove(filename);
              failedDownloads[filename] = status;
            }
            downloadUpdateSequence.value++;
          }

        }
        return null;
      });
    }
  }

  @override
  void onClose() {
    if (Platform.isAndroid) {
      WidgetsBinding.instance.removeObserver(this);
    }
    super.onClose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      reconcileActiveDownloads();
    }
  }

  Future<void> reconcileActiveDownloads() async {
    if (!Platform.isAndroid) return;
    try {
      final list = await platform_dl.getActiveNativeDownloads();
      final recoveredFilenames = <String>{};
      for (final item in list) {
        final id = item['downloadId'] as int;
        final filename = item['filename'] as String;
        final downloaded = item['downloaded'] as int;
        final total = item['total'] as int;
        final status = item['status'] as String;
        recoveredFilenames.add(filename);

        _nativeDownloadIds[filename] = id;

        final progress =
            activeDownloads[filename] ?? DownloadProgress(filename: filename);
        progress.downloadedBytes.value = downloaded;
        progress.totalBytes.value = total;
        progress.bytesPerSecond.value = 0;
        progress.progress.value = total > 0 ? downloaded / total : 0;
        progress.isPaused.value = status == 'Paused';
        if (!activeDownloads.containsKey(filename)) {
          activeDownloads[filename] = progress;
        }
        downloadUpdateSequence.value++;
      }

      // Remove UI entries whose native DownloadManager jobs no longer exist.
      final staleFilenames = _nativeDownloadIds.keys
          .where((filename) => !recoveredFilenames.contains(filename))
          .toList();
      for (final filename in staleFilenames) {
        _nativeDownloadIds.remove(filename);
        activeDownloads.remove(filename);
      }
      downloadUpdateSequence.value++;
    } catch (e) {
      print('[DownloadService] Failed to reconcile active downloads: $e');
    }
  }

  Future<String> downloadModel({
    required String url,
    required String filename,
    String? authToken,
    int expectedBytes = 0,
  }) async {
    if (!Platform.isAndroid) {
      return 'ERROR: Model downloads are available only on Android.';
    }
    if (Get.isRegistered<DeviceEligibilityService>()) {
      final eligibility =
          await Get.find<DeviceEligibilityService>().refreshEligibility();
      if (!eligibility.isEligible) {
        return 'INELIGIBLE: ${eligibility.message}';
      }
    }
    if (activeDownloads.containsKey(filename)) return 'ALREADY_DOWNLOADING';

    final downloadProgress = DownloadProgress(filename: filename);
    activeDownloads[filename] = downloadProgress;
    failedDownloads.remove(filename);

    try {
      final modelsDirectory = await modelsDir;
      final result = await platform_dl.startNativeDownload(
        url: url,
        filename: filename,
        modelsDir: modelsDirectory,
        expectedBytes: expectedBytes,
      );
      if (result != null) {
        final id = result['downloadId'] as int;
        _nativeDownloadIds[filename] = id;
        return 'NATIVE_BACKGROUND_STARTED';
      }
      throw Exception('Native download failed to start.');
    } catch (e) {
      activeDownloads.remove(filename);
      failedDownloads[filename] = '$e';
      rethrow;
    }
  }

  void pauseDownload(String filename) {
    final nativeId = _nativeDownloadIds[filename];
    if (nativeId != null && Platform.isAndroid) {
      platform_dl.cancelNativeDownload(
          downloadId: nativeId, filename: filename);
      activeDownloads.remove(filename);
      _nativeDownloadIds.remove(filename);
    }
  }

  Future<void> deleteModel(String filename) async {
    if (!Platform.isAndroid) return;
    final nativeId = _nativeDownloadIds[filename];
    if (nativeId != null && Platform.isAndroid) {
      await platform_dl.cancelNativeDownload(
          downloadId: nativeId, filename: filename);
      _nativeDownloadIds.remove(filename);
    }
    await platform_dl.deleteModel(await modelPath(filename));
  }

  static String formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  static String formatWholeMb(int bytes) {
    if (bytes <= 0) return '0 MB';
    final mb = (bytes / (1024 * 1024)).round().clamp(1, 1 << 31);
    return '$mb MB';
  }

  static String formatSpeed(double bytesPerSecond) {
    return '${formatBytes(bytesPerSecond.round())}/s';
  }

  static String formatDuration(Duration? duration) {
    if (duration == null) return '--';
    if (duration.inHours > 0) {
      return '${duration.inHours}h ${duration.inMinutes.remainder(60)}m';
    }
    if (duration.inMinutes > 0) {
      return '${duration.inMinutes}m ${duration.inSeconds.remainder(60)}s';
    }
    return '${duration.inSeconds}s';
  }
}
