import 'package:http/http.dart' as http;
import 'package:html/parser.dart' as html_parser;

class VideoService {
  /// Simulates Seekee logic: fetches a URL, parses HTML, and finds the direct video link.
  static Future<String?> findDirectVideoUrl(String webUrl) async {
    print('DEBUG: Iniciando detección para: $webUrl');
    try {
      if (webUrl.toLowerCase().endsWith('.mp4') || webUrl.toLowerCase().endsWith('.m3u8')) {
        print('DEBUG: El enlace ya es directo: $webUrl');
        return webUrl;
      }

      final response = await http.get(Uri.parse(webUrl), headers: {
        'User-Agent': 'Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Mobile/15E148 Safari/604.1'
      }).timeout(const Duration(seconds: 10));
      
      print('DEBUG: Respuesta de página principal: ${response.statusCode}');
      if (response.statusCode != 200) return null;
      
      final body = response.body;
      final document = html_parser.parse(body);
      
      // 1. Check <video> and <source> tags
      final videoElements = document.querySelectorAll('video, source');
      print('DEBUG: Elementos <video>/<source> encontrados: ${videoElements.length}');
      for (var element in videoElements) {
        final src = element.attributes['src'] ?? element.attributes['data-src'];
        if (src != null && _isProbablyVideo(src)) {
          final found = _normalizeUrl(src, webUrl);
          print('DEBUG: Video encontrado en tag: $found');
          return found;
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
            return _normalizeUrl(src, webUrl);
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
              return normalized;
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
}
