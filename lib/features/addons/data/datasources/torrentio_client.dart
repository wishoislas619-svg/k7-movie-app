import 'dart:convert';
import 'package:http/http.dart' as http;
import '../../domain/entities/torrent_stream.dart';

class TorrentioClient {
  /// Normaliza manifestUrl: Stremio usa `stremio://` pero http necesita `https://`
  static String _normalize(String manifestUrl) {
    if (manifestUrl.startsWith('stremio://')) {
      return manifestUrl.replaceFirst('stremio://', 'https://');
    }
    return manifestUrl;
  }

  /// Host del stream asociado a un manifest. NO debe fijarse a Torrentio:
  /// cada addon sirve sus streams desde SU host configurado.
  static String _hostFor(String manifestUrl) {
    final normalized = _normalize(manifestUrl);
    final uri = Uri.tryParse(normalized);
    if (uri == null || uri.host.isEmpty) return '';
    return 'https://${uri.host}';
  }

  /// Descompone una URL de manifest de addon y devuelve la configuración
  /// embebida en la ruta para poder construir la URL de streams. Quita el
  /// `manifest.json` final y usa el resto de segmentos como config.
  static String configFromManifest(String manifestUrl) {
    final normalized = _normalize(manifestUrl);
    final uri = Uri.tryParse(normalized);
    if (uri == null) return '';
    final segments = uri.pathSegments;
    if (segments.isEmpty) return '';
    // https://host/{config}/manifest.json  ->  {config} (puede tener varias partes)
    if (segments.last == 'manifest.json' && segments.length > 1) {
      return segments.sublist(0, segments.length - 1).join('/');
    }
    // Sin manifest.json: se asume el primer segmento como config (torrentio).
    return segments.length >= 2 ? segments[0] : '';
  }

  /// Construye la URL base de streams: https://{host}/{config}/stream/{type}/{id}.json
  static String streamUrl({
    required String manifestUrl,
    required String type, // 'movie' | 'series'
    required String imdbId,
  }) {
    final host = _hostFor(manifestUrl);
    if (host.isEmpty) return '';
    final config = configFromManifest(manifestUrl);
    final prefix = config.isEmpty ? '' : '/$config';
    return '$host$prefix/stream/$type/$imdbId.json';
  }

  static Future<List<Map<String, dynamic>>> fetchManifest(
    String manifestUrl,
  ) async {
    final normalized = _normalize(manifestUrl);
    final resp =
        await http.get(Uri.parse(normalized), headers: {'accept': 'application/json'});
    if (resp.statusCode != 200) {
      throw Exception('Manifest error: HTTP ${resp.statusCode}');
    }
    final json = jsonDecode(resp.body);
    final Map<String, dynamic> data = json is Map<String, dynamic> ? json : {};
    return [
      {
        'id': data['id'] ?? manifestUrl,
        'name': data['name'] ?? 'Addon',
        'manifestUrl': manifestUrl,
        'resources': data['resources'] ?? [],
      }
    ];
  }

  static Future<List<TorrentStream>> fetchStreams({
    required String manifestUrl,
    required String type,
    required String imdbId,
  }) async {
    final url = streamUrl(manifestUrl: manifestUrl, type: type, imdbId: imdbId);
    final resp = await http.get(Uri.parse(url), headers: {'accept': 'application/json'});
    if (resp.statusCode != 200) {
      throw Exception('Streams error: HTTP ${resp.statusCode}');
    }
    final json = jsonDecode(resp.body) as Map<String, dynamic>;
    final rawStreams = json['streams'] as List<dynamic>? ?? [];

    final result = <TorrentStream>[];
    if (rawStreams.isEmpty) return result;

    for (final raw in rawStreams) {
      final Map<String, dynamic> s = raw is Map<String, dynamic> ? raw : {};
      final name = (s['name'] ?? '') as String;
      final title = (s['title'] ?? '') as String;
      final url = s['url'] != null ? (s['url'] as String) : null;
      final infoHash = s['infoHash'] != null ? (s['infoHash'] as String) : null;
      final fileIdx = s['fileIdx'] is num ? (s['fileIdx'] as num).toInt() : null;

      String? quality = _extractQuality(name);
      if (quality == null) quality = _extractQuality(title);

      final isDebrid =
          name.toUpperCase().contains('RD') ||
          name.toUpperCase().contains('DEBRID') ||
          name.toUpperCase().contains('+)') ||
          (url != null && url.isNotEmpty && !url.startsWith('magnet:'));

      final subtitles = <SubtitleItem>[];
      final rawSubs = s['subtitles'];
      if (rawSubs is List) {
        for (final rs in rawSubs) {
          if (rs is Map) {
            final lang = rs['lang'] ?? rs['language'];
            final surl = rs['url'];
            if (surl is String && surl.isNotEmpty) {
              subtitles.add(SubtitleItem(
                language: lang is String ? lang : 'Sub',
                url: surl,
              ));
            }
          }
        }
      }

      result.add(TorrentStream(
        name: name,
        title: title,
        url: url,
        infoHash: infoHash,
        fileIdx: fileIdx,
        isDebrid: isDebrid,
        quality: quality,
        sizeHuman: _extractSize(title),
        sizeBytes: _extractBytes(title),
        seeders: _extractInt(title, 'seeders') ??
            _extractSeeders(title) ??
            _extractSeeders(name),
        peers: _extractInt(title, 'peers'),
        language: _extractLanguage(title),
        flags: _extractFlags('$name $title'),
        subtitles: subtitles,
      ));
    }

    return result;
  }

  static String? _extractQuality(String text) {
    final m = RegExp(r'(\d{3,4}p|4k|2160p|1080p|720p|480p)', caseSensitive: false)
        .firstMatch(text);
    return m?.group(1);
  }

  static String? _extractSize(String text) {
    final m = RegExp(r'([\d.,]+\s*(GB|MB|TB|KB))', caseSensitive: false).firstMatch(text);
    return m?.group(1);
  }

  static int? _extractBytes(String text) {
    final m = RegExp(r'([\d.,]+)\s*(GB|MB|TB|KB)', caseSensitive: false).firstMatch(text);
    if (m == null) return null;
    final n = double.tryParse(m.group(1)!.replaceAll(',', ''));
    if (n == null) return null;
    switch (m.group(2)!.toUpperCase()) {
      case 'KB':
        return (n * 1024).round();
      case 'MB':
        return (n * 1024 * 1024).round();
      case 'GB':
        return (n * 1024 * 1024 * 1024).round();
      case 'TB':
        return (n * 1024 * 1024 * 1024 * 1024).round();
    }
    return null;
  }

  static int? _extractInt(String text, String key) {
    final m = RegExp('$key=([\\d,]+)', caseSensitive: false).firstMatch(text);
    if (m == null) return null;
    return int.tryParse(m.group(1)!.replaceAll(',', ''));
  }

  static int? _extractSeeders(String name) {
    final m = RegExp(r'👤 (\d+)').firstMatch(name);
    return m == null ? null : int.tryParse(m.group(1)!);
  }

  static List<String> _extractFlags(String text) {
    final matches = RegExp(
      r'[\u{1F1E6}-\u{1F1FF}][\u{1F1E6}-\u{1F1FF}]',
      unicode: true,
    ).allMatches(text);
    final seen = <String>{};
    for (final m in matches) {
      seen.add(m.group(0)!);
    }
    return seen.toList();
  }

  static String? _extractLanguage(String text) {
    if (text.toUpperCase().contains('LATINO')) return 'Latino';
    if (text.toUpperCase().contains('ESP') || text.toUpperCase().contains('ESPAÑOL')) {
      return 'Español (Castellano)';
    }
    if (text.toUpperCase().contains('SUB')) return 'Subtitulado';
    if (text.toUpperCase().contains('ING')) return 'Inglés';
    return null;
  }
}
