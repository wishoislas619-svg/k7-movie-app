import 'package:http/http.dart' as http;
import 'package:html/parser.dart' as html_parser;
import '../../../movies/domain/entities/movie.dart';

class SubtitleInfo {
  final String language;
  final String url;
  SubtitleInfo({required this.language, required this.url});
}

class VideoExtractionResult {
  final String videoUrl;
  final List<SubtitleInfo> subtitles;
  VideoExtractionResult({required this.videoUrl, this.subtitles = const []});
}

class VideoService {
  /// Simulates Seekee logic: fetches a URL, parses HTML, and finds the direct video link.
  static Future<VideoExtractionResult?> findDirectVideoUrl(String webUrl) async {
    print('DEBUG: Iniciando detección para: $webUrl');
    try {
      if (webUrl.toLowerCase().endsWith('.mp4') || webUrl.toLowerCase().endsWith('.m3u8')) {
        print('DEBUG: El enlace ya es directo: $webUrl');
        return VideoExtractionResult(videoUrl: webUrl);
      }

      final response = await http.get(Uri.parse(webUrl), headers: {
        'User-Agent': 'Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Mobile/15E148 Safari/604.1'
      }).timeout(const Duration(seconds: 10));
      
      print('DEBUG: Respuesta de página principal: ${response.statusCode}');
      if (response.statusCode != 200) return null;
      
      final body = response.body;
      final document = html_parser.parse(body);
      
      List<SubtitleInfo> extractedSubtitles = [];
      // Buscar subtítulos en etiquetas <track>
      final tracks = document.querySelectorAll('track');
      for (var track in tracks) {
        final src = track.attributes['src'] ?? track.attributes['data-src'];
        if (src != null && src.toLowerCase().contains('.vtt')) {
          final label = track.attributes['label'] ?? track.attributes['srclang'] ?? 'Subtítulo';
          extractedSubtitles.add(SubtitleInfo(language: label, url: _normalizeUrl(src, webUrl)));
        }
      }

      // Buscar subtítulos en formato JSON común (jwplayer tracks, etc)
      final trackRegex = RegExp(r'"file":\s*"([^"]+\.vtt)"\s*,\s*"label":\s*"([^"]+)"');
      final trackMatches = trackRegex.allMatches(body);
      for (var match in trackMatches) {
         final src = match.group(1);
         final label = match.group(2) ?? 'Subtítulo';
         if (src != null) {
           extractedSubtitles.add(SubtitleInfo(language: label, url: _normalizeUrl(src, webUrl)));
         }
      }

      // 1. Check <video> and <source> tags
      final videoElements = document.querySelectorAll('video, source');
      print('DEBUG: Elementos <video>/<source> encontrados: ${videoElements.length}');
      for (var element in videoElements) {
        final src = element.attributes['src'] ?? element.attributes['data-src'];
        if (src != null && _isProbablyVideo(src)) {
          final found = _normalizeUrl(src, webUrl);
          print('DEBUG: Video encontrado en tag: $found');
          return VideoExtractionResult(videoUrl: found, subtitles: extractedSubtitles);
        }
      }

      // 2. Check <iframe> (Look for embeds)
      final iframes = document.getElementsByTagName('iframe');
      print('DEBUG: Iframes encontrados: ${iframes.length}');
      for (var iframe in iframes) {
        final src = iframe.attributes['src'] ?? iframe.attributes['data-src'];
        if (src != null) {
          print('DEBUG: Analizando iframe: $src');
          if (src.contains('.mp4') || src.contains('.m3u8')) {
            return VideoExtractionResult(videoUrl: _normalizeUrl(src, webUrl), subtitles: extractedSubtitles);
          }
          // Patrón específico encontrado en la investigación (Embed69)
          if (src.contains('embed69.org') || src.contains('vidhide') || src.contains('voe')) {
            print('DEBUG: Iframe de reproductor detectado, intentando extraer origen...');
            // En un sistema real, aquí podríamos hacer un segundo scrape del iframe
          }
        }
      }

      // 3. Advanced Regex Search (Common in JS/JSON parts of the page)
      print('DEBUG: Iniciando búsqueda por expresiones regulares...');
      final List<RegExp> videoRegexes = [
        RegExp(r'''(https?://[^\s"'\\]+\.mp4[^\s"'\\]*)'''),
        RegExp(r'''(https?://[^\s"'\\]+\.m3u8[^\s"'\\]*)'''),
        RegExp(r'''file":\s*"([^"]+\.mp4)"'''),
        RegExp(r'''source":\s*"([^"]+\.mp4)"'''),
        RegExp(r'''"url":\s*"([^"]+)"'''), // Intentar capturar JSON genérico
      ];

      for (var regex in videoRegexes) {
        final matches = regex.allMatches(body);
        for (var match in matches) {
          final found = match.group(1);
          if (found != null && !found.contains('preview') && !found.contains('ads')) {
            final normalized = _normalizeUrl(found, webUrl);
            if (_isProbablyVideo(normalized)) {
              print('DEBUG: Video detectado por Regex: $normalized');
              return VideoExtractionResult(videoUrl: normalized, subtitles: extractedSubtitles);
            }
          }
        }
      }

      print('DEBUG: No se encontró ningún video directo en la página.');
      return null;
    } catch (e) {
      print('DEBUG: Error durante la detección: $e');
      return null;
    }
  }

  /// Parses an .m3u8 master playlist to find available resolutions.
  static Future<List<VideoQuality>> getHlsQualities(String masterUrl, {Map<String, String>? headers, String? masterText}) async {
    List<VideoQuality> qualities = [];
    try {
      String body = masterText ?? "";
      if (body.isEmpty) {
        final response = await http.get(Uri.parse(masterUrl), headers: headers).timeout(const Duration(seconds: 5));
        if (response.statusCode != 200) {
           print('DEBUG: getHlsQualities HTTP ERROR ${response.statusCode}');
           return qualities;
        }
        body = response.body;
      }

      print('DEBUG: getHlsQualities BODY START: ${body.substring(0, body.length > 200 ? 200 : body.length)}');

      final lines = body.split('\n');
      String? currentRes;
      
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i].trim();
        if (line.startsWith('#EXT-X-STREAM-INF')) {
          final resMatch = RegExp(r'RESOLUTION=(\d+x\d+)').firstMatch(line);
          if (resMatch != null) {
            currentRes = resMatch.group(1);
          }
        } else if (line.isNotEmpty && !line.startsWith('#') && currentRes != null) {
          String qualityUrl = line.trim();
          if (!qualityUrl.startsWith('http')) {
            // Use proper URI resolution to avoid double-slash bugs
            final baseUri = Uri.parse(masterUrl);
            final parentPath = baseUri.path.substring(0, baseUri.path.lastIndexOf('/') + 1);
            final resolved = baseUri.replace(path: '$parentPath$qualityUrl', query: null, fragment: null);
            qualityUrl = resolved.toString();
          }
          print('DEBUG: getHlsQualities qualityUrl resolved: $qualityUrl');
          
          qualities.add(VideoQuality(
            resolution: _formatResolution(currentRes),
            url: qualityUrl,
          ));
          currentRes = null;
        }
      }
    } catch (e) {
      print('DEBUG: Error parsing HLS qualities: $e');
    }
    return qualities;
  }

  static String _formatResolution(String res) {
    if (res.contains('x')) {
      final height = res.split('x').last;
      return '${height}p';
    }
    return res;
  }

  static bool _isProbablyVideo(String url) {
    final lower = url.toLowerCase();
    return lower.contains('.mp4') || lower.contains('.m3u8') || lower.contains('.webm');
  }

  static String _normalizeUrl(String url, String base) {
    var cleanUrl = url.replaceAll(r'\', ''); // Limpiar escapes de JSON
    if (cleanUrl.startsWith('//')) return 'https:$cleanUrl';
    if (cleanUrl.startsWith('/')) {
      final uri = Uri.parse(base);
      return '${uri.scheme}://${uri.host}$cleanUrl';
    }
    return cleanUrl;
  }

  /// Scrapes description and rating from the movie's main page or video page.
  static Future<Map<String, dynamic>> scrapeMetadata(String url) async {
    print('-----------------------------------------');
    print('SCRAPING METADATA FROM: $url');
    print('-----------------------------------------');
    try {
      // Use EXACT headers from findDirectVideoUrl which are known to work
      final response = await http.get(Uri.parse(url), headers: {
        'User-Agent': 'Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Mobile/15E148 Safari/604.1'
      }).timeout(const Duration(seconds: 10));

      print('DEBUG SCRAPE: HTTP Response Status: ${response.statusCode}');
      if (response.statusCode != 200) {
        return {};
      }

      final body = response.body; 
      final document = html_parser.parse(body);
      final baseUrl = Uri.parse(url).origin;

      String? resolveUrl(String? path) {
        if (path == null || path.isEmpty) return null;
        var cleanPath = path.replaceAll(r'\', ''); // Clean JSON escapes
        if (cleanPath.startsWith('http')) return cleanPath;
        if (cleanPath.startsWith('//')) return 'https:$cleanPath';
        return '$baseUrl${cleanPath.startsWith('/') ? '' : '/'}$cleanPath';
      }

      String? description;
      String? year;
      String? duration;
      double rating = 0.0;

      // 0.1 Scrape Year
      final yearRegex = RegExp(r'\(?([12][0-9]{3})\)?');
      final titleText = document.querySelector('title')?.text ?? "";
      final yearMatch = yearRegex.firstMatch(titleText) ?? yearRegex.firstMatch(response.body);
      if (yearMatch != null) {
        year = yearMatch.group(1);
      }

      // 0.2 Scrape Duration
      final durationRegex = RegExp(r'(\d+\s*h[r]?)?\s*(\d+\s*min[s]?)');
      final durationMatch = durationRegex.firstMatch(response.body);
      if (durationMatch != null) {
        duration = durationMatch.group(0);
      }

      // 1. Scrape Description
      final metaDescription = document.querySelector('meta[name="description"]')?.attributes['content'] ??
                             document.querySelector('meta[property="og:description"]')?.attributes['content'];

      if (metaDescription != null && metaDescription.length > 10) {
        description = metaDescription;
      } else {
        // Try Regex search (similar to how we find video URLs)
        final descRegexes = [
          RegExp(r'"description"\s*:\s*"([^"]+)"'),
          RegExp(r'"overview"\s*:\s*"([^"]+)"'),
          RegExp(r'"synopsis"\s*:\s*"([^"]+)"'),
          RegExp(r'description\s*=\s*"([^"]+)"'),
        ];
        for (var regex in descRegexes) {
          final match = regex.firstMatch(body);
          if (match != null && (match.group(1)?.length ?? 0) > 20) {
            description = match.group(1);
            break;
          }
        }
        
        if (description == null) {
          // Search for keywords in text
          final bodyText = document.body?.text ?? "";
          final descriptionKeywords = ['introducción', 'descripción', 'detalles', 'sinopsis', 'resumen'];
          
          for (var keyword in descriptionKeywords) {
            // Look for headers (h1-h6) that contain the keyword
            final headers = document.querySelectorAll('h1, h2, h3, h4, h5, h6, strong, b');
            for (var header in headers) {
              if (header.text.toLowerCase().contains(keyword)) {
                // Try to get the next sibling or parent's next sibling that is a paragraph or div
                var sibling = header.nextElementSibling;
                if (sibling == null && header.parent != null) {
                  sibling = header.parent!.nextElementSibling;
                }
                
                if (sibling != null && sibling.text.trim().length > 20) {
                  description = sibling.text.trim();
                  break;
                }
              }
            }
            if (description != null) break;

            // Fallback: search for elements where the text starts with the keyword
            final elements = document.querySelectorAll('p, div, span');
            for (var element in elements) {
              final text = element.text.trim();
              if (text.toLowerCase().startsWith(keyword) && text.length > keyword.length + 10) {
                description = text.substring(keyword.length).replaceFirst(RegExp(r'^[:\s]+'), '').trim();
                break;
              }
            }
            if (description != null) break;
          }
        }
      }

      // 2. Scrape Rating
      // Try Regex search in raw body first
      final ratRegexes = [
        RegExp(r'"ratingValue"\s*:\s*"([^"]+)"'),
        RegExp(r'"ratingValue"\s*:\s*(\d+(\.\d+)?)'),
        RegExp(r'"score"\s*:\s*(\d+(\.\d+)?)'),
      ];
      for (var regex in ratRegexes) {
        final match = regex.firstMatch(body);
        if (match != null) {
          final val = match.group(1);
          if (val != null) {
            double raw = double.tryParse(val) ?? 0.0;
            if (raw > 10) raw = raw / 10.0; // handle 85/100
            rating = raw > 5 ? raw / 2.0 : raw;
            break;
          }
        }
      }

      if (rating == 0) {
        // Look for patterns like "7.8/10", "Rating: 4.5" or just a number inside rating classes
        final ratingRegex = RegExp(r'(\d+(\.\d+)?)\s*/\s*10');
        final match = ratingRegex.firstMatch(body);
        if (match != null) {
          double rawRating = double.tryParse(match.group(1) ?? "0") ?? 0.0;
          rating = rawRating / 2.0;
        } else {
          // Look for alternate patterns
          final altRatingRegex = RegExp(r'[Rr]ating:\s*(\d+(\.\d+)?)');
          final altMatch = altRatingRegex.firstMatch(body);
          if (altMatch != null) {
            rating = double.tryParse(altMatch.group(1) ?? "0") ?? 0.0;
          } else {
            // Look inside elements with rating classes
            final ratingElement = document.querySelector('.rating, .score, .vote-average');
            if (ratingElement != null) {
              final raw = double.tryParse(ratingElement.text.trim().replaceAll(RegExp(r'[^0-9.]'), '')) ?? 0.0;
              if (raw > 5)
                rating = raw / 2.0;
              else if (raw > 0) rating = raw;
            }
          }
        }
      }

      // Round rating as requested:
      if (rating > 0) {
        rating = (rating * 2).roundToDouble() / 2.0;
      }

      print('DEBUG SCRAPE: Descripcion encontrada: ${description != null ? (description!.length > 30 ? description!.substring(0, 30) : description) : "NULL"}');
      print('DEBUG SCRAPE: Poster encontrado: NULL');
      print('DEBUG SCRAPE: Backdrop encontrado: NULL');

      return {
        'description': description,
        'rating': rating,
        'year': year,
        'duration': duration,
      };
    } catch (e) {
      print('DEBUG: Error scraping metadata: $e');
      return {};
    }
  }
}
