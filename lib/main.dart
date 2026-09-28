import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'controllers/settings_controller.dart';
import 'controllers/cloud_model_controller.dart';
import 'controllers/model_controller.dart';
import 'core/theme.dart';
import 'core/app_identity.dart';
import 'core/splash_artwork.dart';
import 'core/routes.dart';
import 'services/hive_service.dart';
import 'services/inference_service.dart';
import 'services/cloud_service.dart';
import 'services/download_service.dart';
import 'services/automatic_model_download_service.dart';
import 'services/device_info_service.dart';
import 'services/device_eligibility_service.dart';
import 'services/model_selection_service.dart';
import 'services/inference_resource_policy.dart';
import 'services/app_log_service.dart';
import 'services/crash_reporting_service.dart';
import 'core/constants.dart';

void main() {
  final appLogBuffer = <String>[];

  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();

    // Register logger first so everything routes to it
    final appLog = AppLogService();
    Get.put(appLog);

    // Flush buffered prints
    for (final line in appLogBuffer) {
      appLog.info(line);
    }
    appLogBuffer.clear();

    appLog.info('App started');

    try {
      await SplashArtwork.preload();
    } catch (error, stack) {
      appLog.error('Could not preload launch artwork.',
          details: '$error\n$stack');
    }

    // Support phones and tablets in portrait or landscape.
    await SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);

    // Initialize Hive
    await Hive.initFlutter();

    // Register global services
    await Get.putAsync(() => HiveService().init());
    await Get.putAsync(() => DeviceInfoService().init());
    Get.put(DownloadService());
    await Get.putAsync(() => DeviceEligibilityService().init());
    await Get.putAsync(() => ModelSelectionService().init());

    // Settings controller must be initialized before runApp for theme support
    final settingsController = Get.put(SettingsController());
    Get.put(CloudModelController());

    Get.put(InferenceService());
    Get.put(CloudService());
    await Get.putAsync(() => AutomaticModelDownloadService().init());
    final crashReporting =
        await Get.putAsync(() => CrashReportingService().init());
    FlutterError.onError = (details) {
      FlutterError.presentError(details);
      appLog.error(
        details.exceptionAsString(),
        details: details.stack?.toString() ?? 'No stack',
      );
      crashReporting.recordFlutterFatal(details);
    };
    PlatformDispatcher.instance.onError = (error, stack) {
      appLog.error(
        error.toString(),
        details: stack.toString(),
      );
      crashReporting.recordFatal(error, stack, reason: 'platform_dispatcher');
      return true;
    };
    Get.put(ModelController());

    // Auto-configure inference settings based on device RAM
    _autoConfigureForDevice();

    // Keep last model as a quick-load option, but do not auto-load on startup.
    _validateLastModel();

    runApp(const MaxAIApp());

    // Apply system UI after frame is rendered so Get.mediaQuery is available
    WidgetsBinding.instance.addPostFrameCallback((_) {
      settingsController.setThemeMode(settingsController.themeMode.value);
    });
  }, (error, stack) async {
    if (Get.isRegistered<AppLogService>()) {
      Get.find<AppLogService>().error(
        'Uncaught zone error: $error',
        details: stack.toString(),
      );
    }
    if (Get.isRegistered<CrashReportingService>()) {
      await Get.find<CrashReportingService>()
          .recordFatal(error, stack, reason: 'run_zoned_guarded');
    }
  }, zoneSpecification: ZoneSpecification(
    print: (self, parent, zone, line) {
      if (Get.isRegistered<AppLogService>()) {
        Get.find<AppLogService>().info(line);
      } else {
        appLogBuffer.add(line);
      }
      parent.print(zone, line);
    },
  ));
}

/// Validates that remembered models still exist on disk.
/// Does NOT auto-load — the HomeView will ask the user on first launch.
void _validateLastModel() async {
  final hive = Get.find<HiveService>();
  final downloadService = Get.find<DownloadService>();

  // Validate last text/LLM model
  final textModelName = hive.getSetting<String>(AppConstants.keyLocalModelName);
  final textModelPath = hive.getSetting<String>(AppConstants.keyLocalModelPath);
  final selectedModel = Get.find<ModelSelectionService>().selectedModel.value;
  if (selectedModel != null &&
      textModelName != null &&
      textModelName.isNotEmpty &&
      textModelPath != null &&
      textModelPath.isNotEmpty &&
      textModelName == selectedModel.filename) {
    if (!await downloadService.isModelDownloaded(textModelName)) {
      await hive.setSetting(AppConstants.keyLocalModelPath, '');
      await hive.setSetting(AppConstants.keyLocalModelName, '');
    }
  }
}

/// Applies the RAM profile on first launch and migrates untouched legacy defaults.
void _autoConfigureForDevice() {
  final hive = Get.find<HiveService>();
  final device = Get.find<DeviceInfoService>();
  final selected = Get.find<ModelSelectionService>().selectedModel.value;

  final hasConfigured =
      hive.getSetting<bool>('device_auto_configured') ?? false;
  final hasManualLimits = hive.getSetting<bool>(
        AppConstants.keyInferenceLimitsManuallyConfigured,
      ) ??
      false;
  if (hasConfigured) {
    final isPro =
        selected?.identifier == AutomaticModelPolicy.maxAiPro.identifier;
    final legacyContextSize = isPro ? 2048 : 1024;
    final legacyMaxTokens = isPro ? 512 : 256;
    final savedContextSize = hive.getSetting<int>(AppConstants.keyContextSize);
    final savedMaxTokens = hive.getSetting<int>(AppConstants.keyMaxTokens);
    if (selected != null &&
        !hasManualLimits &&
        savedContextSize == legacyContextSize &&
        savedMaxTokens == legacyMaxTokens) {
      final limits = InferenceResourcePolicy.forAvailableRam(
        availableRamGb: device.hasAvailableRamMeasurement.value
            ? device.availableRamGB.value
            : null,
        modelContextLimit: selected.maxContextSize,
        modelOutputLimit: selected.maxOutputTokens,
      );
      final increasesLimits = limits.contextSize >= legacyContextSize &&
          limits.maxOutputTokens >= legacyMaxTokens &&
          (limits.contextSize > legacyContextSize ||
              limits.maxOutputTokens > legacyMaxTokens);
      if (increasesLimits) {
        hive.setSetting(AppConstants.keyContextSize, limits.contextSize);
        hive.setSetting(AppConstants.keyMaxTokens, limits.maxOutputTokens);
        final settings = Get.find<SettingsController>();
        settings.contextSize.value = limits.contextSize;
        settings.maxTokens.value = limits.maxOutputTokens;
        Get.find<AppLogService>().info(
          '[AutoConfig] Migrated untouched legacy inference limits to '
          'context=${limits.contextSize}, maxTokens=${limits.maxOutputTokens}',
        );
      }
    }
    return;
  }

  final model = selected ?? AutomaticModelPolicy.maxAiLite;
  final limits = InferenceResourcePolicy.forAvailableRam(
    availableRamGb: device.hasAvailableRamMeasurement.value
        ? device.availableRamGB.value
        : null,
    modelContextLimit: model.maxContextSize,
    modelOutputLimit: model.maxOutputTokens,
  );
  final contextSize = limits.contextSize;
  final maxTokens = limits.maxOutputTokens;
  hive.setSetting(AppConstants.keyContextSize, contextSize);
  hive.setSetting(AppConstants.keyMaxTokens, maxTokens);
  hive.setSetting(AppConstants.keyTemperature, 0.7);
  hive.setSetting('device_auto_configured', true);
  final settings = Get.find<SettingsController>();
  settings.contextSize.value = contextSize;
  settings.maxTokens.value = maxTokens;

  Get.find<AppLogService>()
      .info('[AutoConfig] Set context=$contextSize, maxTokens=$maxTokens for '
          '${device.totalRamGB.value.toStringAsFixed(1)}GB RAM');
}

class MaxAIApp extends StatelessWidget {
  const MaxAIApp({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = Get.find<SettingsController>();
    return Obx(() {
      final themeMode = settings.themeMode.value;
      final scale = settings.fontScale.value; // read here → Obx tracks it
      return GetMaterialApp(
        title: AppIdentity.name,
        debugShowCheckedModeBanner: false,
        theme: AppTheme.lightTheme,
        darkTheme: AppTheme.darkTheme,
        themeMode: themeMode,
        initialRoute: AppRoutes.splash,
        getPages: AppPages.pages,
        builder: (ctx, child) => MediaQuery(
          data: MediaQuery.of(ctx).copyWith(
            textScaler: TextScaler.linear(scale),
          ),
          child: child!,
        ),
      );
    });
  }
}
