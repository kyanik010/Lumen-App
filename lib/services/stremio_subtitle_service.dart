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
    if (raw == null || raw.isEmpty) return const [];

    dynamic decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      return const [];
    }
    if (decoded is! List) return const [];

    final addons = decoded
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .where((addon) {
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
    return null;
  }

  String _normaliseTitle(String value) =>
      value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

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
