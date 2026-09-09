// Custom build: Wake-on-LAN through an always-on relay PC (see
// scripts/ops/wol_relay.py in the algo_trader repo). The relay learns the
// MAC addresses of the PCs on its LAN once, and this client only needs the
// relay address (host:port, reachable over Tailscale).
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../consts.dart';
import '../models/platform_model.dart';

class WolTarget {
  final String name;
  final String label;
  final String mac;
  final String? lastIp;
  final String? source;
  final String? learnedAt;
  final bool up;

  WolTarget({
    required this.name,
    required this.label,
    required this.mac,
    this.lastIp,
    this.source,
    this.learnedAt,
    this.up = false,
  });

  factory WolTarget.fromJson(Map<String, dynamic> j) => WolTarget(
        name: (j['name'] ?? '') as String,
        label: (j['label'] ?? j['name'] ?? '') as String,
        mac: (j['mac'] ?? '') as String,
        lastIp: j['last_ip'] as String?,
        source: j['source'] as String?,
        learnedAt: j['learned_at'] as String?,
        up: j['up'] == true,
      );
}

class WolRelay {
  static const Duration _timeout = Duration(seconds: 8);

  /// Relay address as "host:port". Falls back to [kDefaultWolRelay].
  static String get address {
    final v = bind.mainGetLocalOption(key: kOptionCustomWolRelay).trim();
    return v.isEmpty ? kDefaultWolRelay : v;
  }

  static Future<void> setAddress(String v) =>
      bind.mainSetLocalOption(key: kOptionCustomWolRelay, value: v.trim());

  static Uri _uri(String path, [Map<String, String>? query]) =>
      Uri.parse('http://$address$path')
          .replace(queryParameters: query == null || query.isEmpty ? null : query);

  static Map<String, dynamic> _decode(http.Response r) {
    final j = jsonDecode(utf8.decode(r.bodyBytes));
    if (j is! Map<String, dynamic>) {
      throw Exception('unexpected response');
    }
    if (r.statusCode != 200 || j['ok'] != true) {
      throw Exception(j['error']?.toString() ?? 'HTTP ${r.statusCode}');
    }
    return j;
  }

  static List<WolTarget> _targetsOf(Map<String, dynamic> j) =>
      ((j['targets'] ?? []) as List)
          .map((e) => WolTarget.fromJson(e as Map<String, dynamic>))
          .toList();

  /// List the targets the relay knows (with an "up" probe per target).
  static Future<List<WolTarget>> targets() async {
    final r = await http.get(_uri('/targets')).timeout(_timeout);
    return _targetsOf(_decode(r));
  }

  /// Ask the relay to re-scan its LAN (only needed when a PC was added).
  static Future<List<WolTarget>> rescan() async {
    final r = await http
        .post(_uri('/scan'))
        .timeout(const Duration(seconds: 30));
    return _targetsOf(_decode(r));
  }

  /// Find a learned target by the peer's hostname (case-insensitive).
  static Future<WolTarget?> findByHostname(String hostname) async {
    final h = hostname.split('.').first.toUpperCase();
    if (h.isEmpty) return null;
    for (final t in await targets()) {
      if (t.name.toUpperCase() == h || t.label.toUpperCase() == h) return t;
    }
    return null;
  }

  /// Wake by relay target name or by raw MAC. Returns the packet count sent.
  static Future<int> wake({String? name, String? mac}) async {
    final uri = name != null
        ? _uri('/wake/${Uri.encodeComponent(name)}')
        : _uri('/wake', {'mac': mac ?? ''});
    final r = await http.post(uri).timeout(_timeout);
    return (_decode(r)['sent'] ?? 0) as int;
  }

  static Future<bool> isUp(String name) async {
    final r = await http
        .get(_uri('/status/${Uri.encodeComponent(name)}'))
        .timeout(_timeout);
    return _decode(r)['up'] == true;
  }

  /// Send a magic packet from this device directly (works only when the
  /// phone is on the same LAN as the target, e.g. home Wi-Fi).
  static Future<int> sendMagicPacketDirect(String mac, {int repeat = 3}) async {
    final hex = mac.replaceAll(RegExp(r'[^0-9A-Fa-f]'), '');
    if (hex.length != 12) throw Exception('invalid MAC: $mac');
    final macBytes = List<int>.generate(
        6, (i) => int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16));
    final packet = <int>[...List.filled(6, 0xff)];
    for (var i = 0; i < 16; i++) {
      packet.addAll(macBytes);
    }
    final sock = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    try {
      sock.broadcastEnabled = true;
      var sent = 0;
      for (var i = 0; i < repeat; i++) {
        sent += sock.send(packet, InternetAddress('255.255.255.255'), 9) > 0 ? 1 : 0;
      }
      return sent;
    } finally {
      sock.close();
    }
  }
}
