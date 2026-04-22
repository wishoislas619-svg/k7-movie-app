import 'dart:io';
import 'dart:convert';
import 'package:http/http.dart' as http;

class MediaProxyService {
  static final MediaProxyService _instance = MediaProxyService._internal();
  factory MediaProxyService() => _instance;
  MediaProxyService._internal();

  HttpServer? _server;
  int _port = 0;
  String _localIp = '';

  int get port => _port;
  String get localIp => _localIp;

  Future<void> start() async {
    if (_server != null) return;

    try {
      _server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
      _port = _server!.port;
      
      // Encontrar la IP local (WiFi / Hotspot) — cubrimos todos los rangos privados RFC-1918
      final interfaces = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );
      outer:
      for (var iface in interfaces) {
        for (var addr in iface.addresses) {
          final ip = addr.address;
          // Rangos RFC-1918: 192.168.x.x | 10.x.x.x | 172.16-31.x.x
          if (ip.startsWith('192.168.') ||
              ip.startsWith('10.') ||
              RegExp(r'^172\.(1[6-9]|2[0-9]|3[0-1])\.').hasMatch(ip)) {
            _localIp = ip;
            break outer;
          }
        }
      }

      print('🎬 [PROXY] Servidor iniciado en http://$_localIp:$_port');

      _server!.listen((HttpRequest request) async {
        try {
          if (request.uri.path == '/proxy') {
            await _handleProxyRequest(request);
          } else {
            request.response.statusCode = HttpStatus.notFound;
            await request.response.close();
          }
        } catch (e) {
          print('❌ [PROXY] Error manejando petición: $e');
          request.response.statusCode = HttpStatus.internalServerError;
          await request.response.close();
        }
      });
    } catch (e) {
      print('❌ [PROXY] No se pudo iniciar el servidor: $e');
    }
  }

  Future<void> _handleProxyRequest(HttpRequest request) async {
    final encodedUrl = request.uri.queryParameters['url'];
    final encodedHeaders = request.uri.queryParameters['headers'];

    if (encodedUrl == null) {
      request.response.statusCode = HttpStatus.badRequest;
      await request.response.close();
      return;
    }

    final url = utf8.decode(base64Url.decode(encodedUrl));
    Map<String, String> headers = {};
    if (encodedHeaders != null) {
      headers = Map<String, String>.from(json.decode(utf8.decode(base64Url.decode(encodedHeaders))));
    }

    print('🚀 [PROXY] Redirigiendo a: $url');

    // Aplicar cabeceras por defecto solo si no vienen en la petición original
    if (url.contains('videasy') || url.contains('embed.su') || url.contains('mdisk')) {
       headers['Referer'] ??= 'https://embed.su/';
       headers['Origin'] ??= 'https://embed.su';
    }
    
    // SPOOFING: Si es Algoritmo 1, nos hacemos pasar por un celular (Android)
    // Muchos servidores de Algoritmo 1 bloquean si el User-Agent parece una TV o Desktop
    final isAlgo1 = headers['X-Proxy-Algorithm'] == '1' || (url.contains('m3u8') && !url.contains('embed.su') && !url.contains('videasy'));
    final isAlgo2Or3 = headers['X-Proxy-Algorithm'] == '2' || headers['X-Proxy-Algorithm'] == '3' || url.contains('videasy') || url.contains('embed.su');

    if (isAlgo1) {
      headers['User-Agent'] = 'Mozilla/5.0 (Linux; Android 13; SM-S918B) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/116.0.0.0 Mobile Safari/537.36';
      print('📱 [PROXY] Aplicando User-Agent móvil (Algo 1)');
    } else if (isAlgo2Or3) {
      headers['User-Agent'] = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/121.0.0.0 Safari/537.36';
      headers['Sec-Fetch-Dest'] ??= 'video';
      headers['Sec-Fetch-Mode'] ??= 'cors';
      headers['Sec-Fetch-Site'] ??= 'cross-site';
      print('💻 [PROXY] Aplicando User-Agent Desktop (Algo 2/3)');
    } else {
      // User Agent amigable para SmartTVs por defecto
      headers['User-Agent'] ??= 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';
    }
    
    // Limpiar headers internos de control antes de enviar al upstream
    headers.remove('X-Proxy-Algorithm');

    try {
      final client = http.Client();
      final proxyRequest = http.Request('GET', Uri.parse(url))
        ..headers.addAll(headers)
        ..followRedirects = true;

      final response = await client.send(proxyRequest);

      // Copiar headers de respuesta (importante para Content-Type y Rangos)
      request.response.statusCode = response.statusCode;
      response.headers.forEach((key, value) {
        if (key.toLowerCase() != 'transfer-encoding' && key.toLowerCase() != 'content-encoding') {
          request.response.headers.set(key, value);
        }
      });

      // Habilitar CORS para el dispositivo receptor
      request.response.headers.set('Access-Control-Allow-Origin', '*');
      request.response.headers.set('Access-Control-Allow-Methods', 'GET, OPTIONS');
      request.response.headers.set('Access-Control-Allow-Headers', '*');

      final contentType = response.headers['content-type']?.toLowerCase() ?? '';
      final isM3u8 = contentType.contains('mpegurl') || url.toLowerCase().contains('.m3u8');

      if (isM3u8) {
        // 📝 REESCRITURA DE M3U8: Leemos la lista y proxiamos cada enlace interno
        final body = await response.stream.bytesToString();
        final rewrittenBody = _rewriteM3u8(body, url, headers);
        request.response.write(rewrittenBody);
        await request.response.close();
        print('♻️ [PROXY] Lista M3U8 reescrita para forzar túnel en segmentos');
      } else {
        // Streaming directo para segmentos (.ts) o archivos MP4
        await request.response.addStream(response.stream);
        await request.response.close();
      }
    } catch (e) {
      print('❌ [PROXY] Error en upstream: $e');
      request.response.statusCode = HttpStatus.serviceUnavailable;
      await request.response.close();
    }
  }

  String _rewriteM3u8(String content, String baseUrl, Map<String, String> originalHeaders) {
    final lines = LineSplitter.split(content);
    final rewrittenLines = <String>[];
    final baseUri = Uri.parse(baseUrl);

    for (var line in lines) {
      if (line.isEmpty) {
        rewrittenLines.add(line);
        continue;
      }

      if (line.startsWith('#')) {
        // Buscar URIs dentro de tags (ej: #EXT-X-KEY:METHOD=AES-128,URI="...")
        var newLine = line;
        final uriRegex = RegExp(r'URI="([^"]+)"');
        final match = uriRegex.firstMatch(line);
        if (match != null) {
          final internalUrl = match.group(1)!;
          final absoluteUri = baseUri.resolve(internalUrl);
          final proxiedUrl = getProxiedUrl(absoluteUri.toString(), originalHeaders);
          newLine = line.replaceFirst(internalUrl, proxiedUrl);
        }
        rewrittenLines.add(newLine);
      } else {
        // Es una URL de segmento o de sub-playlist, la proxiamos
        final absoluteUri = baseUri.resolve(line);
        final proxiedUrl = getProxiedUrl(absoluteUri.toString(), originalHeaders);
        rewrittenLines.add(proxiedUrl);
      }
    }
    return rewrittenLines.join('\n');
  }

  String getProxiedUrl(String url, Map<String, String>? headers) {
    if (_localIp.isEmpty) return url; // Fallback si no hay proxy

    final bUrl = base64Url.encode(utf8.encode(url));
    final bHeaders = headers != null ? base64Url.encode(utf8.encode(json.encode(headers))) : null;

    var proxyUrl = 'http://$_localIp:$_port/proxy?url=$bUrl';
    if (bHeaders != null) {
      proxyUrl += '&headers=$bHeaders';
    }
    return proxyUrl;
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
    _port = 0;
    _localIp = '';
  }
}
