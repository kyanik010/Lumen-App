import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import '../widgets.dart';

/// Stremio addon marketplace and installed-addon manager.
class StremioAddonsScreen extends StatefulWidget {
  const StremioAddonsScreen({super.key});

  @override
  State<StremioAddonsScreen> createState() => _StremioAddonsScreenState();
}

class _StremioAddonsScreenState extends State<StremioAddonsScreen> {
  static const _storageKey = 'eagle_x_stremio_addons_v1';
  static const _officialUrl = 'https://api.strem.io/addonscollection.json';
  static const _communityUrl = 'https://stremio-addons.net/api/v0/addons?sort_by=stars&order=desc&limit=100&page=1';
  static const _legacyCommunityUrl = 'https://stremio-addons.com/addon_catalog/all/community.json';
  static const _defaultAddons = <Map<String, dynamic>>[
    {
      'id': 'com.linvo.cinemeta', 'name': 'Cinemeta', 'version': '3.0.14',
      'description': 'The official addon for movie and series catalogs',
      'url': 'https://v3-cinemeta.strem.io/manifest.json',
      'types': ['movie', 'series'], 'resources': ['catalog', 'meta', 'addon_catalog'], 'enabled': true,
    },
    {
      'id': 'org.stremio.opensubtitlesv3', 'name': 'OpenSubtitles V3', 'version': '1.0.0',
      'description': 'Official OpenSubtitles v3 subtitle addon',
      'url': 'https://opensubtitles-v3.strem.io/manifest.json',
      'types': ['movie', 'series'], 'resources': ['subtitles'], 'enabled': true,
    },
    {
      'id': 'opensubtitles-pro', 'name': 'OpenSubtitles PRO', 'version': '0.1.0',
      'description': 'Community subtitle addon',
      'url': 'https://opensubtitlesv3-pro.dexter21767.com/manifest.json',
      'types': ['movie', 'series'], 'resources': ['subtitles'], 'enabled': true,
    },
  ];
  final _search = TextEditingController();
  final _url = TextEditingController();
  final _client = http.Client();
  List<Map<String, dynamic>> _installed = [];
  List<Map<String, dynamic>> _official = [];
  List<Map<String, dynamic>> _community = [];
  String _tab = 'installed';
  bool _loading = true;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadInstalled();
    _loadMarket();
  }

  @override
  void dispose() {
    _search.dispose();
    _url.dispose();
    _client.close();
    super.dispose();
  }

  Future<void> _loadInstalled() async {
    final prefs = await SharedPreferences.getInstance();
    List<Map<String, dynamic>> loaded = [];
    final raw = prefs.getString(_storageKey);
    if (raw != null) {
      try {
        final parsed = jsonDecode(raw);
        if (parsed is List) {
          loaded = parsed.whereType<Map>().map((e) =>
            Map<String, dynamic>.from(e)).toList();
        }
      } catch (_) {}
    }
    var changed = false;
    for (final seed in _defaultAddons) {
      final index = loaded.indexWhere(
        (e) => e['id'] == seed['id'] || e['url'] == seed['url'],
      );
      if (index < 0) {
        loaded.add(Map<String, dynamic>.from(seed));
        changed = true;
        continue;
      }

      // Older installs may have persisted these defaults with incomplete
      // manifest metadata. Merge the seed back in so subtitle resources and
      // the canonical manifest URL remain usable after an app update, while
      // preserving the user's enabled/disabled choice.
      final existing = loaded[index];
      final merged = <String, dynamic>{...seed, ...existing};
      for (final field in const ['id', 'name', 'version', 'url']) {
        if ((merged[field] ?? '').toString().trim().isEmpty) {
          merged[field] = seed[field];
        }
      }
      for (final field in const ['types', 'resources']) {
        final values = merged[field];
        if (values is! List || values.isEmpty) {
          merged[field] = seed[field];
        }
      }
      if (merged['enabled'] is! bool) merged['enabled'] = true;
      if (jsonEncode(existing) != jsonEncode(merged)) {
        loaded[index] = merged;
        changed = true;
      }
    }
    _installed = loaded;
    if (changed || raw == null) {
      await prefs.setString(_storageKey, jsonEncode(_installed));
    }
    if (mounted) setState(() {});
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_storageKey, jsonEncode(_installed));
  }

  Map<String, dynamic>? _marketEntry(dynamic raw) {
    if (raw is! Map) return null;
    final manifest = raw['manifest'];
    final transport = raw['transportUrl'] ?? raw['manifestUrl'];
    if (manifest is! Map || transport is! String || transport.isEmpty) return null;
    final hints = manifest['behaviorHints'];
    final configurationRequired =
        (hints is Map && hints['configurationRequired'] == true) ||
        transport.contains('/[config]/');
    var configureUrl = (raw['configureUrl'] ?? '').toString();
    if (configureUrl.isEmpty && configurationRequired) {
      configureUrl = transport.replaceFirst('/[config]', '');
      if (configureUrl.endsWith('/manifest.json')) {
        configureUrl = configureUrl.substring(
          0,
          configureUrl.length - '/manifest.json'.length,
        );
      }
      configureUrl += '/configure';
    }
    return {
      'id': manifest['id']?.toString() ?? transport,
      'name': manifest['name']?.toString() ?? 'Unknown addon',
      'description': manifest['description']?.toString() ?? '',
      'version': manifest['version']?.toString() ?? '',
      'logo': manifest['logo']?.toString() ?? '',
      'url': transport,
      'configureUrl': configureUrl,
      'configurationRequired': configurationRequired,
      'configurable': hints is Map && hints['configurable'] == true,
      'types': _stringList(manifest['types']),
      'resources': _stringList(manifest['resources']),
      'enabled': true,
    };
  }

  List<String> _stringList(dynamic raw) {
    if (raw is! List) return [];
    return raw.map((e) => e is Map ? (e['name'] ?? '').toString() : e.toString())
      .where((e) => e.isNotEmpty).toList();
  }

  Future<List<Map<String, dynamic>>> _getJsonList(String url) async {
    final response = await _client.get(Uri.parse(url)).timeout(const Duration(seconds: 25));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('HTTP ${response.statusCode}');
    }
    final body = jsonDecode(response.body);
    dynamic list = body;
    if (body is Map) list = body['addons'] ?? body['results'] ?? body['data'] ?? [];
    if (list is! List) return [];
    return list.map(_marketEntry).whereType<Map<String, dynamic>>().toList();
  }

  Future<void> _loadMarket() async {
    if (mounted) setState(() { _loading = true; _error = null; });
    try {
      final officialFuture = _getJsonList(_officialUrl);
      Future<List<Map<String, dynamic>>> communityFuture() async {
        try {
          final first = await _getJsonList(_communityUrl);
          if (first.isNotEmpty) return first;
        } catch (_) {}
        return _getJsonList(_legacyCommunityUrl);
      }
      final results = await Future.wait([officialFuture, communityFuture()]);
      if (!mounted) return;
      setState(() {
        _official = results[0];
        _community = results[1];
        _loading = false;
        if (_official.isEmpty && _community.isEmpty) {
          _error = 'تعذر تحميل السوق الآن. يمكنك التثبيت باستخدام رابط Manifest.';
        }
      });
    } catch (_) {
      if (mounted) setState(() {
        _loading = false;
        _error = 'تعذر الاتصال بسوق الإضافات. تحقق من الإنترنت أو استخدم رابط Manifest.';
      });
    }
  }

  bool _isInstalled(Map<String, dynamic> item) =>
      _installed.any((e) => e['id'] == item['id'] || e['url'] == item['url']);

  List<Map<String, dynamic>> get _visible {
    final source = _tab == 'installed' ? _installed : _tab == 'official' ? _official : _community;
    final q = _search.text.trim().toLowerCase();
    return source.where((e) => q.isEmpty ||
      '${e['name']} ${e['description']} ${e['id']}'.toLowerCase().contains(q)).toList();
  }

  Future<void> _install(Map<String, dynamic> item) async {
    if (_isInstalled(item)) return;
    setState(() => _busy = true);
    try {
      var url = item['url'].toString().trim();
      var uri = Uri.tryParse(url);
      if (uri == null || !uri.hasScheme ||
          !(uri.scheme == 'https' || uri.scheme == 'http')) {
        throw Exception('رابط Manifest غير صالح');
      }
      if (item['configurationRequired'] == true || url.contains('/[config]/')) {
        var configureUrl = (item['configureUrl'] ?? '').toString();
        if (configureUrl.isEmpty) {
          configureUrl = url.replaceFirst('/[config]', '');
          if (configureUrl.endsWith('/manifest.json')) {
            configureUrl = configureUrl.substring(
              0,
              configureUrl.length - '/manifest.json'.length,
            );
          }
          configureUrl += '/configure';
        }
        final configureUri = Uri.tryParse(configureUrl);
        var opened = false;
        if (configureUri != null) {
          try {
            opened = await launchUrl(
              configureUri,
              mode: LaunchMode.externalApplication,
            );
          } catch (_) {
            opened = false;
          }
        }
        if (!opened) {
          await Clipboard.setData(ClipboardData(text: configureUrl));
        }
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(opened
                ? 'تم فتح صفحة إعداد الإضافة. بعد الإعداد أضف رابط Manifest الناتج.'
                : 'تعذّر فتح المتصفح؛ نُسخ رابط الإعداد. بعد الإعداد أضف رابط Manifest الناتج.'),
            duration: const Duration(seconds: 5),
          ));
        }
        return;
      }

      http.Response? response;
      Map<String, dynamic>? manifest;
      final candidates = <Uri>[uri];
      if (!url.endsWith('/manifest.json')) {
        candidates.add(Uri.parse('${url.replaceFirst(RegExp(r'/$'), '')}/manifest.json'));
      }
      Object? lastError;
      for (final candidate in candidates) {
        try {
          final candidateResponse = await _client.get(candidate).timeout(const Duration(seconds: 30));
          if (candidateResponse.statusCode < 200 || candidateResponse.statusCode >= 300) {
            lastError = Exception('HTTP ${candidateResponse.statusCode}');
            continue;
          }
          final decoded = jsonDecode(candidateResponse.body);
          if (decoded is Map && decoded['id'] != null && decoded['name'] != null) {
            response = candidateResponse;
            manifest = Map<String, dynamic>.from(decoded);
            url = candidate.toString();
            break;
          }
          lastError = Exception('بيانات Manifest غير مكتملة');
        } catch (e) {
          lastError = e;
        }
      }
      if (response == null || manifest == null) {
        throw Exception('تعذر تحميل Manifest من الرابط. ${lastError ?? ''}');
      }

      final entry = Map<String, dynamic>.from(item);
      entry['url'] = url;
      entry['id'] = manifest['id'].toString();
      entry['name'] = manifest['name'].toString();
      entry['description'] = manifest['description']?.toString() ?? '';
      entry['version'] = manifest['version']?.toString() ?? '';
      entry['logo'] = manifest['logo']?.toString() ?? '';
      entry['types'] = _stringList(manifest['types']);
      entry['resources'] = _stringList(manifest['resources']);
      entry['enabled'] = true;
      _installed.removeWhere((e) => e['id'] == entry['id'] || e['url'] == entry['url']);
      _installed.add(entry);
      await _save();
      if (mounted) {
        setState(() {});
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('تم تثبيت ${entry['name']}')));
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('لم يتم التثبيت: ${e.toString().replaceFirst('Exception: ', '')}')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _addByUrl() async {
    final value = _url.text.trim();
    if (value.isEmpty) return;
    final uri = Uri.tryParse(value);
    if (uri == null || !uri.hasScheme || (uri.scheme != 'https' && uri.scheme != 'http')) {
      setState(() => _error = 'أدخل رابط Manifest صالحًا يبدأ بـ https:// أو http://');
      return;
    }
    await _install({
      'id': value, 'name': value, 'description': '', 'version': '',
      'logo': '', 'url': value, 'types': <String>[], 'resources': <String>[],
      'enabled': true,
    });
    _url.clear();
  }

  Future<void> _toggle(Map<String, dynamic> item) async {
    item['enabled'] = !(item['enabled'] == true);
    await _save();
    if (mounted) setState(() {});
  }

  Future<void> _remove(Map<String, dynamic> item) async {
    _installed.remove(item);
    await _save();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text('Addons', style: theme.textTheme.titleLarge),
      const SizedBox(height: 6),
      Text('تصفّح الإضافات الرسمية والمجتمعية، وثبّت الإضافات وأدرها من هنا.',
        style: theme.textTheme.bodyMedium),
      const SizedBox(height: 16),
      RemoteTextInput(child: TextField(
        controller: _search,
        onChanged: (_) => setState(() {}),
        decoration: const InputDecoration(
          prefixIcon: Icon(Icons.search), hintText: 'البحث عن إضافة...',
          border: OutlineInputBorder()),
      )),
      const SizedBox(height: 12),
      SingleChildScrollView(scrollDirection: Axis.horizontal, child: Row(children: [
        for (final entry in const [
          ('installed', 'المثبتة'), ('official', 'الرسمية'), ('community', 'المجتمع')
        ]) Padding(padding: const EdgeInsets.only(right: 8), child: ChoiceChip(
          label: Text(entry.$2), selected: _tab == entry.$1,
          onSelected: (_) => setState(() => _tab = entry.$1))),
      ])),
      if (_tab != 'installed') ...[
        const SizedBox(height: 12),
        RemoteTextInput(child: TextField(controller: _url, decoration: const InputDecoration(
          labelText: 'رابط Manifest لإضافة أخرى', hintText: 'https://example.com/manifest.json',
          border: OutlineInputBorder()))),
        Align(alignment: Alignment.centerRight, child: TextButton.icon(
          onPressed: _busy ? null : _addByUrl,
          icon: const Icon(Icons.add_link), label: const Text('تثبيت من الرابط'))),
      ],
      if (_loading) const Padding(padding: EdgeInsets.all(24),
        child: Center(child: CircularProgressIndicator())),
      if (_error != null) Padding(padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text(_error!, style: TextStyle(color: theme.colorScheme.error))),
      if (!_loading && _visible.isEmpty) Padding(padding: const EdgeInsets.all(20),
        child: Text(_tab == 'installed' ? 'لا توجد إضافات مثبتة بعد.' : 'لا توجد نتائج مطابقة.',
          textAlign: TextAlign.center)),
      for (final item in _visible) Card(
        child: Padding(padding: const EdgeInsets.all(12), child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if ((item['logo'] ?? '').toString().isNotEmpty)
            ClipRRect(borderRadius: BorderRadius.circular(8), child: Image.network(
              item['logo'].toString(), width: 42, height: 42, fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => const Icon(Icons.extension, size: 36)))
          else const Icon(Icons.extension, size: 36),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(item['name']?.toString() ?? 'Addon', style: theme.textTheme.titleMedium),
            if ((item['version'] ?? '').toString().isNotEmpty)
              Text('v${item['version']}', style: theme.textTheme.labelSmall),
            if ((item['description'] ?? '').toString().isNotEmpty)
              Padding(padding: const EdgeInsets.only(top: 4),
                child: Text(item['description'].toString())),
            if ((item['resources'] as List? ?? []).isNotEmpty)
              Padding(padding: const EdgeInsets.only(top: 4),
                child: Text('الموارد: ${(item['resources'] as List).join(', ')}',
                  style: theme.textTheme.labelSmall)),
          ])),
          if (_tab == 'installed') PopupMenuButton<String>(
            onSelected: (v) => v == 'toggle' ? _toggle(item) : _remove(item),
            itemBuilder: (_) => [
              PopupMenuItem(value: 'toggle', child: Text(item['enabled'] == true ? 'تعطيل' : 'تفعيل')),
              const PopupMenuItem(value: 'remove', child: Text('إزالة')),
            ],
            icon: const Icon(Icons.more_vert))
          else IconButton(
            tooltip: _isInstalled(item) ? 'مثبتة' : 'تثبيت',
            onPressed: _busy || _isInstalled(item) ? null : () => _install(item),
            icon: Icon(_isInstalled(item) ? Icons.check_circle : Icons.download))
        ]))),
    ]);
  }
}
