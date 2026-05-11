import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:ffmpeg_kit_flutter_new_full_gpl/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_full_gpl/ffmpeg_kit_config.dart';
import 'package:ffmpeg_kit_flutter_new_full_gpl/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new_full_gpl/ffmpeg_session.dart';

class _BridgeSession {
  final FFmpegSession? session;
  final String pipePath;

  _BridgeSession(this.session, this.pipePath);
}

class MediaProxyService {
  static final MediaProxyService _instance = MediaProxyService._internal();
  factory MediaProxyService() => _instance;
  MediaProxyService._internal();

  static String? lastCookies;
  static String? deviceUserAgent;

  HttpServer? _server;
  final _httpClient = http.Client();
  String _localIp = '127.0.0.1';
  int _port = 0;

  final Map<String, _BridgeSession> _activeBridgeSessions = {};
  final Map<String, Map<String, String>> _pendingBridgeHeaders = {};
  final Map<String, String> _localFileRegistry = {};
  final Map<String, String> _remuxedFiles = {};
  final Map<String, Map<String, String>> _preResolvedStreams = {};

  String get localIp => _localIp;
  int get port => _port;

  static Map<String, dynamic>? tryUnproxy(String url) {
    if (url.contains('/proxy?url=')) {
      try {
        final uri = Uri.parse(url);
        final encodedUrl = uri.queryParameters['url'];
        final encodedHeaders = uri.queryParameters['headers'];
        
        if (encodedUrl != null) {
          String s = encodedUrl;
          int pad = 4 - (s.length % 4);
          if (pad < 4 && pad > 0) s += '=' * pad;
          final decodedUrl = utf8.decode(base64Url.decode(s));
          
          Map<String, String> headers = {};
          if (encodedHeaders != null) {
            String hs = encodedHeaders;
            int hpad = 4 - (hs.length % 4);
            if (hpad < 4 && hpad > 0) hs += '=' * hpad;
            headers = Map<String, String>.from(json.decode(utf8.decode(base64Url.decode(hs))));
          }
          
          return {
            'url': decodedUrl,
            'headers': headers,
          };
        }
      } catch (_) {}
    }
    return null;
  }

  Future<void> start({String? targetIp}) async {
    if (_server != null) return;
    _server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    _port = _server!.port;
    _localIp = await _getHostIp();
    
    print('🚀 [PROXY] Running at http://$_localIp:$_port');

    FFmpegKitConfig.enableLogCallback((log) {
      final msg = log.getMessage();
      if (msg.contains('Error') || msg.contains('failed') || msg.contains('Opening')) {
         print('🎬 [FFMPEG_LOG] $msg');
      }
    });
    
    _server!.listen(_handleRequest);
  }

  Future<String> _getHostIp() async {
    for (var interface in await NetworkInterface.list()) {
      for (var addr in interface.addresses) {
        if (addr.type == InternetAddressType.IPv4 && !addr.isLoopback) {
          return addr.address;
        }
      }
    }
    return '127.0.0.1';
  }

  Future<void> preResolve(String url, Map<String, String>? headers, {String? explicitAudioUrl}) async {
    if (_preResolvedStreams.containsKey(url)) return;
    print('🕵️ [PRE-RESOLVE] Iniciando búsqueda y PRE-FUSIÓN para: $url');
    
    Map<String, String> streams;
    if (explicitAudioUrl != null) {
      streams = {'video': url, 'audio': explicitAudioUrl};
      print('🕵️ [PRE-RESOLVE] Usando audio EXPLÍCITO proporcionado por el Player');
    } else {
      streams = await _resolveMasterStreams(url, headers);
    }
    
    _preResolvedStreams[url] = streams;
    
    if (streams.containsKey('audio')) {
       print('🎬 [PRE-RESOLVE] Iniciando FFmpeg Bridge en caliente...');
       _prepareBridgeForUrl(url, streams, headers);
    }
  }

  Future<void> _prepareBridgeForUrl(String hlsUrl, Map<String, String> streams, Map<String, String>? headers) async {
    final requestId = base64Url.encode(utf8.encode(hlsUrl)).replaceAll('=', '').substring(0, 8);
    
    // 🔒 BLOQUEO DE CONCURRENCIA: Si ya existe o está en proceso, salir
    if (_activeBridgeSessions.containsKey(hlsUrl)) return;
    
    final tempDir = await getTemporaryDirectory();
    final pipePath = '${tempDir.path}/bridge_$requestId.mp4';
    
    // Registrar inmediatamente para bloquear otras peticiones concurrentes
    _activeBridgeSessions[hlsUrl] = _BridgeSession(null, pipePath);

    if (File(pipePath).existsSync()) {
      try { File(pipePath).deleteSync(); } catch (_) {}
    }

    final videoUrl = streams['video']!;
    final audioUrl = streams['audio'];

    // Extraer User-Agent para pasarlo de forma explícita (más fiable en FFmpeg)
    final userAgent = headers?['User-Agent'] ?? headers?['user-agent'] ?? 'Mozilla/5.0';
    final cleanHeaders = Map<String, String>.from(headers ?? {});
    cleanHeaders.remove('User-Agent');
    cleanHeaders.remove('user-agent');

    final List<String> ffmpegArgs = [
      '-hide_banner',
      '-loglevel', 'info',
      '-probesize', '10M',
      '-analyzeduration', '10M',
      '-reconnect', '1',
      '-reconnect_at_eof', '1',
      '-reconnect_streamed', '1',
      '-reconnect_delay_max', '2',
      '-user_agent', userAgent,
    ];

    // Añadir headers si existen
    if (cleanHeaders.isNotEmpty) {
      String headerString = "";
      cleanHeaders.forEach((k, v) {
        headerString += "$k: $v\r\n";
      });
      ffmpegArgs.addAll(['-headers', headerString]);
    }

    // Inputs
    ffmpegArgs.addAll(['-i', videoUrl]);
    if (audioUrl != null) {
      ffmpegArgs.addAll(['-i', audioUrl]);
      ffmpegArgs.addAll(['-map', '0:v:0', '-map', '1:a:0']);
    } else {
      ffmpegArgs.addAll(['-map', '0:v:0', '-map', '0:a?']);
    }

    // Output flags
    ffmpegArgs.addAll([
      '-c:v', 'copy',
      '-c:a', 'aac',
      '-b:a', '128k',
      '-ar', '44100',
      '-ac', '2',
      '-f', 'mp4',
      '-movflags', 'frag_keyframe+empty_moov+default_base_moof',
      '-y',
      pipePath
    ]);

    print('🎬 [HOT-BRIDGE] CMD: ffmpeg ${ffmpegArgs.join(' ')}');
    
    // Usar ejecución asíncrona para no bloquear el proxy
    final session = await FFmpegKit.executeWithArgumentsAsync(ffmpegArgs, (session) async {
      final state = await session.getState();
      final returnCode = await session.getReturnCode();
      print('🎬 [HOT-BRIDGE] Sesión finalizada: State=$state, ReturnCode=$returnCode');
      
      if (returnCode?.getValue() != 0) {
        final logs = await session.getLogs();
        for (var log in logs) {
           print('🎬 [HOT-BRIDGE][ERROR_LOG] ${log.getMessage()}');
        }
      }
      _activeBridgeSessions.remove(hlsUrl);
    }, (log) {
      print('🎬 [FFMPEG] ${log.getMessage()}');
    });

    final sessionId = await session.getSessionId();
    print('🎬 [HOT-BRIDGE] Sesión iniciada: $sessionId');
    
    _activeBridgeSessions[hlsUrl] = _BridgeSession(session, pipePath);
  }

  String getProxiedUrl(String url, Map<String, String>? headers, {bool useLocalhost = false, int? algorithm = 1, bool remux = false, bool useBridge = false, String? explicitAudioUrl, String? bid}) {
    final ip = useLocalhost ? '127.0.0.1' : _localIp;
    final encodedUrl = base64Url.encode(utf8.encode(url)).replaceAll('=', '');
    String proxyUrl = 'http://$ip:$_port/proxy?url=$encodedUrl';
    
    if (headers != null && headers.isNotEmpty) {
      final encodedHeaders = base64Url.encode(utf8.encode(json.encode(headers))).replaceAll('=', '');
      proxyUrl += '&headers=$encodedHeaders';
    }
    
    final algo = algorithm ?? 1;
    if (algo != 1) proxyUrl += '&algo=$algo';
    if (remux) proxyUrl += '&remux=1';
    if (useBridge) proxyUrl += '&bridge=1';
    if (bid != null) proxyUrl += '&bid=$bid';
    if (explicitAudioUrl != null) {
      final encA = base64Url.encode(utf8.encode(explicitAudioUrl)).replaceAll('=', '');
      proxyUrl += '&aUrl=$encA';
    }
    
    return proxyUrl;
  }

  void _handleRequest(HttpRequest request) async {
    final urlParam = request.uri.queryParameters['url'];
    final headersParam = request.uri.queryParameters['headers'];
    final bridgeParam = request.uri.queryParameters['bridge'];
    final bid = request.uri.queryParameters['bid'];
    final explicitAudioParam = request.uri.queryParameters['aUrl']; // <--- EXTRAER AUDIO EXPLÍCITO

    if (urlParam == null) {
      request.response.statusCode = HttpStatus.badRequest;
      await request.response.close();
      return;
    }

    if (bridgeParam == '1') {
      _handleBridgeRequest(request, urlParam, headersParam, explicitAudioParam);
      return;
    }

    String normalize(String s) {
      int pad = 4 - (s.length % 4);
      if (pad < 4 && pad > 0) s += '=' * pad;
      return s;
    }

    final url = utf8.decode(base64Url.decode(normalize(urlParam)));
    final Map<String, String> headers = {};
    if (headersParam != null) {
      try {
        final decoded = json.decode(utf8.decode(base64Url.decode(normalize(headersParam))));
        if (decoded is Map) headers.addAll(Map<String, String>.from(decoded));
      } catch (_) {}
    }

    if (bid != null && _pendingBridgeHeaders.containsKey(bid)) {
      headers.addAll(_pendingBridgeHeaders[bid]!);
    }

    try {
      final proxyReq = http.Request(request.method, Uri.parse(url));
      headers.forEach((k, v) => proxyReq.headers[k] = v);
      final streamedRes = await _httpClient.send(proxyReq);

      if (url.contains('.m3u8') || (streamedRes.headers['content-type'] ?? '').contains('mpegurl')) {
        final body = await streamedRes.stream.bytesToString();
        final requestHost = request.headers.value(HttpHeaders.hostHeader) ?? '$_localIp:$_port';
        final rewritten = _rewriteM3u8(body, url, headers, requestHost, bid: bid);
        request.response.headers.contentType = ContentType.parse('application/vnd.apple.mpegurl');
        request.response.add(utf8.encode(rewritten));
        await request.response.close();
      } else {
        request.response.statusCode = streamedRes.statusCode;
        streamedRes.headers.forEach((k, v) => request.response.headers.set(k, v));
        await request.response.addStream(streamedRes.stream);
        await request.response.close();
      }
    } catch (e) {
      request.response.statusCode = HttpStatus.serviceUnavailable;
      await request.response.close();
    }
  }

  void _handleBridgeRequest(HttpRequest request, String encodedUrl, String? encodedHeaders, String? encodedAudioUrl) async {
    String normalize(String s) {
      int pad = 4 - (s.length % 4);
      if (pad < 4 && pad > 0) s += '=' * pad;
      return s;
    }

    final hlsUrl = utf8.decode(base64Url.decode(normalize(encodedUrl)));
    final requestId = DateTime.now().millisecondsSinceEpoch.toString().substring(7);
    
    Map<String, String>? headerMap;
    if (encodedHeaders != null) {
      try {
        final decoded = json.decode(utf8.decode(base64Url.decode(normalize(encodedHeaders))));
        if (decoded is Map) headerMap = Map<String, String>.from(decoded);
      } catch (_) {}
    }

    if (!_activeBridgeSessions.containsKey(hlsUrl)) {
       print('🌉 [BRIDGE][$requestId] Iniciando bridge bajo demanda...');
       
       String? explicitAudio;
       if (encodedAudioUrl != null) {
         try {
           explicitAudio = utf8.decode(base64Url.decode(normalize(encodedAudioUrl)));
           print('🌉 [BRIDGE][$requestId] Audio explícito recibido: $explicitAudio');
         } catch (_) {}
       }

       if (!_preResolvedStreams.containsKey(hlsUrl)) {
          final streams = await _resolveMasterStreams(hlsUrl, headerMap);
          if (explicitAudio != null) streams['audio'] = explicitAudio; // <--- USAR AUDIO EXPLÍCITO
          _preResolvedStreams[hlsUrl] = streams;
       }
       await _prepareBridgeForUrl(hlsUrl, _preResolvedStreams[hlsUrl]!, headerMap);
    }

    final session = _activeBridgeSessions[hlsUrl]!;
    final pipePath = session.pipePath;

    request.response.headers.contentType = ContentType.parse('video/mp4');
    request.response.headers.set('Accept-Ranges', 'bytes');
    request.response.headers.set('Access-Control-Allow-Origin', '*');

    // Esperar hasta 30 segundos a que el archivo tenga datos (buffer inicial)
    for (int i = 0; i < 300; i++) {
      if (File(pipePath).existsSync() && File(pipePath).lengthSync() > 1024 * 128) break;
      await Future.delayed(const Duration(milliseconds: 100));
    }

    final file = File(pipePath);
    if (!file.existsSync() || file.lengthSync() < 100) {
      print('🌉 [BRIDGE][$requestId] ERROR: El archivo puente no se generó a tiempo o FFmpeg falló');
      request.response.statusCode = HttpStatus.internalServerError;
      await request.response.close();
      return;
    }

    print('🌉 [BRIDGE][$requestId] Sirviendo MP4 fusionado (${file.lengthSync()} bytes listos)');
    await request.response.addStream(file.openRead());
    await request.response.close();
  }

  Future<Map<String, String>> _resolveMasterStreams(String url, Map<String, String>? headers) async {
    try {
      String? body;
      String currentUrl = url;
      var res = await _httpClient.get(Uri.parse(url), headers: headers).timeout(const Duration(seconds: 4));
      if (res.statusCode == 200) body = res.body;

      if (body != null && !body.contains('TYPE=AUDIO')) {
        if (currentUrl.contains('-v')) {
           final tryAudio = currentUrl.replaceAll('-v', '-a');
           final resA = await _httpClient.get(Uri.parse(tryAudio), headers: headers).timeout(const Duration(seconds: 2));
           if (resA.statusCode == 200 && resA.body.contains('#EXTM3U')) {
              return {'video': currentUrl, 'audio': tryAudio};
           }
        }
        final tryMaster = currentUrl.replaceAll(RegExp(r'index-.*\.m3u8.*'), 'master.m3u8').replaceAll(RegExp(r'playlist\.m3u8.*'), 'master.m3u8');
        if (tryMaster != currentUrl) {
          final resM = await _httpClient.get(Uri.parse(tryMaster), headers: headers).timeout(const Duration(seconds: 3));
          if (resM.statusCode == 200 && resM.body.contains('TYPE=AUDIO')) {
            body = resM.body;
            currentUrl = tryMaster;
          }
        }
      }

      if (body == null || !body.contains('#EXTM3U')) return {'video': url};
      
      String? audioUrl;
      String? videoUrl;
      final audioMatch = RegExp(r'#EXT-X-MEDIA:TYPE=AUDIO.*?URI="(.*?)"').firstMatch(body);
      if (audioMatch != null) {
        audioUrl = audioMatch.group(1);
        if (audioUrl != null && !audioUrl.startsWith('http')) audioUrl = Uri.parse(currentUrl).resolve(audioUrl).toString();
      }

      if (body.contains('#EXT-X-STREAM-INF')) {
        final lines = body.split('\n');
        for (int i = 0; i < lines.length; i++) {
          if (lines[i].contains('#EXT-X-STREAM-INF')) {
            for (int j = i + 1; j < lines.length; j++) {
              final line = lines[j].trim();
              if (line.isNotEmpty && !line.startsWith('#')) {
                videoUrl = line;
                if (!videoUrl.startsWith('http')) videoUrl = Uri.parse(currentUrl).resolve(videoUrl).toString();
                break;
              }
            }
            if (videoUrl != null) break;
          }
        }
      }

      return {
        'video': _sanitizeUrl(videoUrl ?? url), 
        if (audioUrl != null) 'audio': _sanitizeUrl(audioUrl)
      };
    } catch (e) {
      return {'video': url};
    }
  }

  String _sanitizeUrl(String url) {
    String cleaned = url.replaceAll('%3F', '?');
    if (cleaned.indexOf('?') != cleaned.lastIndexOf('?')) {
      final parts = cleaned.split('?');
      cleaned = '${parts[0]}?${parts[1]}';
    }
    return cleaned;
  }

  String _rewriteM3u8(String body, String baseUriStr, Map<String, String> headers, String requestHost, {String? bid}) {
    final baseUri = Uri.parse(baseUriStr);
    return body.split('\n').map((line) {
      if (line.trim().isEmpty || line.startsWith('#')) {
        if (line.startsWith('#EXT-X-MEDIA:TYPE=AUDIO')) {
          return line.replaceFirstMapped(RegExp(r'URI="(.*?)"'), (m) {
            final uri = m.group(1)!;
            final fullUri = uri.startsWith('http') ? uri : baseUri.resolve(uri).toString();
            final proxied = getProxiedUrl(fullUri, headers, bid: bid);
            return 'URI="$proxied"';
          });
        }
        return line;
      }
      final fullUri = line.trim().startsWith('http') ? line.trim() : baseUri.resolve(line.trim()).toString();
      return getProxiedUrl(fullUri, headers, bid: bid);
    }).join('\n');
  }

  Future<String?> remuxLocalFile(String inputPath, String fileId) async {
    final tempDir = await getTemporaryDirectory();
    final outputPath = '${tempDir.path}/remuxed_$fileId.mp4';
    if (File(outputPath).existsSync()) return outputPath;

    final cmd = '-hide_banner -loglevel error -i "$inputPath" -c copy -f mp4 -movflags +faststart -y "$outputPath"';
    await FFmpegKit.execute(cmd);
    _remuxedFiles[fileId] = outputPath;
    return outputPath;
  }

  void registerLocalFile(String fileId, String filePath) {
    _localFileRegistry[fileId] = filePath;
  }

  Future<double> getFileDuration(String path) async {
    final result = await FFprobeKit.execute('-v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$path"');
    final output = await result.getOutput();
    return double.tryParse(output?.trim() ?? '0') ?? 0;
  }

  Future<double> getHlsDuration(String url, {Map<String, String>? headers}) async {
    final result = await FFprobeKit.execute('-v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$url"');
    final output = await result.getOutput();
    return double.tryParse(output?.trim() ?? '0') ?? 0;
  }
}
