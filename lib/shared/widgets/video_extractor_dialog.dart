
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:http/http.dart' as http;
import 'package:movie_app/features/movies/domain/entities/movie.dart';
import 'package:movie_app/features/player/data/datasources/video_service.dart';

class VideoExtractionData {
  final String videoUrl;
  final List<VideoQuality> qualities;
  final String? cookies;
  final String? userAgent;
  final Map<String, String>? headers;

  VideoExtractionData({
    required this.videoUrl, 
    this.qualities = const [],
    this.cookies,
    this.userAgent,
    this.headers,
  });
}

class VideoExtractorDialog extends StatefulWidget {
  final String url;
  const VideoExtractorDialog({super.key, required this.url});

  @override
  State<VideoExtractorDialog> createState() => _VideoExtractorDialogState();
}

class _VideoExtractorDialogState extends State<VideoExtractorDialog> {
  InAppWebViewController? _webViewController;
  String? _statusText = "Localizando video...";
  final List<String> _detectedUrls = [];
  bool _showWebView = true; // Always show to some degree for transparency
  int _timerCount = 0;
  bool _isDisposed = false;
  final List<VideoExtractionData> _foundMedia = [];

  final List<ContentBlocker> _contentBlockers = [
    ContentBlocker(
      trigger: ContentBlockerTrigger(urlFilter: ".*", resourceType: [
        ContentBlockerTriggerResourceType.IMAGE,
        ContentBlockerTriggerResourceType.STYLE_SHEET,
        ContentBlockerTriggerResourceType.FONT,
      ]),
      action: ContentBlockerAction(type: ContentBlockerActionType.BLOCK),
    ),
    ContentBlocker(
      trigger: ContentBlockerTrigger(urlFilter: ".*(google-analytics|doubleclick|popads|adnium|popcash).*"),
      action: ContentBlockerAction(type: ContentBlockerActionType.BLOCK),
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF0F0F0F),
      insetPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 20),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      content: SizedBox(
        width: double.maxFinite,
        height: 500,
        child: Column(
          children: [
            // Status Header
            Row(
              children: [
                const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF00A3FF)),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    _statusText ?? "Localizando...",
                    style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold),
                  ),
                ),
                Text(
                  "${_foundMedia.length} detectados",
                  style: const TextStyle(color: Color(0xFF00A3FF), fontSize: 12),
                ),
              ],
            ),
            const SizedBox(height: 16),
            
            // WebView Container (Responsive)
            Container(
              height: 150,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.white10),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(11),
                child: InAppWebView(
                  initialUrlRequest: URLRequest(url: WebUri(widget.url)),
                  initialSettings: InAppWebViewSettings(
                    javaScriptEnabled: true,
                    domStorageEnabled: true,
                    mediaPlaybackRequiresUserGesture: false,
                    useShouldInterceptRequest: true,
                    contentBlockers: _contentBlockers,
                    userAgent: "Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/116.0.0.0 Mobile Safari/537.36",
                  ),
                  onWebViewCreated: (controller) => _webViewController = controller,
                  onLoadResource: (controller, resource) {
                    final url = resource.url.toString();
                    if (_isVideoUrl(url)) _handleFoundVideo(url);
                  },
                  shouldInterceptRequest: (controller, request) async {
                    final url = request.url.toString();
                    if (_isVideoUrl(url)) _handleFoundVideo(url, customHeaders: request.headers);
                    return null;
                  },
                  onLoadStop: (controller, url) async {
                     _startSniffingTimer();
                  },
                ),
              ),
            ),
            
            const SizedBox(height: 16),
            const Align(
              alignment: Alignment.centerLeft,
              child: Text("ENLACES ENCONTRADOS (Lógica 1DM):", 
                style: TextStyle(color: Colors.white54, fontSize: 10, letterSpacing: 1.2)),
            ),
            const SizedBox(height: 8),
            
            // Results List
            Expanded(
              child: _foundMedia.isEmpty 
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const CircularProgressIndicator(strokeWidth: 2, color: Colors.white10),
                        const SizedBox(height: 16),
                        const Text("Navega o dale PLAY al video...", 
                          style: TextStyle(color: Colors.white24, fontSize: 13)),
                        const SizedBox(height: 4),
                        const Text("Capturando enlaces de red...", 
                          style: TextStyle(color: Colors.white10, fontSize: 10)),
                      ],
                    ),
                  )
                : ListView.builder(
                    itemCount: _foundMedia.length,
                    itemBuilder: (context, index) {
                      final item = _foundMedia[index];
                      final isHls = item.videoUrl.contains('.m3u8');
                      return Container(
                        margin: const EdgeInsets.only(bottom: 10),
                        decoration: BoxDecoration(
                          color: const Color(0xFF1A1A1A),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: Colors.white.withOpacity(0.05)),
                        ),
                        child: ListTile(
                          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                          leading: Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: isHls ? Colors.orange.withOpacity(0.1) : Colors.blue.withOpacity(0.1),
                              shape: BoxShape.circle,
                            ),
                            child: Icon(
                              isHls ? Icons.waves_rounded : Icons.play_circle_filled_rounded, 
                              color: isHls ? Colors.orange : const Color(0xFF00A3FF),
                              size: 20
                            ),
                          ),
                          title: Text(
                             item.qualities.isNotEmpty ? item.qualities.first.resolution : "Video Detectado",
                             style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold),
                          ),
                          subtitle: Text(
                            item.videoUrl.split('?').first,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: Colors.white38, fontSize: 10),
                          ),
                          trailing: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              if (item.qualities.first.resolution.contains('MB') || item.qualities.first.resolution.contains('GB'))
                                const Icon(Icons.stars_rounded, color: Colors.amber, size: 20),
                              const Icon(Icons.download_for_offline_rounded, color: Color(0xFFD400FF), size: 24),
                            ],
                          ),
                          onTap: () => Navigator.pop(context, item),
                        ),
                      );
                    },
                  ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text("CERRAR", style: TextStyle(color: Colors.white54)),
        ),
      ],
    );
  }

  bool _isVideoUrl(String url) {
    final lower = url.toLowerCase();
    
    // Media Extensions (Prioritize these)
    if (lower.contains(".m3u8") || 
        lower.contains(".mp4") || 
        lower.contains(".mpd") || 
        lower.contains(".mkv") || 
        lower.contains(".webm") ||
        lower.contains("/master.") || 
        lower.contains("/playlist.") ||
        lower.contains("googlevideo.com/videoplayback")) return true;

    // Ad/Analytics block (Less restrictive regex)
    if (lower.contains('googleads') || 
        lower.contains('analytics') || 
        lower.contains('telemetry') ||
        lower.contains('doubleclick') ||
        lower.contains('taboola')) return false;

    // Common Video paths
    if (lower.contains("/video/") || 
        lower.contains("/embed/") ||
        lower.contains("delivery")) return true;

    return false;
  }

  @override
  void dispose() {
    _isDisposed = true;
    super.dispose();
  }

  void _handleFoundVideo(String url, {Map<String, String>? customHeaders}) async {
    // Avoid processing duplicates
    if (_detectedUrls.contains(url)) return;
    _detectedUrls.add(url);
    
    print("[SNIFFER] Analizando flujos para: ${url.substring(0, url.length > 50 ? 50 : url.length)}...");
    setState(() => _statusText = "Interceptada petición multimedia...");

    // 1. Capture Cookies & Headers (Like 1DM)
    String? cookieString;
    try {
      final cookieManager = CookieManager.instance();
      final pageCookies = await cookieManager.getCookies(url: WebUri(widget.url));
      final mediaCookies = await cookieManager.getCookies(url: WebUri(url));
      final all = [...pageCookies, ...mediaCookies];
      cookieString = all.map((c) => '${c.name}=${c.value}').join('; ');
      
      if (customHeaders != null) {
        final lowerHeaders = customHeaders.map((k, v) => MapEntry(k.toLowerCase(), v));
        if (lowerHeaders.containsKey('cookie')) {
          cookieString = lowerHeaders['cookie'];
        }
      }
    } catch (e) {
      print("[SNIFFER] Error capturando cookies: $e");
    }

    final String ua = customHeaders?['user-agent'] ?? customHeaders?['User-Agent'] ?? "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36";

    final headersForProbe = <String, String>{};
    if (customHeaders != null) {
      for (final entry in customHeaders.entries) {
        headersForProbe[entry.key] = entry.value;
      }
    }
    if (cookieString != null) headersForProbe['Cookie'] = cookieString;
    headersForProbe['User-Agent'] = ua;
    headersForProbe['Referer'] = widget.url;
    headersForProbe['Origin'] = widget.url.split('/').take(3).join('/');

    // 2. Identify qualities & Explode (Like 1DM)
    try {
      if (url.contains(".m3u8")) {
        print("[SNIFFER] Desglosando lista HLS para encontrar todas las calidades...");
        
        // Add the main HLS as a separate entry first (Auto/Fallback)
        final mainSize = await _probeFileSize(url, headersForProbe);
        _addFoundMedia(
          url: url,
          resolution: "Resolución Auto (HLS)",
          size: mainSize,
          headers: headersForProbe,
          cookies: cookieString,
        );

        final explodedQualities = await VideoService.getHlsQualities(url, headers: headersForProbe);
        
        // Add each quality found as a separate media entry
        for (var q in explodedQualities) {
           final size = await _probeFileSize(q.url, headersForProbe);
           _addFoundMedia(
             url: q.url,
             resolution: "Streaming ${q.resolution}",
             size: size,
             headers: headersForProbe,
             cookies: cookieString,
           );
        }

        // Try direct MP4 if available
        final mp4Fallback = await _tryFindMp4InDialog(url);
        if (mp4Fallback != null) {
          final size = await _probeFileSize(mp4Fallback, headersForProbe);
          _addFoundMedia(
            url: mp4Fallback,
            resolution: "Descarga Directa (MP4)",
            size: size,
            headers: headersForProbe,
            cookies: cookieString,
          );
        }
      } else {
        final size = await _probeFileSize(url, headersForProbe);
        _addFoundMedia(
          url: url,
          resolution: "Original (MP4)",
          size: size,
          headers: headersForProbe,
          cookies: cookieString,
        );
      }
    } catch (e) {
      print("[SNIFFER] Error analizando calidades: $e");
    }
  }

  void _addFoundMedia({
    required String url,
    required String resolution,
    String? size,
    required Map<String, String> headers,
    String? cookies,
  }) {
    if (_isDisposed || !mounted) return;
    
    // Skip tiny files (likely error pages or empty HLS manifests)
    if (size != null && size.contains('KB') && !size.contains('Streaming')) {
       final kb = double.tryParse(size.split(' ').first) ?? 0;
       if (kb < 100) return; // Discard anything < 100KB
    }

    setState(() {
      _foundMedia.add(VideoExtractionData(
        videoUrl: url,
        qualities: [VideoQuality(resolution: size != null ? "$resolution ($size)" : resolution, url: url)],
        cookies: cookies,
        userAgent: headers['user-agent'] ?? headers['User-Agent'],
        headers: headers,
      ));
      _statusText = "¡Nuevo medio detectado!";
    });
  }

  Future<String?> _tryFindMp4InDialog(String hlsUrl) async {
    final String baseUrl = hlsUrl.split('?').first;
    final String query = hlsUrl.contains('?') ? '?${hlsUrl.split('?').last}' : '';
    
    // Probing variations (Common patterns in PeliculaPlay, Akamai, and pirate CDNs)
    final variations = [
      baseUrl.replaceAll(RegExp(r'-microframe-(ld|sd|hd)\.m3u8$'), '.mp4'),
      baseUrl.replaceAll(RegExp(r'\.m3u8$'), '.mp4'),
      baseUrl.replaceAll(RegExp(r'/playlist\.m3u8$'), '/video.mp4'),
      baseUrl.replaceFirst('/hls/', '/').replaceAll('.m3u8', '.mp4'),
      baseUrl.replaceAll('.m3u8', '-video.mp4'),
    ];

    for (var p in variations) {
      if (p == baseUrl) continue;
      final fullUrl = p + query;
      // Probe with Referer to get valid response
      if (await _probeUrl(fullUrl, customReferer: widget.url)) return fullUrl;
    }
    return null;
  }

  Future<String?> _probeFileSize(String url, Map<String, String> headers) async {
    try {
      final response = await http.head(Uri.parse(url), headers: headers).timeout(const Duration(seconds: 4));
      
      if (response.statusCode == 200) {
        final cl = response.headers['content-length'];
        final ct = response.headers['content-type']?.toLowerCase();
        
        if (ct != null && (ct.contains('mpegurl') || ct.contains('apple.mpegurl'))) return "Streaming (HLS)";

        if (cl != null) {
          final bytes = int.tryParse(cl) ?? 0;
          if (bytes <= 0) return null;
          
          if (bytes < 40960) return "Streaming (HLS)"; 

          if (bytes < 1024 * 1024) return "${(bytes / 1024).toStringAsFixed(1)} KB";
          if (bytes < 1024 * 1024 * 1024) return "${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB";
          return "${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB";
        }
      }
    } catch (_) {}
    return null;
  }

  Future<bool> _probeUrl(String url, {String? customReferer}) async {
    try {
      final response = await http.head(Uri.parse(url), headers: {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36',
        if (customReferer != null) 'Referer': customReferer,
      }).timeout(const Duration(seconds: 3));
      
      if (response.statusCode == 200) {
        final cl = response.headers['content-length'];
        if (cl != null) {
          final size = int.tryParse(cl) ?? 0;
          return size > 20 * 1024 * 1024; // Must be > 20MB for a movie
        }
        return true; 
      }
    } catch (_) {}
    return false;
  }

  void _startSniffingTimer() async {
    if (_isDisposed || !mounted) return;
    
    // JS Injection check (ES5 compatible + safer regex)
    const js = '''
      (function() {
        var results = [];
        try {
          // 1. Check all video/source tags
          var tags = document.querySelectorAll('video, source');
          for(var i=0; i<tags.length; i++) {
            var s = tags[i].src || tags[i].getAttribute('data-src');
            if(s && s.indexOf('http') === 0) results.push(s);
          }
          
          // 2. Player-specific detection
          // JWPlayer
          if (window.jwplayer && typeof window.jwplayer === 'function') {
            try {
              var playlist = window.jwplayer().getPlaylist();
              if (playlist && playlist[0] && playlist[0].sources) {
                var sources = playlist[0].sources;
                for(var j=0; j<sources.length; j++) {
                  if(sources[j].file) results.push(sources[j].file);
                }
              }
            } catch(e){}
          }
          // VideoJS
          if (window.videojs && window.videojs.players) {
            var players = window.videojs.players;
            for (var p in players) {
              var src = players[p].currentSrc();
              if (src) results.push(src);
            }
          }
          // 3. Script-based discovery (Safer regex construction)
          var scripts = document.getElementsByTagName('script');
          var pattern = "https?:\\\\/\\\\/[^\\\"'\\\\s]+\\\\.mp4[^\\\"'\\\\s]*";
          var re = new RegExp(pattern, 'g');
          for (var i=0; i<scripts.length; i++) {
            var code = scripts[i].innerHTML;
            if (code) {
              var matchMp4 = code.match(re);
              if (matchMp4) {
                 for(var k=0; k<matchMp4.length; k++) results.push(matchMp4[k]);
              }
            }
          }
        } catch(e){}
        
        return results.join('|||');
      })();
    ''';
    
    try {
      if (_webViewController != null && !_isDisposed) {
        final result = await _webViewController?.evaluateJavascript(source: js);
        if (result != null && result is String && result.isNotEmpty && !_isDisposed) {
          final urls = result.split('|||');
          for (var u in urls) {
             if (u != "null" && u.length > 5) _handleFoundVideo(u);
          }
        }
      }
    } catch (e) {}

    _timerCount++;
    
    if (!_isDisposed && mounted) {
      await Future.delayed(const Duration(seconds: 2));
      _startSniffingTimer();
    }
  }
}
