import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

class StremioSubtitleResult {
  final String id;
  final String url;
  final String language;
  final String label;
  final String addon;
  const StremioSubtitleResult({required this.id, required this.url, required this.language, required this.label, required this.addon});
}

class StremioSubtitleService {
  StremioSubtitleService._();
  static final instance = StremioSubtitleService._();
  static const _key = 'eagle_x_stremio_addons_v1';
  final _client = http.Client();

  Future<List<StremioSubtitleResult>> search({
    required String title,
    required String language,
    bool series = false,
  }) async {
    final identity = await _resolveIdentity(title, series: series);
    if (identity == null) return const [];
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return const [];
    final decoded = jsonDecode(raw);
    if (decoded is! List) return const [];
    final addons = decoded.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).where((a) {
      final enabled = a['enabled'] != false;
      final resources = (a['resources'] as List? ?? const []).map((e) => e.toString()).toList();
      return enabled && (resources.isEmpty || resources.contains('subtitles'));
    }).toList();
    final futures = addons.map((addon) => _fetchAddon(addon, identity, language));
    final results = (await Future.wait(futures)).expand((e) => e).toList();
    final seen = <String>{};
    return results.where((s) => s.url.isNotEmpty && seen.add(s.url)).toList();
  }

  Future<Map<String, dynamic>?> _resolveIdentity(String title, {required bool series}) async {
    final clean = title.replaceAll(RegExp(r'\b(19|20)\d{2}\b'), '').replaceAll(RegExp(r'\b(S\d{1,2}E\d{1,3}|\d{1,2}x\d{1,3})\b', caseSensitive: false), '').trim();
    final episode = RegExp(r'(?:S(\d{1,2})E(\d{1,3})|(\d{1,2})x(\d{1,3}))', caseSensitive: false).firstMatch(title);
    final season = int.tryParse(episode?.group(1) ?? episode?.group(3) ?? '');
    final ep = int.tryParse(episode?.group(2) ?? episode?.group(4) ?? '');
    for (final type in series ? ['series'] : ['movie', 'series']) {
      try {
        final uri = Uri.parse('https://v3-cinemeta.strem.io/catalog/$type/top/search=${Uri.encodeComponent(clean)}.json');
        final response = await _client.get(uri).timeout(const Duration(seconds: 12));
        if (response.statusCode != 200) continue;
        final body = jsonDecode(response.body);
        final metas = body is Map && body['metas'] is List ? body['metas'] as List : const [];
        for (final item in metas.whereType<Map>()) {
          final id = item['imdb_id']?.toString() ?? item['id']?.toString() ?? '';
          if (!RegExp(r'^tt\d+$').hasMatch(id)) continue;
          return {'type': type, 'id': id, if (type == 'series' && season != null && ep != null) 'season': season, if (type == 'series' && season != null && ep != null) 'episode': ep};
        }
      } catch (_) {}
    }
    return null;
  }

  Future<List<StremioSubtitleResult>> _fetchAddon(Map<String, dynamic> addon, Map<String, dynamic> identity, String language) async {
    try {
      final resources = (addon['resources'] as List? ?? const []).map((e) => e is Map ? (e['name'] ?? '').toString() : e.toString()).toList();
      if (resources.isNotEmpty && !resources.contains('subtitles')) return const [];
      var base = (addon['url'] ?? addon['manifestUrl'] ?? addon['transportUrl'] ?? '').toString().trim();
      if (base.isEmpty) return const [];
      if (base.endsWith('/manifest.json')) base = base.substring(0, base.length - '/manifest.json'.length);
      final id = identity['type'] == 'series' && identity['season'] != null
          ? '${identity['id']}:${identity['season']}:${identity['episode']}'
          : identity['id'].toString();
      final uri = Uri.parse('$base/subtitles/${identity['type']}/$id.json');
      final response = await _client.get(uri).timeout(const Duration(seconds: 15));
      if (response.statusCode < 200 || response.statusCode >= 300) return const [];
      final body = jsonDecode(response.body);
      final rows = body is Map && body['subtitles'] is List ? body['subtitles'] as List : const [];
      final name = (addon['name'] ?? 'Stremio addon').toString();
      return rows.whereType<Map>().where((s) {
        final lang = (s['lang'] ?? '').toString().toLowerCase();
        return language == 'all' || lang == language || lang.startsWith('$language-');
      }).map((s) {
        final url = (s['url'] ?? '').toString();
        final lang = (s['lang'] ?? '').toString();
        return StremioSubtitleResult(id: (s['id'] ?? url).toString(), url: url, language: lang, label: (s['label'] ?? lang).toString(), addon: name);
      }).where((s) => s.url.startsWith('https://') || s.url.startsWith('http://')).toList();
    } catch (_) {
      return const [];
    }
  }

  Future<String> download(StremioSubtitleResult subtitle) async {
    final response = await _client.get(Uri.parse(subtitle.url)).timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) throw Exception('Subtitle download failed (${response.statusCode}).');
    final bytes = response.bodyBytes;
    // Stremio subtitle resources commonly serve UTF-8 SRT/VTT files.
    return utf8.decode(bytes, allowMalformed: true);
  }
}
