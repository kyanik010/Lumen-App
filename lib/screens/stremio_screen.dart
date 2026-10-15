import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// Stremio TV catalog browser. Addon installation remains in
/// [StremioAddonsScreen]; this screen only consumes enabled installed addons.
class StremioScreen extends StatefulWidget {
  const StremioScreen({super.key});

  @override
  State<StremioScreen> createState() => _StremioScreenState();
}

class _StremioScreenState extends State<StremioScreen> {
  static const _storageKey = 'eagle_x_stremio_addons_v1';
  final http.Client _client = http.Client();
  List<_TvCatalog> _catalogs = [];
  List<_TvItem> _items = [];
  _TvCatalog? _selected;
  bool _loading = true;
  bool _loadingItems = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadCatalogs();
  }

  @override
  void dispose() {
    _client.close();
    super.dispose();
  }

  Future<void> _loadCatalogs() async {
    setState(() {
      _loading = true;
      _error = null;
      _catalogs = [];
      _items = [];
      _selected = null;
    });
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_storageKey);
      if (raw == null || raw.isEmpty) {
        throw Exception('لم يتم العثور على إضافات مثبتة. افتح Addons أولاً.');
      }
      final decoded = jsonDecode(raw);
      if (decoded is! List) {
        throw const FormatException('قائمة الإضافات غير صالحة');
      }
      final installed = decoded
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .where((a) => a['enabled'] != false)
          .toList();
      final catalogs = <_TvCatalog>[];
      for (final addon in installed) {
        final manifestUrl = _manifestUrl(addon);
        if (manifestUrl == null) continue;
        try {
          final response = await _client
              .get(Uri.parse(manifestUrl))
              .timeout(const Duration(seconds: 12));
          if (response.statusCode != 200) continue;
          final manifest = jsonDecode(response.body);
          if (manifest is! Map) continue;
          final base = _baseUrl(manifestUrl);
          final addonName =
              (manifest['name'] ?? addon['name'] ?? 'Stremio').toString();
          final resources = _list(manifest['resources']);
          if (resources.isNotEmpty && !resources.contains('catalog')) continue;
          final types = _list(manifest['types']);
          final rawCatalogs = manifest['catalogs'];
          if (rawCatalogs is! List) continue;
          for (final rawCatalog in rawCatalogs.whereType<Map>()) {
            final type = (rawCatalog['type'] ?? '').toString();
            final id = (rawCatalog['id'] ?? '').toString();
            if (id.isEmpty || (type != 'movie' && type != 'series')) continue;
            if (types.isNotEmpty && !types.contains(type)) continue;
            final catalogName = (rawCatalog['name'] ?? id).toString();
            final extras = rawCatalog['extra'] is List
                ? (rawCatalog['extra'] as List).whereType<Map>().toList()
                : <Map>[];
            catalogs.add(_TvCatalog(
              addonName: addonName,
              addonId: (manifest['id'] ?? addon['id'] ?? addonName).toString(),
              baseUrl: base,
              id: id,
              type: type,
              name: catalogName,
              supportsSearch: extras.any((e) => e['name'] == 'search'),
            ));
          }
        } catch (_) {
          // An unavailable addon should not prevent catalogs from other addons.
        }
      }
      if (!mounted) return;
      setState(() {
        _catalogs = catalogs;
        _loading = false;
        if (catalogs.isEmpty) {
          _error = 'لم تُرجع الإضافات المفعّلة أي كتالوجات أفلام أو مسلسلات.';
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  String? _manifestUrl(Map<String, dynamic> addon) {
    final raw =
        (addon['url'] ?? addon['manifestUrl'] ?? addon['transportUrl'])
            ?.toString();
    if (raw == null || raw.isEmpty) return null;
    final uri = Uri.tryParse(raw);
    if (uri == null ||
        !uri.hasScheme ||
        (uri.scheme != 'https' && uri.scheme != 'http')) {
      return null;
    }
    return raw.endsWith('/manifest.json')
        ? raw
        : (raw.endsWith('/') ? '${raw}manifest.json' : '${raw}/manifest.json');
  }

  String _baseUrl(String manifestUrl) {
    final uri = Uri.parse(manifestUrl);
    final path = uri.path.endsWith('/manifest.json')
        ? uri.path.substring(0, uri.path.length - '/manifest.json'.length)
        : uri.path;
    return uri
        .replace(path: path, query: null, fragment: null)
        .toString()
        .replaceFirst(RegExp(r'/$'), '');
  }

  List<String> _list(dynamic raw) => raw is List
      ? raw
          .map((e) => e is Map ? (e['name'] ?? '').toString() : e.toString())
          .where((e) => e.isNotEmpty)
          .toList()
      : <String>[];

  Future<void> _openCatalog(_TvCatalog catalog) async {
    setState(() {
      _selected = catalog;
      _loadingItems = true;
      _items = [];
      _error = null;
    });
    try {
      final uri = Uri.parse(
          '${catalog.baseUrl}/catalog/${catalog.type}/${catalog.id}.json');
      final response =
          await _client.get(uri).timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) {
        throw Exception('HTTP ${response.statusCode}');
      }
      final decoded = jsonDecode(response.body);
      final metas = decoded is Map ? decoded['metas'] : null;
      if (metas is! List) {
        throw const FormatException('استجابة الكتالوج غير صالحة');
      }
      final items = metas
          .whereType<Map>()
          .map((m) => _TvItem(
                id: (m['id'] ?? '').toString(),
                type: (m['type'] ?? catalog.type).toString(),
                name: (m['name'] ?? 'بدون عنوان').toString(),
                poster: (m['poster'] ?? '').toString(),
                description: (m['description'] ?? '').toString(),
                releaseInfo: (m['releaseInfo'] ?? '').toString(),
              ))
          .where((m) => m.id.isNotEmpty)
          .toList();
      if (!mounted) return;
      setState(() {
        _items = items;
        _loadingItems = false;
        if (items.isEmpty) _error = 'هذا الكتالوج لا يحتوي عناصر حالياً.';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingItems = false;
        _error =
            'تعذّر تحميل الكتالوج: ${e.toString().replaceFirst('Exception: ', '')}';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(children: [
          const Icon(Icons.live_tv_outlined, size: 28),
          const SizedBox(width: 10),
          Expanded(child: Text('Stremio TV', style: theme.textTheme.titleLarge)),
          IconButton(
            tooltip: 'تحديث الكتالوجات',
            onPressed: _loading ? null : _loadCatalogs,
            icon: const Icon(Icons.refresh),
          ),
          if (_selected != null)
            IconButton(
              tooltip: 'العودة إلى القنوات',
              onPressed: () => setState(() {
                _selected = null;
                _items = [];
                _error = null;
              }),
              icon: const Icon(Icons.arrow_back),
            ),
        ]),
        const SizedBox(height: 12),
        if (_loading)
          const Expanded(child: Center(child: CircularProgressIndicator()))
        else if (_selected == null)
          Expanded(
              child: _error != null
                  ? _message(_error!, onRetry: _loadCatalogs)
                  : _catalogGrid())
        else
          Expanded(
              child: _loadingItems
                  ? const Center(child: CircularProgressIndicator())
                  : _error != null
                      ? _message(_error!,
                          onRetry: () => _openCatalog(_selected!))
                      : _itemGrid()),
      ],
    );
  }

  Widget _message(String message, {required VoidCallback onRetry}) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.info_outline, size: 36),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            OutlinedButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh),
                label: const Text('إعادة المحاولة')),
          ]),
        ),
      );

  Widget _catalogGrid() => GridView.builder(
        padding: const EdgeInsets.only(bottom: 20),
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 280,
          mainAxisExtent: 112,
          crossAxisSpacing: 12,
          mainAxisSpacing: 12,
        ),
        itemCount: _catalogs.length,
        itemBuilder: (context, index) {
          final c = _catalogs[index];
          return Card(
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: () => _openCatalog(c),
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Row(children: [
                  const Icon(Icons.live_tv, size: 30),
                  const SizedBox(width: 12),
                  Expanded(
                      child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(c.name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w600)),
                      const SizedBox(height: 5),
                      Text(
                          '${c.addonName} · ${c.type == 'series' ? 'مسلسلات' : 'أفلام'}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall),
                    ],
                  )),
                  const Icon(Icons.chevron_right),
                ]),
              ),
            ),
          );
        },
      );

  Widget _itemGrid() => GridView.builder(
        padding: const EdgeInsets.only(bottom: 20),
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 190,
          childAspectRatio: .62,
          crossAxisSpacing: 12,
          mainAxisSpacing: 12,
        ),
        itemCount: _items.length,
        itemBuilder: (context, index) {
          final item = _items[index];
          return Card(
            clipBehavior: Clip.antiAlias,
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                      child: item.poster.startsWith('http')
                          ? Image.network(item.poster,
                              fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) => const Center(
                                  child: Icon(Icons.movie_outlined, size: 42)))
                          : const Center(
                              child: Icon(Icons.movie_outlined, size: 42))),
                  Padding(
                    padding: const EdgeInsets.all(9),
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(item.name,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style:
                                  const TextStyle(fontWeight: FontWeight.w600)),
                          if (item.releaseInfo.isNotEmpty)
                            Text(item.releaseInfo,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.bodySmall),
                        ]),
                  ),
                ]),
          );
        },
      );
}

class _TvCatalog {
  final String addonName, addonId, baseUrl, id, type, name;
  final bool supportsSearch;
  const _TvCatalog({
    required this.addonName,
    required this.addonId,
    required this.baseUrl,
    required this.id,
    required this.type,
    required this.name,
    required this.supportsSearch,
  });
}

class _TvItem {
  final String id, type, name, poster, description, releaseInfo;
  const _TvItem({
    required this.id,
    required this.type,
    required this.name,
    required this.poster,
    required this.description,
    required this.releaseInfo,
  });
}
