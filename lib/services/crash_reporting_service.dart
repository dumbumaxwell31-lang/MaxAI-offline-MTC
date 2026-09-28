import 'package:flutter/material.dart';
import 'package:get/get.dart';

import 'app_log_service.dart';

/// Records diagnostic context locally without sending data off-device.
class CrashReportingService extends GetxService {
  Future<CrashReportingService> init() async {
    Get.find<AppLogService>().info('Local crash diagnostics initialized');
    return this;
  }

  Future<void> recordFlutterFatal(FlutterErrorDetails details) async {
    Get.find<AppLogService>().error(
      'Flutter fatal error',
      details: details.stack?.toString() ?? details.exceptionAsString(),
    );
  }

  Future<void> recordFatal(
    Object error,
    StackTrace stack, {
    String reason = 'fatal',
  }) async {
    Get.find<AppLogService>().error(
      'Fatal error: $reason',
      details: '$error\n$stack',
    );
  }

  Future<void> recordNonFatal(
    Object error, {
    StackTrace? stack,
    String reason = 'nonfatal',
    Map<String, Object?> extra = const {},
  }) async {
    Get.find<AppLogService>().error(
      'Non-fatal error: $reason',
      details: '$error\n${stack ?? StackTrace.current}\n$extra',
    );
  }

  void log(String message) => Get.find<AppLogService>().info(message);
}
