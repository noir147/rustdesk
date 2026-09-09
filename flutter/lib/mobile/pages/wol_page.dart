// Custom build: Wake-on-LAN page. Lists the PCs learned by the relay and
// wakes them through it (or directly, when on the same LAN).
import 'dart:async';

import 'package:flutter/material.dart';

import '../../common.dart';
import '../../common/wol_relay.dart';

class WolPage extends StatefulWidget {
  const WolPage({Key? key}) : super(key: key);

  @override
  State<WolPage> createState() => _WolPageState();
}

class _WolPageState extends State<WolPage> {
  final _addr = TextEditingController(text: WolRelay.address);
  List<WolTarget> _targets = [];
  bool _loading = false;
  String? _error;
  final Map<String, String> _msg = {};
  final Map<String, Timer> _polls = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final t in _polls.values) {
      t.cancel();
    }
    _addr.dispose();
    super.dispose();
  }

  Future<void> _load({bool rescan = false}) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list = rescan ? await WolRelay.rescan() : await WolRelay.targets();
      if (!mounted) return;
      setState(() => _targets = list);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _wake(WolTarget t, {bool direct = false}) async {
    setState(() => _msg[t.name] = direct ? 'Sending (direct)…' : 'Sending via relay…');
    try {
      final n = direct
          ? await WolRelay.sendMagicPacketDirect(t.mac)
          : await WolRelay.wake(name: t.name);
      if (!mounted) return;
      setState(() => _msg[t.name] = 'Sent $n packets. Waiting for ${t.label}…');
      _polls[t.name]?.cancel();
      var k = 0;
      _polls[t.name] = Timer.periodic(const Duration(seconds: 3), (timer) async {
        k++;
        bool up = false;
        try {
          up = await WolRelay.isUp(t.name);
        } catch (_) {}
        if (!mounted) {
          timer.cancel();
          return;
        }
        if (up || k >= 30) {
          timer.cancel();
          setState(() {
            _msg[t.name] = up ? 'Online' : 'No response within 90s';
            if (up) {
              _targets = _targets
                  .map((x) => x.name == t.name
                      ? WolTarget(
                          name: x.name,
                          label: x.label,
                          mac: x.mac,
                          lastIp: x.lastIp,
                          source: x.source,
                          learnedAt: x.learnedAt,
                          up: true)
                      : x)
                  .toList();
            }
          });
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _msg[t.name] = 'Failed: $e');
    }
  }

  Widget _card(WolTarget t) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(Icons.circle,
                  size: 12, color: t.up ? Colors.green : Colors.orange),
              const SizedBox(width: 8),
              Expanded(
                  child: Text(t.label,
                      style: theme.textTheme.titleMedium,
                      overflow: TextOverflow.ellipsis)),
            ]),
            Text('${t.name}  ${t.mac}${t.lastIp != null ? '  ${t.lastIp}' : ''}',
                style: theme.textTheme.bodySmall),
            Text(t.up ? 'Online' : 'Offline / sleeping',
                style: TextStyle(color: t.up ? Colors.green : Colors.orange)),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(
                child: ElevatedButton.icon(
                  icon: const Icon(Icons.power_settings_new),
                  label: const Text('Wake (relay)'),
                  onPressed: () => _wake(t),
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: () => _wake(t, direct: true),
                child: const Text('Direct'),
              ),
            ]),
            if (_msg[t.name] != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(_msg[t.name]!, style: theme.textTheme.bodySmall),
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Wake-on-LAN'),
        actions: [
          IconButton(
            tooltip: 'Rescan LAN (only when a PC was added)',
            icon: const Icon(Icons.radar),
            onPressed: _loading ? null : () => _load(rescan: true),
          ),
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : () => _load(),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
            child: TextField(
              controller: _addr,
              decoration: const InputDecoration(
                labelText: 'Relay (always-on PC, host:port over Tailscale)',
                hintText: '100.77.70.61:5055',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              keyboardType: TextInputType.url,
              onSubmitted: (v) async {
                await WolRelay.setAddress(v);
                _load();
              },
            ),
          ),
          if (_loading) const LinearProgressIndicator(),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text('Relay error: $_error',
                  style: const TextStyle(color: Colors.red)),
            ),
          Expanded(
            child: _targets.isEmpty && !_loading
                ? Center(
                    child: Text(translate('Empty')),
                  )
                : ListView(children: _targets.map(_card).toList()),
          ),
        ],
      ),
    );
  }
}
