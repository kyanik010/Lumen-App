import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

class StremioSubtitleResult {
  final String id;
  final String url;
  final String language;
  final String label;
  final String addon;

  const StremioSubtitleResult({
    required this.id,
    required this.url,
    required this.language,
    required this.label,
    required this.addon,
  });
}

class StremioSubtitleService {
  StremioSubtitleService._();

  static final instance = StremioSubtitleService._();
  static const _key = 'eagle_x_stremio_addons_v1';
  static const _defaultSubtitleAddons = <Map<String, dynamic>>[
    {
      'id': 'org.stremio.opensubtitlesv3',
      'name': 'OpenSubtitles V3',
      'version': '1.0.0',
      'url': 'https://opensubtitles-v3.strem.io/manifest.json',
      'types': ['movie', 'series'],
      'resources': ['subtitles'],
      'enabled': true,
    },
    {
      'id': 'opensubtitles-pro',
      'name': 'OpenSubtitles PRO',
      'version': '0.1.0',
      'url': 'https://opensubtitlesv3-pro.dexter21767.com/manifest.json',
      'types': ['movie', 'series'],
      'resources': ['subtitles'],
      'enabled': true,
    },
  ];
  final http.Client _client = http.Client();
  static const _timeout = Duration(seconds: 20);

  String _normaliseLanguage(String value) {
    final v = value.trim().toLowerCase().replaceAll('_', '-');
    const aliases = <String, String>{
      'ar': 'ara', 'eng': 'eng', 'en': 'eng',
      'es': 'spa', 'spa': 'spa', 'fr': 'fra', 'fre': 'fra', 'de': 'deu',
      'ger': 'deu', 'it': 'ita', 'pt': 'por', 'ru': 'rus', 'nl': 'nld',
      'tr': 'tur', 'zh': 'zho', 'ja': 'jpn', 'ko': 'kor', 'hi': 'hin',
      'fa': 'fas', 'ara': 'ara',
    };
    return aliases[v] ?? v;
  }

  Future<List<StremioSubtitleResult>> search({
    required String title,
    required String language,
    bool series = false,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    List<Map<String, dynamic>> stored = [];
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          stored = decoded
              .whereType<Map>()
              .map((e) => Map<String, dynamic>.from(e))
              .toList();
        }
      } catch (_) {
        // Recover with the built-in subtitle addons instead of silently
        // disabling every Stremio subtitle source for malformed old storage.
      }
    }

    var changed = false;
    for (final seed in _defaultSubtitleAddons) {
      final index = stored.indexWhere(
        (addon) => addon['id'] == seed['id'] || addon['url'] == seed['url'],
      );
      if (index < 0) {
        stored.add(Map<String, dynamic>.from(seed));
        changed = true;
        continue;
      }
      final existing = stored[index];
      final merged = <String, dynamic>{...seed, ...existing};
      final resources = _resourceNames(merged['resources']);
      if (!resources.contains('subtitles')) merged['resources'] = seed['resources'];
      if ((merged['url'] ?? '').toString().trim().isEmpty) merged['url'] = seed['url'];
      if ((merged['name'] ?? '').toString().trim().isEmpty) merged['name'] = seed['name'];
      if (merged['enabled'] is! bool) merged['enabled'] = true;
      if (jsonEncode(existing) != jsonEncode(merged)) {
        stored[index] = merged;
        changed = true;
      }
    }
    if (changed || raw == null || raw.isEmpty) {
      await prefs.setString(_key, jsonEncode(stored));
    }

    final addons = stored.where((addon) {
      if (addon['enabled'] == false) return false;
      final resources = _resourceNames(addon['resources']);
      return resources.contains('subtitles') &&
          (addon['url'] ?? addon['manifestUrl'] ?? addon['transportUrl']) != null;
    }).toList();
    if (addons.isEmpty) return const [];

    final identity = await _resolveIdentity(title, series: series);
    if (identity == null) return const [];

    final results = <StremioSubtitleResult>[];
    final batches = await Future.wait(
      addons.map((addon) => _fetchAddon(addon, identity, language)),
    );
    for (final batch in batches) {
      results.addAll(batch);
    }
    final seen = <String>{};
    return results.where((item) => seen.add(item.url)).toList();
  }

  List<String> _resourceNames(dynamic raw) {
    if (raw is! List) return const [];
    return raw
        .map((e) => e is Map ? (e['name'] ?? '').toString() : e.toString())
        .where((e) => e.isNotEmpty)
        .toList();
  }

  Future<Map<String, dynamic>?> _resolveIdentity(
    String title, {
    required bool series,
  }) async {
    final episodeMatch = RegExp(
      r'(?:S(\d{1,2})E(\d{1,3})|(\d{1,2})x(\d{1,3}))',
      caseSensitive: false,
    ).firstMatch(title);
    final season = int.tryParse(episodeMatch?.group(1) ?? episodeMatch?.group(3) ?? '');
    final episode = int.tryParse(episodeMatch?.group(2) ?? episodeMatch?.group(4) ?? '');
    final clean = title
        .replaceAll(RegExp(r'\b(19|20)\d{2}\b'), '')
        .replaceAll(RegExp(r'\bS\d{1,2}E\d{1,3}\b|\b\d{1,2}x\d{1,3}\b', caseSensitive: false), '')
        .replaceAll(RegExp(r'[._]+'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (clean.isEmpty) return null;

    final types = series ? const ['series'] : const ['movie', 'series'];
    for (final type in types) {
      try {
        final uri = Uri.parse(
          'https://v3-cinemeta.strem.io/catalog/$type/top/search=${Uri.encodeComponent(clean)}.json',
        );
        final response = await _client.get(uri).timeout(_timeout);
        if (response.statusCode != 200) continue;
        final body = jsonDecode(response.body);
        final metas = body is Map && body['metas'] is List
            ? body['metas'] as List
            : const [];
        final candidates = metas.whereType<Map>().where((item) {
          final id = (item['imdb_id'] ?? item['id'] ?? '').toString();
          return RegExp(r'^tt\d+$').hasMatch(id);
        }).toList();
        if (candidates.isEmpty) continue;

        final queryKey = _normaliseTitle(clean);
        candidates.sort((a, b) {
          final aKey = _normaliseTitle((a['name'] ?? a['title'] ?? '').toString());
          final bKey = _normaliseTitle((b['name'] ?? b['title'] ?? '').toString());
          final aScore = aKey == queryKey ? 0 : (aKey.contains(queryKey) || queryKey.contains(aKey) ? 1 : 2);
          final bScore = bKey == queryKey ? 0 : (bKey.contains(queryKey) || queryKey.contains(bKey) ? 1 : 2);
          return aScore.compareTo(bScore);
        });
        final selected = candidates.first;
        final id = (selected['imdb_id'] ?? selected['id']).toString();
        return <String, dynamic>{
          'type': type,
          'id': id,
          if (type == 'series' && season != null && episode != null) 'season': season,
          if (type == 'series' && season != null && episode != null) 'episode': episode,
        };
      } catch (_) {
        // Continue with the next supported catalog type.
      }
    }

    // Cinemeta is the preferred identity provider, but it can be unavailable
    // or return no match for a title. Fall back to searchable catalogs from
    // the user's enabled Stremio addons, accepting only IMDb-backed movie or
    // series identities before requesting subtitle resources.
    return _searchConfiguredIdentity(
      clean,
      series: series,
      season: season,
      episode: episode,
    );
  }

  String _normaliseTitle(String value) =>
      value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

  Future<Map<String, dynamic>?> _searchConfiguredIdentity(
    String query, {
    required bool series,
    int? season,
    int? episode,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw == null || raw.isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! List) return null;

      final addons = decoded
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .where((addon) => addon['enabled'] != false)
          .take(20)
          .toList(growable: false);
      final batches = await Future.wait(
        addons.map((addon) => _searchAddonCatalogs(addon, query, series: series)),
      );
      final candidates = batches.expand((batch) => batch).where((item) {
        final id = (item['id'] ?? '').toString();
        final type = (item['type'] ?? '').toString().toLowerCase();
        return RegExp(r'^tt\\d{7,10}
    Map<String, dynamic> addon,
    Map<String, dynamic> identity,
    String language,
  ) async {
    try {
      final baseValue = (addon['url'] ?? addon['manifestUrl'] ?? addon['transportUrl'] ?? '').toString().trim();
      if (baseValue.isEmpty) return const [];
      var baseUri = Uri.tryParse(baseValue);
      if (baseUri == null || (baseUri.scheme != 'http' && baseUri.scheme != 'https')) {
        return const [];
      }
      var path = baseUri.path;
      if (path.endsWith('/manifest.json')) {
        path = path.substring(0, path.length - '/manifest.json'.length);
      } else {
        path = path.replaceFirst(RegExp(r'/$'), '');
      }
      baseUri = baseUri.replace(path: path, query: null, fragment: null);
      final resourceId = identity['type'] == 'series' && identity['season'] != null
          ? '${identity['id']}:${identity['season']}:${identity['episode']}'
          : identity['id'].toString();
      final uri = baseUri.resolve('subtitles/${identity['type']}/${Uri.encodeComponent(resourceId)}.json');
      final response = await _client.get(uri).timeout(_timeout);
      if (response.statusCode < 200 || response.statusCode >= 300) return const [];
      final body = jsonDecode(response.body);
      final rows = body is Map && body['subtitles'] is List
          ? body['subtitles'] as List
          : const [];
      final wanted = _normaliseLanguage(language);
      final allLanguages = language.trim().toLowerCase() == 'all' || wanted == 'all';
      final name = (addon['name'] ?? 'Stremio addon').toString();

      return rows.whereType<Map>().where((subtitle) {
        final lang = _normaliseLanguage((subtitle['lang'] ?? '').toString());
        return allLanguages || lang == wanted || lang.startsWith('$wanted-');
      }).map((subtitle) {
        final url = (subtitle['url'] ?? '').toString();
        final lang = (subtitle['lang'] ?? '').toString();
        return StremioSubtitleResult(
          id: (subtitle['id'] ?? url).toString(),
          url: url,
          language: lang,
          label: (subtitle['label'] ?? lang).toString(),
          addon: name,
        );
      }).where((subtitle) {
        final uri = Uri.tryParse(subtitle.url);
        return uri != null && (uri.scheme == 'http' || uri.scheme == 'https');
      }).toList();
    } catch (_) {
      return const [];
    }
  }

  Future<String> download(StremioSubtitleResult subtitle) async {
    final response = await _client.get(Uri.parse(subtitle.url)).timeout(_timeout);
    if (response.statusCode != 200) {
      throw Exception('Subtitle download failed (${response.statusCode}).');
    }
    return utf8.decode(response.bodyBytes, allowMalformed: true);
  }
}
).hasMatch(id) &&
            (type == 'movie' || type == 'series');
      }).toList();
      if (candidates.isEmpty) return null;

      final queryKey = _normaliseTitle(query);
      candidates.sort((a, b) {
        final aKey = _normaliseTitle((a['name'] ?? '').toString());
        final bKey = _normaliseTitle((b['name'] ?? '').toString());
        final aScore = aKey == queryKey
            ? 0
            : (aKey.contains(queryKey) || queryKey.contains(aKey) ? 1 : 2);
        final bScore = bKey == queryKey
            ? 0
            : (bKey.contains(queryKey) || queryKey.contains(bKey) ? 1 : 2);
        return aScore.compareTo(bScore);
      });
      final selected = candidates.first;
      final type = (selected['type'] ?? '').toString();
      final id = (selected['id'] ?? '').toString();
      return <String, dynamic>{
        'type': type,
        'id': id,
        if (type == 'series' && season != null && episode != null) 'season': season,
        if (type == 'series' && season != null && episode != null) 'episode': episode,
      };
    } catch (_) {
      return null;
    }
  }

  Future<List<Map<String, dynamic>>> _searchAddonCatalogs(
    Map<String, dynamic> addon,
    String query, {
    required bool series,
  }) async {
    try {
      final rawUrl =
          (addon['url'] ?? addon['manifestUrl'] ?? addon['transportUrl'] ?? '')
              .toString()
              .trim();
      var uri = Uri.tryParse(rawUrl);
      if (uri == null ||
          (uri.scheme != 'http' && uri.scheme != 'https')) {
        return const [];
      }
      final manifestUrl = rawUrl.endsWith('/manifest.json')
          ? rawUrl
          : (rawUrl.endsWith('/') ? '${rawUrl}manifest.json' : '${rawUrl}/manifest.json');
      final response = await _client.get(Uri.parse(manifestUrl)).timeout(_timeout);
      if (response.statusCode != 200) return const [];
      final manifest = jsonDecode(response.body);
      if (manifest is! Map || manifest['catalogs'] is! List) return const [];

      final manifestUri = Uri.parse(manifestUrl);
      final basePath = manifestUri.path.endsWith('/manifest.json')
          ? manifestUri.path.substring(0, manifestUri.path.length - '/manifest.json'.length)
          : manifestUri.path;
      final base = manifestUri.replace(path: basePath, query: null, fragment: null)
          .toString().replaceFirst(RegExp(r'/
    Map<String, dynamic> addon,
    Map<String, dynamic> identity,
    String language,
  ) async {
    try {
      final baseValue = (addon['url'] ?? addon['manifestUrl'] ?? addon['transportUrl'] ?? '').toString().trim();
      if (baseValue.isEmpty) return const [];
      var baseUri = Uri.tryParse(baseValue);
      if (baseUri == null || (baseUri.scheme != 'http' && baseUri.scheme != 'https')) {
        return const [];
      }
      var path = baseUri.path;
      if (path.endsWith('/manifest.json')) {
        path = path.substring(0, path.length - '/manifest.json'.length);
      } else {
        path = path.replaceFirst(RegExp(r'/$'), '');
      }
      baseUri = baseUri.replace(path: path, query: null, fragment: null);
      final resourceId = identity['type'] == 'series' && identity['season'] != null
          ? '${identity['id']}:${identity['season']}:${identity['episode']}'
          : identity['id'].toString();
      final uri = baseUri.resolve('subtitles/${identity['type']}/${Uri.encodeComponent(resourceId)}.json');
      final response = await _client.get(uri).timeout(_timeout);
      if (response.statusCode < 200 || response.statusCode >= 300) return const [];
      final body = jsonDecode(response.body);
      final rows = body is Map && body['subtitles'] is List
          ? body['subtitles'] as List
          : const [];
      final wanted = _normaliseLanguage(language);
      final allLanguages = language.trim().toLowerCase() == 'all' || wanted == 'all';
      final name = (addon['name'] ?? 'Stremio addon').toString();

      return rows.whereType<Map>().where((subtitle) {
        final lang = _normaliseLanguage((subtitle['lang'] ?? '').toString());
        return allLanguages || lang == wanted || lang.startsWith('$wanted-');
      }).map((subtitle) {
        final url = (subtitle['url'] ?? '').toString();
        final lang = (subtitle['lang'] ?? '').toString();
        return StremioSubtitleResult(
          id: (subtitle['id'] ?? url).toString(),
          url: url,
          language: lang,
          label: (subtitle['label'] ?? lang).toString(),
          addon: name,
        );
      }).where((subtitle) {
        final uri = Uri.tryParse(subtitle.url);
        return uri != null && (uri.scheme == 'http' || uri.scheme == 'https');
      }).toList();
    } catch (_) {
      return const [];
    }
  }

  Future<String> download(StremioSubtitleResult subtitle) async {
    final response = await _client.get(Uri.parse(subtitle.url)).timeout(_timeout);
    if (response.statusCode != 200) {
      throw Exception('Subtitle download failed (${response.statusCode}).');
    }
    return utf8.decode(response.bodyBytes, allowMalformed: true);
  }
}
), '');
      final catalogs = (manifest['catalogs'] as List).whereType<Map>().where((catalog) {
        final type = (catalog['type'] ?? '').toString();
        if (type != 'movie' && type != 'series') return false;
        if (series && type != 'series') return false;
        final extras = catalog['extra'] is List ? catalog['extra'] as List : const [];
        return extras.whereType<Map>().any((extra) => extra['name'] == 'search');
      }).toList(growable: false);

      final results = await Future.wait(catalogs.map((catalog) async {
        try {
          final type = (catalog['type'] ?? '').toString();
          final id = (catalog['id'] ?? '').toString();
          if (id.isEmpty) return const <Map<String, dynamic>>[];
          final request = Uri.parse(
            '$base/catalog/$type/$id/search=${Uri.encodeComponent(query)}.json',
          );
          final response = await _client.get(request).timeout(_timeout);
          if (response.statusCode != 200) return const <Map<String, dynamic>>[];
          final body = jsonDecode(response.body);
          final metas = body is Map && body['metas'] is List ? body['metas'] as List : const [];
          return metas.whereType<Map>().map((meta) {
            final rawId = (meta['imdb_id'] ?? meta['id'] ?? '').toString();
            return <String, dynamic>{
              'id': rawId,
              'type': (meta['type'] ?? type).toString(),
              'name': (meta['name'] ?? meta['title'] ?? '').toString(),
            };
          }).where((meta) => RegExp(r'^tt\\d{7,10}
    Map<String, dynamic> addon,
    Map<String, dynamic> identity,
    String language,
  ) async {
    try {
      final baseValue = (addon['url'] ?? addon['manifestUrl'] ?? addon['transportUrl'] ?? '').toString().trim();
      if (baseValue.isEmpty) return const [];
      var baseUri = Uri.tryParse(baseValue);
      if (baseUri == null || (baseUri.scheme != 'http' && baseUri.scheme != 'https')) {
        return const [];
      }
      var path = baseUri.path;
      if (path.endsWith('/manifest.json')) {
        path = path.substring(0, path.length - '/manifest.json'.length);
      } else {
        path = path.replaceFirst(RegExp(r'/$'), '');
      }
      baseUri = baseUri.replace(path: path, query: null, fragment: null);
      final resourceId = identity['type'] == 'series' && identity['season'] != null
          ? '${identity['id']}:${identity['season']}:${identity['episode']}'
          : identity['id'].toString();
      final uri = baseUri.resolve('subtitles/${identity['type']}/${Uri.encodeComponent(resourceId)}.json');
      final response = await _client.get(uri).timeout(_timeout);
      if (response.statusCode < 200 || response.statusCode >= 300) return const [];
      final body = jsonDecode(response.body);
      final rows = body is Map && body['subtitles'] is List
          ? body['subtitles'] as List
          : const [];
      final wanted = _normaliseLanguage(language);
      final allLanguages = language.trim().toLowerCase() == 'all' || wanted == 'all';
      final name = (addon['name'] ?? 'Stremio addon').toString();

      return rows.whereType<Map>().where((subtitle) {
        final lang = _normaliseLanguage((subtitle['lang'] ?? '').toString());
        return allLanguages || lang == wanted || lang.startsWith('$wanted-');
      }).map((subtitle) {
        final url = (subtitle['url'] ?? '').toString();
        final lang = (subtitle['lang'] ?? '').toString();
        return StremioSubtitleResult(
          id: (subtitle['id'] ?? url).toString(),
          url: url,
          language: lang,
          label: (subtitle['label'] ?? lang).toString(),
          addon: name,
        );
      }).where((subtitle) {
        final uri = Uri.tryParse(subtitle.url);
        return uri != null && (uri.scheme == 'http' || uri.scheme == 'https');
      }).toList();
    } catch (_) {
      return const [];
    }
  }

  Future<String> download(StremioSubtitleResult subtitle) async {
    final response = await _client.get(Uri.parse(subtitle.url)).timeout(_timeout);
    if (response.statusCode != 200) {
      throw Exception('Subtitle download failed (${response.statusCode}).');
    }
    return utf8.decode(response.bodyBytes, allowMalformed: true);
  }
}
).hasMatch(meta['id'] as String))
              .toList(growable: false);
        } catch (_) {
          return const <Map<String, dynamic>>[];
        }
      }));
      return results.expand((batch) => batch).toList(growable: false);
    } catch (_) {
      return const [];
    }
  }

  Future<List<StremioSubtitleResult>> _fetchAddon(
    Map<String, dynamic> addon,
    Map<String, dynamic> identity,
    String language,
  ) async {
    try {
      final baseValue = (addon['url'] ?? addon['manifestUrl'] ?? addon['transportUrl'] ?? '').toString().trim();
      if (baseValue.isEmpty) return const [];
      var baseUri = Uri.tryParse(baseValue);
      if (baseUri == null || (baseUri.scheme != 'http' && baseUri.scheme != 'https')) {
        return const [];
      }
      var path = baseUri.path;
      if (path.endsWith('/manifest.json')) {
        path = path.substring(0, path.length - '/manifest.json'.length);
      } else {
        path = path.replaceFirst(RegExp(r'/$'), '');
      }
      baseUri = baseUri.replace(path: path, query: null, fragment: null);
      final resourceId = identity['type'] == 'series' && identity['season'] != null
          ? '${identity['id']}:${identity['season']}:${identity['episode']}'
          : identity['id'].toString();
      final uri = baseUri.resolve('subtitles/${identity['type']}/${Uri.encodeComponent(resourceId)}.json');
      final response = await _client.get(uri).timeout(_timeout);
      if (response.statusCode < 200 || response.statusCode >= 300) return const [];
      final body = jsonDecode(response.body);
      final rows = body is Map && body['subtitles'] is List
          ? body['subtitles'] as List
          : const [];
      final wanted = _normaliseLanguage(language);
      final allLanguages = language.trim().toLowerCase() == 'all' || wanted == 'all';
      final name = (addon['name'] ?? 'Stremio addon').toString();

      return rows.whereType<Map>().where((subtitle) {
        final lang = _normaliseLanguage((subtitle['lang'] ?? '').toString());
        return allLanguages || lang == wanted || lang.startsWith('$wanted-');
      }).map((subtitle) {
        final url = (subtitle['url'] ?? '').toString();
        final lang = (subtitle['lang'] ?? '').toString();
        return StremioSubtitleResult(
          id: (subtitle['id'] ?? url).toString(),
          url: url,
          language: lang,
          label: (subtitle['label'] ?? lang).toString(),
          addon: name,
        );
      }).where((subtitle) {
        final uri = Uri.tryParse(subtitle.url);
        return uri != null && (uri.scheme == 'http' || uri.scheme == 'https');
      }).toList();
    } catch (_) {
      return const [];
    }
  }

  Future<String> download(StremioSubtitleResult subtitle) async {
    final response = await _client.get(Uri.parse(subtitle.url)).timeout(_timeout);
    if (response.statusCode != 200) {
      throw Exception('Subtitle download failed (${response.statusCode}).');
    }
    return utf8.decode(response.bodyBytes, allowMalformed: true);
  }
}
