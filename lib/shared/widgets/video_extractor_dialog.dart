
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
  final int extractionAlgorithm;
  const VideoExtractorDialog({super.key, required this.url, this.extractionAlgorithm = 1});

  @override
  State<VideoExtractorDialog> createState() => _VideoExtractorDialogState();
}

class _VideoExtractorDialogState extends State<VideoExtractorDialog> with SingleTickerProviderStateMixin {
  late AnimationController _borderController;
  InAppWebViewController? _webViewController;
  String? _statusText = "Localizando video...";
  final List<String> _detectedUrls = [];
  bool _showWebView = false; 
  int _timerCount = 0;
  bool _isDisposed = false;
  final List<VideoExtractionData> _foundMedia = [];
  bool _snifferInjected = false;
  static const _webviewTouchChannel = MethodChannel('com.luis.movieapp/webview_touch');
  final GlobalKey _webViewKey = GlobalKey();

  final List<ContentBlocker> _contentBlockers = [
    ContentBlocker(
      trigger: ContentBlockerTrigger(urlFilter: ".*"),
      action: ContentBlockerAction(
        type: ContentBlockerActionType.CSS_DISPLAY_NONE, 
        selector: ".ad, .ads, .advertisement, [id^='ad-'], [class^='ad-'], .popup, .overlay"
      ),
    ),
    ContentBlocker(
      trigger: ContentBlockerTrigger(urlFilter: ".*(google-analytics|doubleclick|popads|adnium|popcash|exoclick|juicyads|propellerads|clonamp).*"),
      action: ContentBlockerAction(type: ContentBlockerActionType.BLOCK),
    ),
  ];

  @override
  void initState() {
    super.initState();
    _showWebView = false; // Always hidden by default as requested
    _borderController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 4),
    )..repeat();
  }

  @override
  void dispose() {
    _isDisposed = true;
    _borderController.dispose();
    super.dispose();
  }

  final String _cleanerJs = '''
    (function() {
      const selectors = ['.overlay', '.popup', '.popup-container', '#popads', '.modal-backdrop', 'div[class*="ad-"]', 'div[id*="ad-"]'];
      selectors.forEach(s => {
        document.querySelectorAll(s).forEach(el => el.remove());
      });
      // Facilitate interaction if something is blocked
      document.body.style.overflow = 'auto';
      window.open = function() { return null; };
    })();
  ''';

  @override
  Widget build(BuildContext context) {
    final filteredMedia = _foundMedia.where((m) {
      final url = m.videoUrl.toLowerCase();
      
      // BLOCK problematic direct extensions as explicitly requested for downloads
      bool isProblematic = url.contains('.mp4') || url.contains('.mkv');
      
      // If we're using Algorithm 2, we should be EXTRA strict about hiding direct links
      // as they are likely ads or non-HLS streams that won't work in the background.
      if (widget.extractionAlgorithm == 2 && !url.contains('.m3u8')) {
        isProblematic = true;
      }

      // Always allow adaptive streaming (HLS/MPD) regardless of other checks
      if (url.contains('.m3u8') || url.contains('.mpd')) return true;

      return !isProblematic;
    }).toList();

    return AnimatedBuilder(
      animation: _borderController,
      builder: (context, child) {
        return AlertDialog(
          backgroundColor: const Color(0xFF0F0F0F),
          insetPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 20),
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          contentPadding: EdgeInsets.zero,
          content: Container(
            width: double.maxFinite,
            height: 520,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: Colors.transparent, width: 2),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(20),
              child: Stack(
                children: [
                // Animated Iridescent Border Effect (Energy Flowing)
                Positioned.fill(
                  child: Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(20),
                      gradient: SweepGradient(
                        center: Alignment.center,
                        transform: GradientRotation(_borderController.value * 2 * 3.14159),
                        colors: const [
                          Color(0xFF00A3FF),
                          Color(0xFFD400FF),
                          Color(0xFF00FFD1),
                          Color(0xFF4A90FF),
                          Color(0xFFBC00FF),
                          Color(0xFF00FFD1),
                          Color(0xFF00A3FF),
                        ],
                      ),
                    ),
                  ),
                ),
                // Inner content background to hide the center of the gradient
                Positioned.fill(
                  child: Container(
                    margin: const EdgeInsets.all(2), // Matches border width
                    decoration: BoxDecoration(
                      color: const Color(0xFF0F0F0F),
                      borderRadius: BorderRadius.circular(18),
                    ),
                  ),
                ),
            // Background WebView for Algorithm 2 (Full size but hidden if requested)
            // We use OverflowBox to allow it to be larger than the dialog
            Positioned.fill(
              child: OverflowBox(
                minWidth: 0,
                maxWidth: double.infinity,
                minHeight: 0,
                maxHeight: double.infinity,
                alignment: Alignment.center,
                child: SizedBox(
                  // Use screen size if Alg 2 to match player exactly
                  width: widget.extractionAlgorithm == 2 ? MediaQuery.of(context).size.width : 500,
                  height: widget.extractionAlgorithm == 2 ? MediaQuery.of(context).size.height : 280,
                  child: Opacity(
                    opacity: _showWebView ? 1.0 : 0.01,
                    child: IgnorePointer(
                      ignoring: !_showWebView, // When hidden, don't block dialog touches
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: InAppWebView(
                          key: _webViewKey,
                          initialUrlRequest: URLRequest(url: WebUri(widget.url)),
                          initialSettings: InAppWebViewSettings(
                            javaScriptEnabled: true,
                            domStorageEnabled: true,
                            mediaPlaybackRequiresUserGesture: false,
                            useShouldInterceptRequest: true,
                            contentBlockers: _contentBlockers,
                            javaScriptCanOpenWindowsAutomatically: false,
                            supportMultipleWindows: false,
                            useShouldOverrideUrlLoading: true,
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
                            _injectNetworkSniffer();
                            controller.evaluateJavascript(source: _cleanerJs);

                            if (widget.extractionAlgorithm == 2) {
                              await Future.delayed(const Duration(milliseconds: 1500));
                              if (!_isDisposed) {
                                _runAlgorithm2();
                              }
                            }
                          },
                          shouldOverrideUrlLoading: (controller, navigationAction) async {
                            var uri = navigationAction.request.url;
                            if (uri != null) {
                              final initialHost = Uri.parse(widget.url).host;
                              if (uri.host != initialHost && !uri.host.contains('google') && !uri.host.contains('facebook')) {
                                return NavigationActionPolicy.CANCEL;
                              }
                            }
                            return NavigationActionPolicy.ALLOW;
                          },
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),

            // Opaque Background Layer to hide the process and the app behind
            // Only active when the WebView is hidden to allow manual browser interaction
            if (!_showWebView)
              Positioned.fill(
                child: Container(
                  decoration: BoxDecoration(
                    color: const Color(0xFF0F0F0F),
                    borderRadius: BorderRadius.circular(18),
                  ),
                ),
              ),

            // Visible UI Layer
            Column(
              children: [
                // K7 Branding & Status
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [const Color(0xFF00A3FF).withOpacity(0.1), const Color(0xFFD400FF).withOpacity(0.1)],
                    ),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: Colors.white.withOpacity(0.05)),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min, // Avoid overflow
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Container(
                            padding: const EdgeInsets.all(6),
                            decoration: BoxDecoration(
                              gradient: const LinearGradient(colors: [Color(0xFF4A90FF), Color(0xFFBC00FF)]),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: const Text('K7', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: Colors.white)),
                          ),
                          const SizedBox(width: 10),
                          const Text('EXTRACTOR INTELIGENTE', style: TextStyle(letterSpacing: 2, fontWeight: FontWeight.bold, fontSize: 13, color: Colors.white)),
                        ],
                      ),
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2.5, color: Color(0xFF00A3FF)),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              _statusText ?? "Localizando...",
                              style: const TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.w500),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
            
                // Results List / Status
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.orange.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.orange.withOpacity(0.3)),
                  ),
                  child: const Row(
                    children: [
                       Icon(Icons.info_outline, color: Colors.orange, size: 16),
                       SizedBox(width: 8),
                       Expanded(
                         child: Text(
                           "Selecciona un enlace HLS para descargar sin errores.",
                           style: TextStyle(color: Colors.orange, fontSize: 11, fontWeight: FontWeight.bold),
                         ),
                       ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),

                // Toggle visibility in Alg 1 (In Alg 2 it's better to keep it hidden/fixed)
                if (widget.extractionAlgorithm != 2)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: TextButton.icon(
                      onPressed: () => setState(() => _showWebView = !_showWebView),
                      icon: Icon(_showWebView ? Icons.visibility_off_rounded : Icons.visibility_rounded, size: 16, color: Colors.white38),
                      label: Text(_showWebView ? "OCULTAR NAVEGADOR" : "MOSTRAR NAVEGADOR", style: const TextStyle(color: Colors.white38, fontSize: 9, fontWeight: FontWeight.bold)),
                    ),
                  ),

                Expanded(
                  child: filteredMedia.isEmpty
                      ? Center(
                          child: SingleChildScrollView(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Container(
                                  width: 60,
                                  height: 60,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    border: Border.all(color: const Color(0xFF00A3FF).withOpacity(0.1), width: 4),
                                  ),
                                  child: const Center(
                                    child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF00A3FF)),
                                  ),
                                ),
                                const SizedBox(height: 20),
                                const Text("Analizando protocolos de red...",
                                    style: TextStyle(color: Colors.white38, fontSize: 12, fontWeight: FontWeight.w500)),
                                const SizedBox(height: 4),
                                const Text("Esto puede tardar unos segundos", style: TextStyle(color: Colors.white12, fontSize: 10)),
                              ],
                            ),
                          ),
                        )
                      : ListView.builder(
                                padding: EdgeInsets.zero,
                                itemCount: filteredMedia.length,
                                itemBuilder: (context, index) {
                                  final item = filteredMedia[index];
                                  final isHls = item.videoUrl.contains('.m3u8');
                                  return Container(
                                    margin: const EdgeInsets.only(bottom: 12),
                                    child: Stack(
                                      children: [
                                        // Animated Iridescent Border (Card Energy Flow)
                                        Positioned.fill(
                                          child: Container(
                                            decoration: BoxDecoration(
                                              borderRadius: BorderRadius.circular(16),
                                              gradient: LinearGradient(
                                                begin: Alignment.topLeft,
                                                end: Alignment.bottomRight,
                                                transform: GradientRotation(_borderController.value * 2 * 3.14159),
                                                colors: const [
                                                  Color(0xFF00A3FF),
                                                  Color(0xFFD400FF),
                                                  Color(0xFF00FFD1),
                                                  Color(0xFF4A90FF),
                                                  Color(0xFFBC00FF),
                                                  Color(0xFF00A3FF),
                                                ],
                                              ),
                                            ),
                                          ),
                                        ),
                                        // Card Inner Content
                                        Container(
                                          margin: const EdgeInsets.all(1.5),
                                          decoration: BoxDecoration(
                                            color: const Color(0xFF161616),
                                            borderRadius: BorderRadius.circular(15),
                                          ),
                                          child: ListTile(
                                            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                                            leading: Container(
                                              padding: const EdgeInsets.all(10),
                                              decoration: BoxDecoration(
                                                gradient: LinearGradient(
                                                  colors: isHls
                                                      ? [Colors.orange.withOpacity(0.2), Colors.deepOrange.withOpacity(0.2)]
                                                      : [const Color(0xFF00A3FF).withOpacity(0.2), const Color(0xFFD400FF).withOpacity(0.2)],
                                                ),
                                                shape: BoxShape.circle,
                                              ),
                                              child: Icon(isHls ? Icons.waves_rounded : Icons.play_arrow_rounded, color: isHls ? Colors.orange : const Color(0xFF00A3FF), size: 24),
                                            ),
                                            title: Text(
                                              item.qualities.isNotEmpty ? item.qualities.first.resolution : "Multimedia Detectada",
                                              style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold),
                                            ),
                                            subtitle: Text(
                                              isHls ? "Streaming Adaptativo (HLS)" : "Archivo Directo (MP4/MKV)",
                                              style: TextStyle(color: isHls ? Colors.orange.withOpacity(0.6) : const Color(0xFF00A3FF).withOpacity(0.6), fontSize: 11),
                                            ),
                                            trailing: const Icon(Icons.arrow_forward_ios_rounded, color: Colors.white12, size: 14),
                                            onTap: () => Navigator.pop(context, item),
                                          ),
                                        ),
                                      ],
                                    ),
                                  );
                                },
                              ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text("CANCELAR", style: TextStyle(color: Colors.white38, fontSize: 12, fontWeight: FontWeight.bold)),
            ),
          ],
        );
      },
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

        final masterUrl = await _resolveHlsMasterUrl(url, headersForProbe);
        final targetUrl = masterUrl ?? url;
        if (masterUrl != null && masterUrl != url) {
          print("[SNIFFER] Master HLS detectado: $masterUrl");
        }
        final explodedQualities = await VideoService.getHlsQualities(targetUrl, headers: headersForProbe);
        
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

  Future<void> _injectNetworkSniffer() async {
    if (_snifferInjected || _webViewController == null || _isDisposed) return;
    _snifferInjected = true;

    _webViewController?.addJavaScriptHandler(
      handlerName: 'snifferManifest',
      callback: (args) async {
        if (args.isEmpty) return;
        final payload = args.first;
        if (payload is Map) {
          final url = payload['url']?.toString() ?? '';
          final body = payload['body']?.toString() ?? '';
          if (url.isNotEmpty && body.isNotEmpty) {
            await _handleManifestText(url, body);
          }
        }
      },
    );

    _webViewController?.addJavaScriptHandler(
      handlerName: 'snifferUrl',
      callback: (args) async {
        if (args.isEmpty) return;
        final url = args.first?.toString() ?? '';
        if (url.isNotEmpty && _isVideoUrl(url)) {
          _handleFoundVideo(url);
        }
      },
    );

    const js = '''
      (function() {
        if (window.__snifferHooked) return;
        window.__snifferHooked = true;

        function shouldCapture(url) {
          if (!url) return false;
          var u = url.toLowerCase();
          return u.indexOf('.m3u8') !== -1 || u.indexOf('.mpd') !== -1;
        }

        var origFetch = window.fetch;
        if (origFetch) {
          window.fetch = function() {
            return origFetch.apply(this, arguments).then(function(resp) {
              try {
                var url = resp.url || (arguments[0] && arguments[0].url) || arguments[0];
                if (shouldCapture(url)) {
                  resp.clone().text().then(function(txt) {
                    try {
                      window.flutter_inappwebview.callHandler('snifferManifest', {url: url, body: txt});
                    } catch(e){}
                  });
                  window.flutter_inappwebview.callHandler('snifferUrl', url);
                }
              } catch(e){}
              return resp;
            });
          };
        }

        var origOpen = XMLHttpRequest.prototype.open;
        var origSend = XMLHttpRequest.prototype.send;
        XMLHttpRequest.prototype.open = function(method, url) {
          this.__snifferUrl = url;
          return origOpen.apply(this, arguments);
        };
        XMLHttpRequest.prototype.send = function() {
          this.addEventListener('load', function() {
            try {
              var url = this.__snifferUrl || '';
              if (shouldCapture(url)) {
                var txt = this.responseText;
                try {
                  window.flutter_inappwebview.callHandler('snifferManifest', {url: url, body: txt});
                } catch(e){}
                window.flutter_inappwebview.callHandler('snifferUrl', url);
              }
            } catch(e){}
          });
          return origSend.apply(this, arguments);
        };
      })();
    ''';

    try {
      await _webViewController?.evaluateJavascript(source: js);
    } catch (_) {}
  }

  Future<void> _handleManifestText(String url, String body) async {
    if (_isDisposed || !mounted) return;
    if (!body.contains('#EXTM3U') && !body.contains('#EXT-X-STREAM-INF')) return;

    final headers = <String, String>{'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36'};
    final qualities = <VideoQuality>[];
    try {
      final lines = body.split('\\n');
      String? currentRes;
      for (int i = 0; i < lines.length; i++) {
        final line = lines[i].trim();
        if (line.startsWith('#EXT-X-STREAM-INF')) {
          final resMatch = RegExp(r'RESOLUTION=(\\d+x\\d+)').firstMatch(line);
          if (resMatch != null) {
            currentRes = _formatResolution(resMatch.group(1) ?? '');
          }
        } else if (line.isNotEmpty && !line.startsWith('#') && currentRes != null) {
          final qUrl = _resolveUrl(url, line);
          qualities.add(VideoQuality(resolution: currentRes, url: qUrl));
          currentRes = null;
        }
      }
    } catch (_) {}

    if (qualities.isEmpty) return;
    for (final q in qualities) {
      _addFoundMedia(
        url: q.url,
        resolution: "Streaming ${q.resolution}",
        size: null,
        headers: headers,
        cookies: null,
      );
    }
  }

  String _formatResolution(String res) {
    if (res.contains('x')) {
      final height = res.split('x').last;
      return '${height}p';
    }
    return res;
  }

  String _resolveUrl(String base, String ref) {
    try {
      final baseUri = Uri.parse(base);
      final refUri = Uri.parse(ref);
      if (refUri.hasScheme) return ref;
      return baseUri.resolveUri(refUri).toString();
    } catch (_) {
      return ref;
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
      if (_foundMedia.any((m) => m.videoUrl == url)) return;
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

  Future<String?> _resolveHlsMasterUrl(String mediaUrl, Map<String, String> headers) async {
    try {
      final mediaText = await _fetchText(mediaUrl, headers);
      if (mediaText != null && mediaText.contains('#EXT-X-STREAM-INF')) {
        return mediaUrl;
      }
    } catch (_) {}

    final uri = Uri.parse(mediaUrl);
    final baseUrl = mediaUrl.split('?').first;
    final query = uri.hasQuery ? '?${uri.query}' : '';

    final candidates = <String>{
      _replaceQualitySuffix(baseUrl) + query,
      _replaceQualitySuffix(baseUrl).replaceAll('.m3u8', '/master.m3u8') + query,
      _replaceQualitySuffix(baseUrl).replaceAll('.m3u8', '/index.m3u8') + query,
      _replaceQualitySuffix(baseUrl).replaceAll('.m3u8', '/playlist.m3u8') + query,
      '${uri.scheme}://${uri.host}${uri.pathSegments.take(uri.pathSegments.length - 1).join('/')}/master.m3u8$query',
      '${uri.scheme}://${uri.host}${uri.pathSegments.take(uri.pathSegments.length - 1).join('/')}/index.m3u8$query',
      '${uri.scheme}://${uri.host}${uri.pathSegments.take(uri.pathSegments.length - 1).join('/')}/playlist.m3u8$query',
    };

    for (final c in candidates) {
      if (c.isEmpty || !c.contains('.m3u8')) continue;
      try {
        final text = await _fetchText(c, headers);
        if (text != null && text.contains('#EXT-X-STREAM-INF')) {
          return c;
        }
      } catch (_) {}
    }
    return null;
  }

  String _replaceQualitySuffix(String url) {
    return url.replaceAll(RegExp(r'(-microframe-(ld|sd|hd)|-(ld|sd|hd)|_(ld|sd|hd)|-\\d+p)\\.m3u8$', caseSensitive: false), '.m3u8');
  }

  Future<String?> _fetchText(String url, Map<String, String> headers) async {
    try {
      final res = await http.get(Uri.parse(url), headers: headers).timeout(const Duration(seconds: 4));
      if (res.statusCode == 200) return res.body;
    } catch (_) {}
    return null;
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

  Future<void> _runAlgorithm2() async {
    if (_isDisposed || !mounted) return;
    try {
      final dpr = MediaQuery.of(context).devicePixelRatio;
      final box = _webViewKey.currentContext?.findRenderObject() as RenderBox?;
      if (box != null) {
        final offset = box.localToGlobal(Offset.zero);
        final w = box.size.width;
        final h = box.size.height;

        print("[SNIFFER] Ejecutando Algoritmo 2 de Clics para descarga...");

        // Secuencia de 4 clicks en cruz/centro para asegurar que se quiten Ads y se active el video
        final points = [
          Offset(w / 2, h / 2),
          Offset(w / 2 + 20, h / 2),
          Offset(w / 2, h / 2 + 20),
          Offset(w / 2, h / 2)
        ];

        for (var p in points) {
          if (_isDisposed) break;
          await _webviewTouchChannel.invokeMethod('tapAt', {
            'x': (offset.dx + p.dx) * dpr,
            'y': (offset.dy + p.dy) * dpr
          });
          await Future.delayed(const Duration(milliseconds: 500));
        }

        // Click again after a short wait to ensure play trigger
        await Future.delayed(const Duration(milliseconds: 800));
        if (!_isDisposed) {
          await _webviewTouchChannel.invokeMethod('tapAt', {
            'x': (offset.dx + w/2) * dpr,
            'y': (offset.dy + h/2) * dpr
          });
        }
      }
    } catch (e) {
      print("Error Algoritmo 2 Descarga: $e");
    }
  }
}
