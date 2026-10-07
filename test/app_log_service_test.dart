import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:maxai/services/app_log_service.dart';
import 'package:maxai/services/crash_reporting_service.dart';

void main() {
  tearDown(Get.reset);

  test('an error log does not recurse through crash reporting', () {
    final log = Get.put(AppLogService());
    Get.put(CrashReportingService());

    log.error('google_fonts failed', details: 'offline');

    // Original error plus one crash-report entry, no runaway recursion.
    expect(log.entries.length, 2);
    expect(log.entries.last.message, 'google_fonts failed');
  });
}
