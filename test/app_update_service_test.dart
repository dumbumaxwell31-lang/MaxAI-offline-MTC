import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:maxai/services/app_update_service.dart';

class _MemoryStore implements UpdateStateStore {
  final values = <String, Object?>{};

  @override
  Object? read(String key) => values[key];

  @override
  Future<void> write(String key, Object? value) async => values[key] = value;
}

http.Response _release(String tag, {String notes = '- Bug fixes'}) =>
    http.Response(
      jsonEncode({
        'tag_name': tag,
        'name': 'MaxAI ${tag.replaceFirst('v', '')}',
        'body': notes,
        'published_at': '2026-10-01T10:00:00Z',
        'draft': false,
        'prerelease': false,
      }),
      200,
    );

void main() {
  group('AppVersion', () {
    test('compares numerically, not as strings', () {
      const v = AppVersion.tryParse;
      expect(v('1.0.0')!.compareTo(v('1.1.0')!), lessThan(0));
      expect(v('1.1.0')!.compareTo(v('1.2.0')!), lessThan(0));
      expect(v('1.2.0')!.compareTo(v('2.0.0')!), lessThan(0));
      expect(v('1.10.0')! > v('1.9.0')!, isTrue);
    });

    test('treats equal versions as equal', () {
      expect(AppVersion.tryParse('v1.0.5'), AppVersion.tryParse('1.0.5'));
      expect(AppVersion.tryParse('1.0.5+5'), AppVersion.tryParse('1.0.5'));
      expect(AppVersion.tryParse('1.2'), AppVersion.tryParse('1.2.0'));
    });

    test('rejects malformed and pre-release versions', () {
      for (final raw in [null, '', 'latest', '1.x.0', '1.2.3.4', '1.2.0-beta']) {
        expect(AppVersion.tryParse(raw), isNull, reason: '$raw');
      }
    });
  });

  group('AppUpdateService', () {
    late _MemoryStore store;
    late DateTime now;
    late int fetches;

    AppUpdateService service({
      String current = '1.0.5',
      bool online = true,
      Future<http.Response> Function(Uri)? fetch,
    }) {
      return AppUpdateService(
        store: store,
        currentVersionReader: () async => current,
        connectivityChecker: () async => online,
        clock: () => now,
        fetcher: (uri) {
          fetches++;
          expect(uri, AppUpdateService.latestReleaseUri);
          return (fetch ?? (_) async => _release('v1.0.5'))(uri);
        },
      );
    }

    setUp(() {
      store = _MemoryStore();
      now = DateTime(2026, 10, 8, 12);
      fetches = 0;
    });

    test('newer release shows the update card with notes', () async {
      final updates = service(fetch: (_) async => _release('v1.1.0'));
      await updates.checkForUpdates();

      expect(updates.status.value, UpdateCheckStatus.updateAvailable);
      expect(updates.visibleUpdate.value!.version.toString(), '1.1.0');
      expect(updates.visibleUpdate.value!.notes, contains('Bug fixes'));
      expect(store.values[AppUpdateService.keyLatestVersion], '1.1.0');
    });

    test('current equal to latest shows nothing', () async {
      final updates = service(fetch: (_) async => _release('v1.0.5'));
      await updates.checkForUpdates();

      expect(updates.status.value, UpdateCheckStatus.upToDate);
      expect(updates.visibleUpdate.value, isNull);
    });

    test('current newer than latest shows nothing', () async {
      final updates =
          service(current: '2.0.0', fetch: (_) async => _release('v1.9.9'));
      await updates.checkForUpdates();

      expect(updates.status.value, UpdateCheckStatus.upToDate);
      expect(updates.visibleUpdate.value, isNull);
    });

    test('repository without releases counts as up to date', () async {
      final updates = service(fetch: (_) async => http.Response('{}', 404));
      await updates.checkForUpdates();

      expect(updates.status.value, UpdateCheckStatus.upToDate);
      expect(updates.visibleUpdate.value, isNull);
    });

    test('offline skips the request entirely', () async {
      final updates = service(online: false);
      await updates.checkForUpdates();

      expect(fetches, 0);
      expect(updates.status.value, UpdateCheckStatus.offline);
      expect(updates.visibleUpdate.value, isNull);
      expect(store.values[AppUpdateService.keyLastCheckAt], isNull);
    });

    test('network failure and timeout are handled silently', () async {
      final failing = service(
        fetch: (_) async => throw http.ClientException('Failed host lookup'),
      );
      await expectLater(failing.checkForUpdates(), completes);
      expect(failing.status.value, UpdateCheckStatus.failed);
      expect(failing.visibleUpdate.value, isNull);

      store = _MemoryStore();
      final slow = service(fetch: (_) => Completer<http.Response>().future);
      await expectLater(
        Future(() => slow.checkForUpdates()),
        completes,
      );
      expect(slow.status.value, UpdateCheckStatus.failed);
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('server errors and malformed metadata are ignored', () async {
      final error = service(fetch: (_) async => http.Response('oops', 500));
      await error.checkForUpdates();
      expect(error.status.value, UpdateCheckStatus.failed);

      store = _MemoryStore();
      final malformed =
          service(fetch: (_) async => http.Response('not json', 200));
      await malformed.checkForUpdates();
      expect(malformed.status.value, UpdateCheckStatus.failed);

      store = _MemoryStore();
      final badTag = service(fetch: (_) async => _release('nightly'));
      await badTag.checkForUpdates();
      expect(badTag.status.value, UpdateCheckStatus.failed);
      expect(badTag.visibleUpdate.value, isNull);
    });

    test('checks at most once per 24 hours unless manual', () async {
      final updates = service(fetch: (_) async => _release('v1.1.0'));
      await updates.checkForUpdates();
      expect(fetches, 1);

      now = now.add(const Duration(hours: 23));
      final next = service(fetch: (_) async => _release('v1.1.0'));
      await next.checkForUpdates();
      expect(fetches, 1, reason: 'cached interval');
      expect(next.visibleUpdate.value!.version.toString(), '1.1.0',
          reason: 'cached latest version is still shown');

      await next.checkForUpdates(manual: true);
      expect(fetches, 2, reason: 'manual check ignores the interval');

      now = now.add(const Duration(hours: 25));
      await service().checkForUpdates();
      expect(fetches, 3, reason: 'interval elapsed since the manual check');
    });

    test('Later hides that version until a manual check', () async {
      final updates = service(fetch: (_) async => _release('v1.1.0'));
      await updates.checkForUpdates();
      await updates.dismiss();
      expect(updates.visibleUpdate.value, isNull);

      now = now.add(const Duration(days: 2));
      final again = service(fetch: (_) async => _release('v1.1.0'));
      await again.checkForUpdates();
      expect(again.status.value, UpdateCheckStatus.updateAvailable);
      expect(again.visibleUpdate.value, isNull);

      await again.checkForUpdates(manual: true);
      expect(again.visibleUpdate.value, isNotNull);

      now = now.add(const Duration(days: 2));
      final newer = service(fetch: (_) async => _release('v1.2.0'));
      await newer.checkForUpdates();
      expect(newer.visibleUpdate.value!.version.toString(), '1.2.0');
    });
  });
}
