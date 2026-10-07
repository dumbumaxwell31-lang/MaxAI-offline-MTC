import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';

import 'hive_service.dart';

/// A numeric `major.minor.patch` version. Tags such as `v1.2.0`, `1.2` and
/// `1.2.0+5` (build metadata is ignored) are accepted.
class AppVersion implements Comparable<AppVersion> {
  const AppVersion(this.major, this.minor, this.patch);

  final int major;
  final int minor;
  final int patch;

  static final _pattern = RegExp(r'^[vV]?(\d+)(?:\.(\d+))?(?:\.(\d+))?$');

  /// Returns null for anything that is not a plain numeric version, including
  /// pre-release tags such as `1.2.0-beta`, so they are never offered.
  static AppVersion? tryParse(String? raw) {
    if (raw == null) return null;
    final value = raw.trim().split('+').first;
    final match = _pattern.firstMatch(value);
    if (match == null) return null;
    return AppVersion(
      int.parse(match.group(1)!),
      int.parse(match.group(2) ?? '0'),
      int.parse(match.group(3) ?? '0'),
    );
  }

  @override
  int compareTo(AppVersion other) {
    if (major != other.major) return major.compareTo(other.major);
    if (minor != other.minor) return minor.compareTo(other.minor);
    return patch.compareTo(other.patch);
  }

  bool operator >(AppVersion other) => compareTo(other) > 0;

  @override
  bool operator ==(Object other) =>
      other is AppVersion && compareTo(other) == 0;

  @override
  int get hashCode => Object.hash(major, minor, patch);

  @override
  String toString() => '$major.$minor.$patch';
}

class AppRelease {
  const AppRelease({
    required this.version,
    required this.name,
    this.notes = '',
    this.publishedAt,
  });

  final AppVersion version;
  final String name;
  final String notes;
  final DateTime? publishedAt;

  /// Parses the GitHub "latest release" JSON. Returns null when the payload is
  /// malformed, a draft/pre-release, or its tag is not a numeric version.
  static AppRelease? fromGitHubJson(Object? json) {
    if (json is! Map) return null;
    if (json['draft'] == true || json['prerelease'] == true) return null;
    final tag = json['tag_name'];
    final version = AppVersion.tryParse(tag is String ? tag : null);
    if (version == null) return null;
    final name = json['name'];
    final body = json['body'];
    final published = json['published_at'];
    return AppRelease(
      version: version,
      name: name is String && name.trim().isNotEmpty
          ? name.trim()
          : 'MaxAI $version',
      notes: body is String ? body.trim() : '',
      publishedAt: published is String ? DateTime.tryParse(published) : null,
    );
  }
}

enum UpdateCheckStatus {
  idle,
  checking,
  upToDate,
  updateAvailable,
  offline,
  failed,
  skipped,
}

/// Small key-value persistence used for update state only.
abstract class UpdateStateStore {
  Object? read(String key);
  Future<void> write(String key, Object? value);
}

class HiveUpdateStateStore implements UpdateStateStore {
  HiveUpdateStateStore(this._hive);
  final HiveService _hive;

  @override
  Object? read(String key) => _hive.getSetting<Object>(key);

  @override
  Future<void> write(String key, Object? value) =>
      _hive.setSetting(key, value);
}

typedef ReleaseFetcher = Future<http.Response> Function(Uri uri);
typedef ConnectivityChecker = Future<bool> Function();
typedef CurrentVersionReader = Future<String> Function();

/// Checks the official MaxAI GitHub repository for a newer release.
///
/// Every check runs in the background and never throws: offline devices,
/// DNS failures, timeouts, HTTP errors and malformed metadata all end in a
/// quiet state change. GitHub is only used to learn that a newer version
/// exists; the update itself goes through Google Play.
class AppUpdateService extends GetxService {
  AppUpdateService({
    UpdateStateStore? store,
    ReleaseFetcher? fetcher,
    ConnectivityChecker? connectivityChecker,
    CurrentVersionReader? currentVersionReader,
    DateTime Function()? clock,
  })  : _store = store,
        _fetcher = fetcher,
        _connectivityChecker = connectivityChecker,
        _currentVersionReader = currentVersionReader,
        _clock = clock ?? DateTime.now;

  /// Fixed at build time. Never read from remote data.
  static const repositoryOwner = 'dumbumaxwell31-lang';
  static const repositoryName = 'MaxAI-offline-MTC';
  static final latestReleaseUri = Uri.https(
    'api.github.com',
    '/repos/$repositoryOwner/$repositoryName/releases/latest',
  );

  static const checkInterval = Duration(hours: 24);
  static const requestTimeout = Duration(seconds: 10);
  static const connectivityTimeout = Duration(seconds: 3);

  static const keyLastCheckAt = 'app_update_last_check_ms';
  static const keyLatestVersion = 'app_update_latest_version';
  static const keyLatestName = 'app_update_latest_name';
  static const keyLatestNotes = 'app_update_latest_notes';
  static const keyDismissedVersion = 'app_update_dismissed_version';

  static const _channel = MethodChannel('com.maxai/app_update');

  UpdateStateStore? _store;
  final ReleaseFetcher? _fetcher;
  final ConnectivityChecker? _connectivityChecker;
  final CurrentVersionReader? _currentVersionReader;
  final DateTime Function() _clock;

  final status = UpdateCheckStatus.idle.obs;
  final currentVersion = ''.obs;

  /// The newer release, if any, regardless of whether it was dismissed.
  final latestRelease = Rx<AppRelease?>(null);

  /// The release to show in the update card, or null when nothing should show.
  final visibleUpdate = Rx<AppRelease?>(null);

  Future<void>? _inFlight;

  UpdateStateStore get _state =>
      _store ??= HiveUpdateStateStore(Get.find<HiveService>());

  /// Runs a check unless one ran within [checkInterval]. With [manual] the
  /// interval is ignored and a previously dismissed version is shown again.
  Future<void> checkForUpdates({bool manual = false}) {
    return _inFlight ??= _check(manual: manual).whenComplete(() {
      _inFlight = null;
    });
  }

  Future<void> _check({required bool manual}) async {
    try {
      final current = await _readCurrentVersion();
      if (current == null) {
        status.value = UpdateCheckStatus.failed;
        return;
      }

      if (!manual && _checkedRecently()) {
        _restoreCachedRelease(current);
        if (status.value == UpdateCheckStatus.idle) {
          status.value = UpdateCheckStatus.skipped;
        }
        return;
      }

      status.value = UpdateCheckStatus.checking;
      if (!await _hasInternet()) {
        // Offline is normal for MaxAI. Not an attempt, so retry next launch.
        status.value = UpdateCheckStatus.offline;
        _restoreCachedRelease(current);
        return;
      }

      await _state.write(keyLastCheckAt, _clock().millisecondsSinceEpoch);
      final response =
          await (_fetcher ?? _defaultFetch)(latestReleaseUri)
              .timeout(requestTimeout);

      if (response.statusCode == 404) {
        // The repository has no published release yet.
        _apply(current, null, manual: manual);
        return;
      }
      if (response.statusCode != 200) {
        status.value = UpdateCheckStatus.failed;
        return;
      }

      final release = AppRelease.fromGitHubJson(jsonDecode(response.body));
      if (release == null) {
        status.value = UpdateCheckStatus.failed;
        return;
      }
      await _state.write(keyLatestVersion, release.version.toString());
      await _state.write(keyLatestName, release.name);
      await _state.write(keyLatestNotes, release.notes);
      _apply(current, release, manual: manual);
    } catch (_) {
      // Update checks must never affect the app.
      status.value = UpdateCheckStatus.failed;
    }
  }

  void _apply(AppVersion current, AppRelease? release,
      {required bool manual}) {
    if (release == null || !(release.version > current)) {
      latestRelease.value = null;
      visibleUpdate.value = null;
      status.value = UpdateCheckStatus.upToDate;
      return;
    }
    latestRelease.value = release;
    final dismissed = AppVersion.tryParse(_readString(keyDismissedVersion));
    final isDismissed = dismissed != null && dismissed == release.version;
    visibleUpdate.value = manual || !isDismissed ? release : null;
    status.value = UpdateCheckStatus.updateAvailable;
  }

  void _restoreCachedRelease(AppVersion current) {
    final version = AppVersion.tryParse(_readString(keyLatestVersion));
    if (version == null || !(version > current)) return;
    final release = AppRelease(
      version: version,
      name: _readString(keyLatestName) ?? 'MaxAI $version',
      notes: _readString(keyLatestNotes) ?? '',
    );
    _apply(current, release, manual: false);
  }

  bool _checkedRecently() {
    final last = _state.read(keyLastCheckAt);
    if (last is! int) return false;
    final elapsed = _clock().difference(
      DateTime.fromMillisecondsSinceEpoch(last),
    );
    return !elapsed.isNegative && elapsed < checkInterval;
  }

  /// "Later": hide the card for this version until a newer one appears.
  Future<void> dismiss() async {
    final release = visibleUpdate.value;
    visibleUpdate.value = null;
    if (release == null) return;
    try {
      await _state.write(keyDismissedVersion, release.version.toString());
    } catch (_) {}
  }

  /// Opens this app's Google Play page. Nothing is downloaded or installed.
  Future<bool> openStoreListing() async {
    try {
      return await _channel.invokeMethod<bool>('openPlayStore') ?? false;
    } catch (_) {
      return false;
    }
  }

  String? _readString(String key) {
    final value = _state.read(key);
    return value is String && value.isNotEmpty ? value : null;
  }

  Future<AppVersion?> _readCurrentVersion() async {
    final raw = await (_currentVersionReader ?? _defaultCurrentVersion)();
    currentVersion.value = raw;
    return AppVersion.tryParse(raw);
  }

  Future<bool> _hasInternet() async {
    final checker = _connectivityChecker;
    if (checker != null) return checker();
    try {
      final result = await InternetAddress.lookup(latestReleaseUri.host)
          .timeout(connectivityTimeout);
      return result.isNotEmpty && result.first.rawAddress.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  static Future<String> _defaultCurrentVersion() async {
    final info = await PackageInfo.fromPlatform();
    return info.version;
  }

  static Future<http.Response> _defaultFetch(Uri uri) {
    return http.get(uri, headers: const {
      'Accept': 'application/vnd.github+json',
      'User-Agent': 'MaxAI-Android-UpdateCheck',
    });
  }
}
