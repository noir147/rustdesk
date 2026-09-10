// Custom build: semi-automatic self update from the fork's GitHub releases.
//
// On startup (Android, Wi-Fi only by default) the app fetches
// https://api.github.com/repos/<kCustomUpdateRepo>/releases/latest, compares
// the release tag (custom-<ver>-tvN) with the built-in kCustomBuildTag and,
// if newer, offers to download the arm64 APK and hand it to the Android
// package installer. Android always asks for one final confirmation tap;
// that part cannot be automated for side-loaded apps.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../common.dart';
import '../consts.dart';
import '../models/model.dart';
import '../models/platform_model.dart';

class CustomRelease {
  final String tag;
  final int build;
  final String apkUrl;
  final String apkName;
  final String notes;
  CustomRelease(this.tag, this.build, this.apkUrl, this.apkName, this.notes);
}

class CustomUpdate {
  static bool _busy = false;
  static const _apiUrl =
      'https://api.github.com/repos/$kCustomUpdateRepo/releases/latest';

  static int get currentBuild => parseBuild(kCustomBuildTag) ?? 0;

  /// "custom-1.4.9-tv12" / "tv12" -> 12
  static int? parseBuild(String s) {
    final m = RegExp(r'tv(\d+)').firstMatch(s);
    return m == null ? null : int.tryParse(m.group(1)!);
  }

  static Future<CustomRelease?> fetchLatest() async {
    final r = await http.get(Uri.parse(_apiUrl), headers: {
      'Accept': 'application/vnd.github+json',
      'User-Agent': 'rdcustom-updater'
    }).timeout(const Duration(seconds: 15));
    if (r.statusCode != 200) throw Exception('GitHub API HTTP ${r.statusCode}');
    final j = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
    final tag = (j['tag_name'] ?? '') as String;
    final build = parseBuild(tag);
    if (build == null) return null;
    final assets = (j['assets'] as List? ?? []).cast<Map<String, dynamic>>();
    Map<String, dynamic>? apk;
    for (final a in assets) {
      final n = (a['name'] ?? '') as String;
      if (n.endsWith('-aarch64.apk')) {
        // prefer the locally signed build if both exist
        if (apk == null || n.contains('-local-')) apk = a;
      }
    }
    if (apk == null) return null;
    return CustomRelease(tag, build, apk['browser_download_url'] as String,
        apk['name'] as String, (j['body'] ?? '') as String);
  }

  /// Startup hook. Silent unless a newer build exists.
  static Future<void> checkOnStartup(BuildContext context) async {
    if (!isAndroid) return;
    if (!mainGetLocalBoolOptionSync(kOptionCustomAutoUpdate)) return;
    try {
      final wifi = await gFFI.invokeMethod('is_on_wifi');
      if (!wifi) return;
      final rel = await fetchLatest();
      if (rel == null || rel.build <= currentBuild) return;
      final skipped = bind.mainGetLocalOption(key: kOptionCustomSkipBuild);
      if (skipped == rel.tag) return;
      if (!context.mounted) return;
      await _offer(context, rel, fromStartup: true);
    } catch (e) {
      debugPrint('[custom-update] startup check failed: $e');
    }
  }

  /// Manual check from Settings.
  static Future<void> checkNow(BuildContext context) async {
    if (_busy) return;
    try {
      final rel = await fetchLatest();
      if (!context.mounted) return;
      if (rel == null) {
        showToast('No release found');
      } else if (rel.build <= currentBuild) {
        showToast('Up to date ($kCustomBuildTag, latest ${rel.tag})');
      } else {
        await _offer(context, rel, fromStartup: false);
      }
    } catch (e) {
      showToast('Update check failed: $e');
    }
  }

  static Future<void> _offer(BuildContext context, CustomRelease rel,
      {required bool fromStartup}) async {
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Update available: ${rel.tag}'),
        content: SingleChildScrollView(
          child: Text(
              'Installed: $kCustomBuildTag\n\n${rel.notes.isEmpty ? rel.apkName : rel.notes}'),
        ),
        actions: [
          if (fromStartup)
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'skip'),
              child: const Text('Skip this version'),
            ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'later'),
            child: const Text('Later'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, 'update'),
            child: const Text('Download & install'),
          ),
        ],
      ),
    );
    if (choice == 'skip') {
      await bind.mainSetLocalOption(key: kOptionCustomSkipBuild, value: rel.tag);
    } else if (choice == 'update' && context.mounted) {
      await downloadAndInstall(context, rel);
    }
  }

  static Future<void> downloadAndInstall(
      BuildContext context, CustomRelease rel) async {
    if (_busy) return;
    _busy = true;
    final progress = ValueNotifier<double?>(null);
    final status = ValueNotifier<String>('Downloading ${rel.apkName}…');
    bool dialogOpen = true;
    // progress dialog (not dismissible)
    // ignore: unawaited_futures
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: Text('Updating to ${rel.tag}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ValueListenableBuilder<String>(
                valueListenable: status, builder: (_, s, __) => Text(s)),
            const SizedBox(height: 12),
            ValueListenableBuilder<double?>(
                valueListenable: progress,
                builder: (_, p, __) => LinearProgressIndicator(value: p)),
          ],
        ),
      ),
    ).then((_) => dialogOpen = false);
    try {
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/rdcustom-update-${rel.tag}.apk');
      final client = http.Client();
      try {
        final req = http.Request('GET', Uri.parse(rel.apkUrl))
          ..headers['User-Agent'] = 'rdcustom-updater';
        final resp = await client.send(req).timeout(const Duration(seconds: 30));
        if (resp.statusCode != 200) {
          throw Exception('download HTTP ${resp.statusCode}');
        }
        final total = resp.contentLength ?? 0;
        var got = 0;
        final sink = file.openWrite();
        await for (final chunk in resp.stream) {
          sink.add(chunk);
          got += chunk.length;
          if (total > 0) progress.value = got / total;
        }
        await sink.close();
      } finally {
        client.close();
      }
      status.value = 'Opening installer…';
      final ok = await gFFI.invokeMethod('install_apk', file.path);
      if (!ok) {
        status.value =
            'Allow "install unknown apps" for this app, then tap Download & install again.';
        await Future.delayed(const Duration(seconds: 4));
      }
    } catch (e) {
      status.value = 'Failed: $e';
      await Future.delayed(const Duration(seconds: 4));
    } finally {
      _busy = false;
      if (dialogOpen && context.mounted) Navigator.of(context).pop();
    }
  }
}
