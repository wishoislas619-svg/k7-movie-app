import 'package:ffmpeg_kit_flutter_new_min_gpl/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_min_gpl/ffmpeg_kit_config.dart';
import 'package:ffmpeg_kit_flutter_new_min_gpl/return_code.dart';
import 'package:ffmpeg_kit_flutter_new_min_gpl/session_state.dart';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'dart:convert';
import 'dart:async';
import 'package:http/http.dart' as http;

class MediaProxyService {
  static final MediaProxyService _instance = MediaProxyService._internal();
  factory MediaProxyService() => _instance;
  MediaProxyService._internal();

  static String? lastCookies;
  static String? deviceUserAgent;

  HttpServer? _server;
  int _port = 0;
  String _localIp = '';
  final Map<String, _BridgeSession> _activeBridgeSessions = {};
  final Map<String, Map<String, String>> _pendingBridgeHeaders = {};

  /// Intenta revertir una URL proxeada a su URL original y headers.
  static Map<String, dynamic>? tryUnproxy(String proxiedUrl) {
    try {
      if (!proxiedUrl.contains('/proxy') && !proxiedUrl.contains('/bridge')) return null;
      final uri = Uri.parse(proxiedUrl);
      final bUrl = uri.queryParameters['url'];
      if (bUrl == null) return null;

      String normalize(String s) {
        int pad = 4 - (s.length % 4);
        if (pad < 4 && pad > 0) s += '=' * pad;
        return s;
      }

      final url = utf8.decode(base64Url.decode(normalize(bUrl)));
      final hParam = uri.queryParameters['h'];
      Map<String, String>? headers;
      if (hParam != null) {
        final decoded = utf8.decode(base64Url.decode(normalize(hParam)));
        headers = Map<String, String>.from(json.decode(decoded));
      }
      return {'url': url, 'headers': headers};
    } catch (_) {
      return null;
    }
  }

  Future<void> start() async {
    if (_server != null) return;
    try {
      _server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
      _port = _server!.port;
      _refreshLocalIp();
      
      _server!.listen((HttpRequest request) {
        if (request.uri.path.startsWith('/bridge')) {
          _handleBridgeRequest(request);
        } else if (request.uri.path.startsWith('/proxy')) {
          _handleProxyRequest(request);
        } else {
          request.response.statusCode = HttpStatus.notFound;
          request.response.close();
        }
      });
      
      print('🚀 [PROXY] Running at http://$_localIp:$_port');
    } catch (e) {
      print('❌ [PROXY] Error starting: $e');
    }
  }

  // --- LÓGICA DE PROXY (ALGO 1: FRAGMENTOS) ---
  Future<void> _handleProxyRequest(HttpRequest request) async {
    final encodedUrl = request.uri.queryParameters['url'];
    final encodedHeaders = request.uri.queryParameters['h'] ?? request.uri.queryParameters['headers'];
    final algoParam = request.uri.queryParameters['a'];
    final bid = request.uri.queryParameters['bid']; // Bridge ID
    
    if (encodedUrl == null) {
      request.response.statusCode = HttpStatus.badRequest;
      await request.response.close();
      return;
    }

    String normalize(String s) {
      int pad = 4 - (s.length % 4);
      if (pad < 4 && pad > 0) s += '=' * pad;
      return s;
    }

    final url = utf8.decode(base64Url.decode(normalize(encodedUrl)));
    final requestId = DateTime.now().millisecondsSinceEpoch.toString().substring(7);
    final Map<String, String> headers = {};
    final bool isManifestRequest = url.contains('.m3u8') || url.contains('playlist') || url.contains('master');

    // 1. Cabeceras de la TV
    request.headers.forEach((name, values) {
      final n = name.toLowerCase();
      if (n != 'host' && n != 'connection') {
        if (isManifestRequest && n == 'range') return; // Quitar range solo en manifiestos
        headers[name] = values.join(', ');
      }
    });

    // 2. Cabeceras proxiadas (Inyectadas por el extractor)
    if (encodedHeaders != null) {
      try {
        final decoded = jsonDecode(utf8.decode(base64Url.decode(normalize(encodedHeaders))));
        if (decoded is Map) {
          decoded.forEach((k, v) => headers[k.toString()] = v.toString());
        }
      } catch (_) {}
    }

    // 💡 REUPERAR HEADERS DE MEMORIA (para el puente)
    if (bid != null && _pendingBridgeHeaders.containsKey(bid)) {
      print('📥 [PROXY] Recovering headers for bridge bid: $bid');
      headers.addAll(_pendingBridgeHeaders[bid]!);
    }

    print('🔍 [PROXY][$requestId] Request: $url');

    // 🌉 AUTO-BRIDGE: Si es un manifiesto HLS, lo convertimos en Puente MPEG-TS automáticamente
    if (isManifestRequest && bid == null) {
      print('🌉 [PROXY_AUTO_BRIDGE] Capturada petición HLS. Transmutando a Puente MPEG-TS...');
      _handleBridgeRequest(request, encodedUrl, encodedHeaders);
      return;
    }

    try {
      final client = http.Client();
      final proxyRequest = http.Request(request.method, Uri.parse(url));
      headers.forEach((k, v) => proxyRequest.headers[k] = v);
      proxyRequest.followRedirects = true;

      final streamedResponse = await client.send(proxyRequest);
      final upstreamContentType = (streamedResponse.headers['content-type'] ?? '').toLowerCase();
      
      bool isHls = upstreamContentType.contains('mpegurl') || upstreamContentType.contains('apple.mpegurl') || url.contains('.m3u8');

      if (isHls) {
        final fullBody = await streamedResponse.stream.bytesToString();
        final requestHost = request.headers.value(HttpHeaders.hostHeader) ?? '$_localIp:$_port';
        final rewrittenBody = _rewriteM3u8(fullBody, url, headers, requestHost, algorithm: algoParam, bid: bid);
        
        request.response.headers.contentType = ContentType.parse('application/vnd.apple.mpegurl');
        request.response.add(utf8.encode(rewrittenBody));
        await request.response.close();
        client.close();
      } else {
        _serveStream(request, streamedResponse, null, streamedResponse.stream, algoParam, url, upstreamContentType, client, requestId);
      }
    } catch (e) {
      print('❌ [PROXY][$requestId] Error: $e');
      request.response.statusCode = HttpStatus.serviceUnavailable;
      await request.response.close();
    }
  }

  void _serveStream(HttpRequest request, http.StreamedResponse response, List<int>? firstChunk, Stream<List<int>> stream, String? algoParam, String url, String upstreamContentType, http.Client client, String requestId) async {
    request.response.statusCode = response.statusCode;
    
    // Copiar cabeceras base
    response.headers.forEach((key, value) {
      final k = key.toLowerCase();
      if (k != 'transfer-encoding' && k != 'content-encoding' && k != 'content-type') {
        request.response.headers.set(key, value);
      }
    });

    request.response.headers.set('Access-Control-Allow-Origin', '*');
    request.response.headers.set('Connection', 'keep-alive');

    // --- LÓGICA DE REMUXING (CONVERSIÓN TS -> MP4 PARA FRAGMENTOS) ---
    if (algoParam == '1' && (url.contains('.ts') || url.contains('segment') || upstreamContentType.contains('mp2t'))) {
      print('🎬 [REMUX][$requestId] Converting fragment to MP4 for Smart TV...');
      try {
        final List<int> bytes = [];
        if (firstChunk != null) bytes.addAll(firstChunk);
        await for (var chunk in stream) {
          bytes.addAll(chunk);
        }

        final tempDir = await getTemporaryDirectory();
        final inputPath = '${tempDir.path}/in_$requestId.ts';
        final outputPath = '${tempDir.path}/out_$requestId.mp4';
        
        await File(inputPath).writeAsBytes(bytes);

        final ffmpegCommand = '-i "$inputPath" -c copy -f mp4 -movflags frag_keyframe+empty_moov -y "$outputPath"';
        
        final session = await FFmpegKit.execute(ffmpegCommand);
        final returnCode = await session.getReturnCode();
        
        if (ReturnCode.isSuccess(returnCode)) {
          final convertedBytes = await File(outputPath).readAsBytes();
          request.response.headers.set('content-type', 'video/mp4');
          request.response.headers.contentLength = convertedBytes.length;
          request.response.add(convertedBytes);
          print('✅ [REMUX][$requestId] Success! Sent as MP4');
        } else {
          request.response.headers.set('content-type', 'video/MP2T');
          request.response.add(bytes);
        }

        try { await File(inputPath).delete(); await File(outputPath).delete(); } catch (_) {}
      } catch (e) {
        print('⚠️ [REMUX][$requestId] Error: $e');
      } finally {
        await request.response.close();
        client.close();
      }
      return;
    }

    // Flujo normal para otros archivos
    request.response.headers.set('content-type', upstreamContentType);
    if (firstChunk != null) request.response.add(firstChunk);
    await request.response.addStream(stream);
    await request.response.close();
    client.close();
  }

  // --- LÓGICA DE PUENTE (TRANSCODING STREAM COMPLETO) ---
  void _handleBridgeRequest(HttpRequest request, [String? overrideUrl, String? overrideHeaders]) async {
    final encodedUrl = overrideUrl ?? request.uri.queryParameters['url'];
    final encodedHeaders = overrideHeaders ?? request.uri.queryParameters['h'];
    
    if (encodedUrl == null) {
      request.response.statusCode = HttpStatus.badRequest;
      request.response.write('Falta URL');
      await request.response.close();
      return;
    }

    String normalize(String s) {
      int pad = 4 - (s.length % 4);
      if (pad < 4 && pad > 0) s += '=' * pad;
      return s;
    }

    final requestId = DateTime.now().millisecondsSinceEpoch.toString().substring(7);
    final String hlsUrl = utf8.decode(base64Url.decode(normalize(encodedUrl)));
    
    _BridgeSession? currentSession = _activeBridgeSessions[hlsUrl];
    String? pipePath;

    if (currentSession != null) {
      print('♻️ [BRIDGE] Reusing session for: $hlsUrl');
      pipePath = currentSession.filePath;
    } else {
      final tempDir = await getTemporaryDirectory();
      pipePath = '${tempDir.path}/bridge_${requestId}.ts';
      
      // 🧠 MEMORIA DE CABECERAS: Guardar para FFmpeg
      if (encodedHeaders != null) {
        try {
          final decoded = json.decode(utf8.decode(base64Url.decode(normalize(encodedHeaders))));
          if (decoded is Map) {
            _pendingBridgeHeaders[requestId] = Map<String, String>.from(decoded);
          }
        } catch (_) {}
      }
      
      // 🚀 COMANDO CORTO: Usamos la IP REAL y un ID de referencia (bid)
      // Esto evita que el comando sea demasiado largo y falle en Android.
      final localProxyUrl = 'http://$_localIp:$_port/proxy?url=$encodedUrl&bid=$requestId';
      
      FFmpegKitConfig.enableLogCallback((log) {
        if (log.getMessage().contains('Error') || log.getMessage().contains('http') || log.getMessage().contains('Protocol')) {
          print('🎬 [FFMPEG-LOG] ${log.getMessage()}');
        }
      });

      final ffmpegCommand = '-allowed_extensions ALL -i "$localProxyUrl" -c copy -f mpegts -y "$pipePath"';
      print('🌉 [BRIDGE][$requestId] Starting Bridge (Bypass Short-Url): $hlsUrl');
      print('🎬 [BRIDGE] Command: ffmpeg $ffmpegCommand');
      
      final session = await FFmpegKit.executeAsync(ffmpegCommand);
      currentSession = _BridgeSession(session, pipePath);
      _activeBridgeSessions[hlsUrl] = currentSession;
    }

    try {
      request.response.headers.set('Content-Type', 'video/mp2t');
      request.response.headers.set('Access-Control-Allow-Origin', '*');
      request.response.headers.set('Accept-Ranges', 'none');
      request.response.headers.set('Connection', 'keep-alive');

      final file = File(pipePath);
      int retry = 0;
      while (!(await file.exists()) && retry < 40) {
        await Future.delayed(Duration(milliseconds: 100));
        retry++;
      }
      
      int lastPos = 0;
      int idleCount = 0;
      int totalSent = 0;

      while (true) {
        if (await file.exists()) {
          final currentLength = await file.length();
          if (currentLength > lastPos) {
            idleCount = 0;
            final raf = await file.open();
            await raf.setPosition(lastPos);
            final buffer = await raf.read(currentLength - lastPos);
            await raf.close();
            
            request.response.add(buffer);
            await request.response.flush();
            
            totalSent += buffer.length;
            lastPos = currentLength;
            
            if (lastPos % 100000 == 0) { // Loguear cada ~100KB para no saturar
               print('📡 [BRIDGE][$requestId] Sent: ${(totalSent/1024/1024).toStringAsFixed(2)} MB');
            }
          } else {
            idleCount++;
            final returnCode = await currentSession.ffmpegSession.getReturnCode();
            if (returnCode != null && idleCount > 100) {
               print('🏁 [BRIDGE] FFmpeg finished (Code: $returnCode)');
               break; 
            }
            await Future.delayed(Duration(milliseconds: 100));
          }
        } else {
          await Future.delayed(Duration(milliseconds: 100));
        }
      }
    } catch (e) {
      print('❌ [BRIDGE] Request interrupted: $e');
    } finally {
      // SOLO eliminamos la sesión del mapa si nosotros somos los dueños (el pipePath coincide con el requestId)
      if (pipePath.contains(requestId)) {
         _activeBridgeSessions.remove(hlsUrl);
         print('🏁 [BRIDGE] Main session cleaned up');
      }
      await request.response.close();
    }
  }

  String _rewriteM3u8(String content, String playlistUrl, Map<String, String> headers, String requestHost, {String? algorithm, String? bid}) {
    final lines = LineSplitter.split(content);
    final List<String> rewrittenLines = [];
    final baseUri = Uri.parse(playlistUrl);
    bool hasEndList = false;

    for (var line in lines) {
      final trimmedLine = line.trim();
      if (trimmedLine.isEmpty) continue;
      if (trimmedLine.contains('#EXT-X-ENDLIST')) hasEndList = true;

      if (trimmedLine.startsWith('#')) {
        String newLine = trimmedLine;
        final uriMatch = RegExp(r'URI\s*=\s*"([^"]+)"', caseSensitive: false).firstMatch(trimmedLine);
        if (uriMatch != null) {
          final internalUrl = uriMatch.group(1)!;
          final absoluteUri = baseUri.resolve(internalUrl);
          final proxiedUrl = _buildProxiedUrl(absoluteUri.toString(), headers, requestHost, algorithm: algorithm != null ? int.tryParse(algorithm) : null, bid: bid);
          newLine = trimmedLine.replaceFirst(internalUrl, proxiedUrl);
        }
        rewrittenLines.add(newLine);
      } else {
        final absoluteUri = baseUri.resolve(trimmedLine);
        final proxiedUrl = _buildProxiedUrl(absoluteUri.toString(), headers, requestHost, algorithm: algorithm != null ? int.tryParse(algorithm) : null, bid: bid);
        rewrittenLines.add(proxiedUrl);
      }
    }
    if (!hasEndList) rewrittenLines.add('#EXT-X-ENDLIST');
    return rewrittenLines.join('\n');
  }

  String _buildProxiedUrl(String url, Map<String, String>? headers, String host, {int? algorithm, String? bid}) {
    final bUrl = base64Url.encode(utf8.encode(url)).replaceAll('=', '');
    String? bHeaders;
    if (headers != null && headers.isNotEmpty) {
      bHeaders = base64Url.encode(utf8.encode(jsonEncode(headers))).replaceAll('=', '');
    }

    String extension = '.mp4';
    if (url.toLowerCase().contains('.m3u8')) extension = '.m3u8';
    if (url.toLowerCase().contains('.ts')) extension = '.ts';
    
    var proxyUrl = 'http://$host/proxy$extension?url=$bUrl';
    if (bHeaders != null) proxyUrl += '&h=$bHeaders';
    if (algorithm != null) proxyUrl += '&a=$algorithm';
    if (bid != null) proxyUrl += '&bid=$bid';

    return proxyUrl;
  }

  String getProxiedUrl(String url, Map<String, String>? headers, {bool useLocalhost = false, int? algorithm}) {
    String host = (useLocalhost || _localIp.isEmpty) ? '127.0.0.1:$_port' : '$_localIp:$_port';
    return _buildProxiedUrl(url, headers, host, algorithm: algorithm);
  }

  void _refreshLocalIp() {
    NetworkInterface.list(type: InternetAddressType.IPv4).then((interfaces) {
      for (var iface in interfaces) {
        for (var addr in iface.addresses) {
          final ip = addr.address;
          if (ip.startsWith('192.168.') || ip.startsWith('10.') || RegExp(r'^172\.(1[6-9]|2[0-9]|3[0-1])\.').hasMatch(ip)) {
            _localIp = ip;
            return;
          }
        }
      }
    }).catchError((_) {});
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
    _port = 0;
  }
}

class _BridgeSession {
  final dynamic ffmpegSession;
  final String filePath;
  _BridgeSession(this.ffmpegSession, this.filePath);
}
