import 'dart:async';
import 'dart:collection';
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
  bool _isSpanishSelected = false;
  bool _serverSwitchDone = false; // true once algo 3 has confirmed server switch
  bool _snifferInjected = false;
  Timer? _algo3Timer; // Keeps reference to prevent duplicate timers on page reload
  static const _webviewTouchChannel = MethodChannel('com.luis.movieapp/webview_touch');
  final GlobalKey _webViewKey = GlobalKey();
  Map<String, String>? _lastCapturedHeaders;

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
    _algo3Timer?.cancel();
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
      
      // We allow direct extensions now as requested for better download support
      bool isProblematic = false;
      
      // If we're using Algorithm 2, we should be EXTRA strict about hiding direct links
      // as they are likely ads or non-HLS streams that won't work in the background.
      // BUT allow .txt manifests from known HLS CDN domains
      final isTxtManifest = url.contains('.txt') && 
          (url.contains('goldenfieldproductionworks') || 
           url.contains('/v4/db/') ||
           url.contains('index-f') ||
           url.contains('cf-master'));
      if (widget.extractionAlgorithm == 2 && !url.contains('.m3u8') && !isTxtManifest) {
        isProblematic = true;
      }

      // Filtro de extensiones avanzado para evadir bloqueos
      final isVideo = url.contains('.m3u8') || 
                      url.contains('.mp4') || 
                      url.contains('.mkv') ||
                      url.contains('.webm') ||
                      url.contains('ecotechproducts.shop') ||
                      isTxtManifest ||
                      (url.contains('.txt') && (url.contains('master') || url.contains('playlist')));
      
      if (!isVideo) return false;

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
                  // Use screen size if Alg 2 or 3 to match player exactly
                  width: (widget.extractionAlgorithm == 2 || widget.extractionAlgorithm == 3) ? MediaQuery.of(context).size.width : 500,
                  height: (widget.extractionAlgorithm == 2 || widget.extractionAlgorithm == 3) ? MediaQuery.of(context).size.height : 280,
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
                            isInspectable: true,
                            userAgent: widget.extractionAlgorithm == 1 
                                ? "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
                                : "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/123.0.0.0 Safari/537.36",
                          ),
                          initialUserScripts: UnmodifiableListView<UserScript>([
                            UserScript(
                              source: r'''
                              (function() {
                                console.log('[DEBUG_JS] GHOST_SNIFFER_v4.5_SHADOW_PIERCE');
                                
                                window.onerror = function(msg) {
                                  window.flutter_inappwebview.callHandler('debugLog', 'JS_ERROR: ' + msg);
                                };

                                function notify(url, meta) {
                                  if (!url || typeof url !== 'string' || url.startsWith('blob:') || url.length < 10) return;
                                  // Evitar basura de trackers conocidos
                                  if (url.includes('analytics') || url.includes('doubleclick')) return;
                                  
                                  try {
                                    window.flutter_inappwebview.callHandler('snifferUrl', url, meta || {});
                                  } catch(e) {}
                                }

                                // 1. Hook de Hls.js (El standard de oro)
                                const openHlsHook = () => {
                                  if (window.Hls && !window._hlsHooked) {
                                    const originalLoad = window.Hls.prototype.loadSource;
                                    window.Hls.prototype.loadSource = function(src) {
                                      notify(src, {method: 'HLS_LOAD_SOURCE'});
                                      return originalLoad.apply(this, arguments);
                                    };
                                    window._hlsHooked = true;
                                  }
                                };

                                // 2. Proxy de Setters (Atrapar cuando asignan .src)
                                const proxyMedia = (el) => {
                                  if (el._sniffed) return;
                                  const originalSrc = Object.getOwnPropertyDescriptor(HTMLMediaElement.prototype, 'src');
                                  Object.defineProperty(el, 'src', {
                                    set: function(val) {
                                      notify(val, {context: 'setter'});
                                      return originalSrc.set.apply(this, arguments);
                                    },
                                    get: function() { return originalSrc.get.apply(this); }
                                  });
                                  el._sniffed = true;
                                };

                                // 3. Perforación de Shadow DOM & DOM Scan
                                const deepScan = () => {
                                  const allVideos = [];
                                  const findVideos = (root) => {
                                    if (!root) return;
                                    // Buscar en el root actual
                                    root.querySelectorAll('video, source, iframe, embed').forEach(v => allVideos.push(v));
                                    // Buscar en Shadow Roots
                                    root.querySelectorAll('*').forEach(el => {
                                      if (el.shadowRoot) findVideos(el.shadowRoot);
                                    });
                                  };

                                  findVideos(document);
                                  
                                  allVideos.forEach(el => {
                                    const src = el.src || el.currentSrc || el.getAttribute('data-src');
                                    if (src && src.startsWith('http')) {
                                      notify(src, {tag: el.tagName, shadow: 'pierced'});
                                    }
                                    if (el.tagName === 'VIDEO') proxyMedia(el);
                                  });
                                  
                                  openHlsHook();
                                };

                                // 4. Proxy de Fetch/XHR (Fuerza Bruta)
                                const _fetch = window.fetch;
                                window.fetch = function(...args) {
                                  let url = typeof args[0] === 'string' ? args[0] : (args[0] && args[0].url);
                                  if (url && (url.includes('.m3u8') || url.includes('.mp4'))) notify(url, {type: 'fetch'});
                                  return _fetch.apply(this, args);
                                };

                                // Ciclo de vida
                                setInterval(deepScan, 2000);
                                setInterval(() => window.flutter_inappwebview.callHandler('debugLog', 'HEARTBEAT_ALIVE'), 3000);

                                notify('READY_SIGNAL', {status: 'v4.5_active'});
                              })();
                            ''',
                              injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
                            ),
                          ]),
                          onConsoleMessage: (controller, consoleMessage) {
                            print("[WEBVIEW_CONSOLE] ${consoleMessage.message}");
                          },
                          onWebViewCreated: (controller) {
                            _webViewController = controller;
                            
                            // Debug Handler
                            controller.addJavaScriptHandler(handlerName: 'debugLog', callback: (args) {
                               print("[SNIFFER_DEBUG_JS] ${args.first}");
                            });

            controller.addJavaScriptHandler(
                              handlerName: 'onServerSelected',
                              callback: (args) {
                                if (mounted) {
                                  final serverName = args.isNotEmpty ? args.first.toString() : 'desconocido';
                                  print('[SNIFFER] ✅ Servidor seleccionado: $serverName — limpiando streams del servidor anterior...');
                                  setState(() {
                                    _isSpanishSelected = true;
                                    _serverSwitchDone = true;
                                    // *** Clave: limpiar el stream del servidor default ***
                                    // para que el sniffer capture el stream del nuevo servidor
                                    _foundMedia.clear();
                                    _statusText = "Servidor '$serverName' seleccionado. Extrayendo...";
                                  });
                                }
                              },
                            );

                            controller.addJavaScriptHandler(
                              handlerName: 'snifferUrl',
                              callback: (args) {
                                if (args.isEmpty) return;
                                final String url = args[0].toString();
                                if (url == "READY_SIGNAL") {
                                  print("[DEBUG_SNIFFER] JS Sniper Ready Signal Received");
                                  return;
                                }
                                Map<String, String>? headers;
                                if (args.length > 1 && args[1] is Map) {
                                  headers = Map<String, String>.from(args[1]);
                                }
                                print("[DEBUG_SNIFFER] Captured: $url");
                                if (url.isNotEmpty) _handleFoundVideo(url, customHeaders: headers);
                              },
                            );
                          },
                          onLoadResource: (controller, resource) {
                            final url = resource.url.toString();
                            if (_isVideoUrl(url)) _handleFoundVideo(url);
                          },
                          shouldInterceptRequest: (controller, request) async {
                            final url = request.url.toString();
                            final lower = url.toLowerCase();
                            
                            // Si es un fragmento de video, capturamos sus cabeceras pero no bloqueamos la petición
                            // para que el reproductor web siga funcionando y validando el anuncio.
                            if (lower.contains('.ts') || lower.contains('.m4s') || lower.contains('.mp4/')) {
                               _handleFoundVideo(url, customHeaders: request.headers);
                               return null; 
                            }

                            if (_isVideoUrl(url)) _handleFoundVideo(url, customHeaders: request.headers);
                            return null;
                          },
                           onProgressChanged: (controller, progress) {
                             // _injectNetworkSniffer eliminado por redundancia con initialUserScripts
                           },
                          onLoadStart: (controller, url) {
                            print("[WEBVIEW] Iniciando carga: $url");
                            // Inyección redundante para asegurar presencia
                            controller.evaluateJavascript(source: r'''(function(){ console.log('SNIFFER_RE-INJECT'); })();''');
                          },
                          onLoadStop: (controller, url) async {
                              print("[WEBVIEW] Carga finalizada: $url");
                              controller.evaluateJavascript(source: _cleanerJs);

                            if (widget.extractionAlgorithm == 2) {
                              await Future.delayed(const Duration(milliseconds: 1500));
                              if (!_isDisposed) {
                                _runAlgorithm2();
                              }
                            }
                            if (widget.extractionAlgorithm == 3) {
                              await Future.delayed(const Duration(milliseconds: 1500));
                              if (!_isDisposed) {
                                _algo3Timer?.cancel(); // Cancel any previous timer on page reload
                                _runAlgorithm3();
                                // Bucle de re-clics: continuar hasta confirmar cambio de servidor Y tener media
                                _algo3Timer = Timer.periodic(const Duration(seconds: 4), (timer) {
                                  if (_isDisposed || (_serverSwitchDone && _foundMedia.isNotEmpty)) {
                                    timer.cancel();
                                    return;
                                  }
                                  _runAlgorithm3();
                                });
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
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        TextButton.icon(
                          onPressed: () => setState(() => _showWebView = !_showWebView),
                          icon: Icon(_showWebView ? Icons.visibility_off_rounded : Icons.visibility_rounded, size: 14, color: Colors.white38),
                          label: Text(_showWebView ? "OCULTAR" : "MOSTRAR ", style: const TextStyle(color: Colors.white38, fontSize: 9, fontWeight: FontWeight.bold)),
                        ),
                        const SizedBox(width: 8),
                        if (widget.extractionAlgorithm == 1 && filteredMedia.isEmpty)
                          TextButton.icon(
                            onPressed: () {
                              Navigator.pop(context); // Cierra este
                              // El MovieOptionsPage ya maneja la lógica de re-lanzar con Alg 2 si es necesario 
                              // pero aquí podemos ofrecer un acceso directo
                            },
                            icon: const Icon(Icons.bolt_rounded, size: 14, color: Colors.amber),
                            label: const Text("PROBAR ALGORITMO 2", style: TextStyle(color: Colors.amber, fontSize: 9, fontWeight: FontWeight.bold)),
                          ),
                      ],
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
                                if (widget.extractionAlgorithm == 3 && !_isSpanishSelected)
                                  const Text("Buscando servidor en español...", style: TextStyle(color: Color(0xFFD400FF), fontSize: 10, fontWeight: FontWeight.bold))
                                else
                                  const Text("Esto puede tardar unos segundos", style: TextStyle(color: Colors.white12, fontSize: 10)),
                              ],
                            ),
                          ),
                        )
                      : widget.extractionAlgorithm == 3 && !_isSpanishSelected
                        ? Center(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                const Icon(Icons.language, color: Color(0xFFD400FF), size: 40),
                                const SizedBox(height: 16),
                                const Text("SERVIDOR NO VALIDADO", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                                const SizedBox(height: 8),
                                const Padding(
                                  padding: EdgeInsets.symmetric(horizontal: 40),
                                  child: Text(
                                    "Esperando a que el sistema seleccione el servidor en español para garantizar el idioma correcto.",
                                    textAlign: TextAlign.center,
                                    style: TextStyle(color: Colors.white54, fontSize: 11),
                                  ),
                                ),
                                const SizedBox(height: 20),
                                const CircularProgressIndicator(color: Color(0xFFD400FF), strokeWidth: 2),
                              ],
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
    
    // Ignorar URLs obvias de anuncios para no saturar la lista
    if (url.contains('googleads') || url.contains('imasdk') || url.contains('doubleclick')) {
      return;
    }

    _detectedUrls.add(url);
    print("[SNIFFER] Analizando flujos para: ${url.substring(0, url.length > 50 ? 50 : url.length)}...");
    
    // FILTRO CRÍTICO: ¿Es esto un video real?
    bool isVideo = url.contains('.m3u8') || 
                   url.contains('.mp4') || 
                   url.contains('.mpd') ||
                   url.contains('ecotechproducts.shop') ||
                   url.contains('cf-master') ||
                   (url.contains('.txt') && (url.contains('master') || url.contains('playlist')));
                   
    if (!isVideo) return;

    setState(() => _statusText = "Capturando stream oficial...");

    // 1. Capture Cookies & Headers (Like 1DM) - FORCE CLONE SESSION
    String? cookieString;
    try {
      final cookieManager = CookieManager.instance();
      
      // Sincronización agresiva: Obtenemos cookies de la URL del video Y de la página original
      final pageCookies = await cookieManager.getCookies(url: WebUri(widget.url));
      final mediaCookies = await cookieManager.getCookies(url: WebUri(url));
      
      final all = [...pageCookies, ...mediaCookies];
      final cookieMap = <String, String>{};
      for (var c in all) {
        cookieMap[c.name] = c.value;
      }
      cookieString = cookieMap.entries.map((e) => '${e.key}=${e.value}').join('; ');
      
      if (customHeaders != null) {
        final lowerHeaders = customHeaders.map((k, v) => MapEntry(k.toLowerCase(), v));
        if (lowerHeaders.containsKey('cookie')) {
          cookieString = lowerHeaders['cookie'];
        }
      }
    } catch (e) {
      print("[SNIFFER] Error capturando cookies: $e");
    }

    final String ua = customHeaders?['user-agent'] ?? customHeaders?['User-Agent'] ?? "Mozilla/5.0 (Linux; Android 13; SM-G991B) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/112.0.0.0 Mobile Safari/537.36";
    final String referer = customHeaders?['referer'] ?? customHeaders?['Referer'] ?? widget.url;

    final headersForProbe = <String, String>{};
    
    // Persistencia de tokens: Si capturamos cabeceras en esta sesión, las mantenemos como base
    if (customHeaders != null) {
      _lastCapturedHeaders ??= {};
      _lastCapturedHeaders!.addAll(customHeaders);
    }

    if (_lastCapturedHeaders != null) {
      for (final entry in _lastCapturedHeaders!.entries) {
        // Clonamos cabeceras de seguridad críticas para evitar el error 403
        final keyLower = entry.key.toLowerCase();
        if (keyLower.startsWith('sec-') || keyLower == 'x-auth' || keyLower == 'authorization' || keyLower == 'range' || keyLower == 'origin') {
          headersForProbe[entry.key] = entry.value;
        }
      }
    }
    
    if (cookieString != null) headersForProbe['Cookie'] = cookieString;
    headersForProbe['User-Agent'] = ua;
    headersForProbe['Referer'] = referer;
    // Si no hay Origin, lo derivamos del Referer para mayor credibilidad
    headersForProbe['Origin'] = headersForProbe['Origin'] ?? referer.split('/').take(3).join('/');
    headersForProbe['Accept'] = '*/*';
    headersForProbe['Accept-Language'] = 'es-ES,es;q=0.9,en;q=0.8';

    // 2. Identify qualities & Explode (Like 1DM)
    try {
      if (url.contains(".m3u8") || url.contains(".txt") || url.contains(".mpd")) {
        print("[SNIFFER] Desglosando lista HLS/TXT para encontrar todas las calidades...");
        
        // Add the main HLS entry immediately WITHOUT probing size (manifests are always tiny)
        _addFoundMedia(
          url: url,
          resolution: "Resolución Auto (HLS)",
          size: "Streaming (HLS)",
          headers: headersForProbe,
          cookies: cookieString,
        );

        // Fetch qualities in background so dialog populates fast
        final masterUrl = await _resolveHlsMasterUrl(url, headersForProbe);
        final targetUrl = masterUrl ?? url;
        List<VideoQuality> explodedQualities = await VideoService.getHlsQualities(targetUrl, headers: headersForProbe);
        
        if (explodedQualities.isEmpty) {
          print('[SNIFFER] HTTP falló para obtener calidades, usando WebView fetch...');
          final webViewText = await _fetchWithWebView(targetUrl);
          if (webViewText != null && webViewText.isNotEmpty) {
            explodedQualities = await VideoService.getHlsQualities(targetUrl, headers: headersForProbe, masterText: webViewText);
          }
        }
        
        print('[SNIFFER] Calidades encontradas: ${explodedQualities.length}');
        for (var q in explodedQualities) {
           print('[SNIFFER] Calidad -> res:${q.resolution} url:${q.url}');
           // Manifest sub-tracks (.txt/.m3u8) don't need size probing — add immediately
           _addFoundMedia(
             url: q.url,
             resolution: "Streaming ${q.resolution}",
             size: "Streaming (HLS)",
             headers: headersForProbe,
             cookies: cookieString,
           );
           print('[SNIFFER] Calidad agregada: ${q.url.split('/').last}');
        }
      } else if (url.contains(".ts") || url.contains(".m4s")) {
        print("[BYPASS] Sesión refrescada mediante fragmento de video.");
        return;
      } else {
        final size = await _probeFileSize(url, headersForProbe);
        _addFoundMedia(
          url: url,
          resolution: "Auto-Captura (Video)",
          size: size,
          headers: headersForProbe,
          cookies: cookieString,
        );
      }
    } catch (e) {
      print("[SNIFFER] Error en bypass: $e");
    }
  }

  // Método eliminado por redundancia con initialUserScripts

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
    
    // Skip tiny files (likely error pages) EXCEPT for manifests (.m3u8, .mpd) which are just text files
    final isManifest = url.contains('.m3u8') || url.contains('.mpd') || url.contains('.txt');
    if (!isManifest && size != null && size.contains('KB') && !size.contains('Streaming')) {
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

  Future<String?> _fetchWithWebView(String url) async {
    if (_webViewController == null) return null;
    try {
      final js = '''
        (async function() {
          try {
            const resp = await fetch("$url");
            if (!resp.ok) return null;
            return await resp.text();
          } catch(e) {
            return null;
          }
        })();
      ''';
      final result = await _webViewController!.evaluateJavascript(source: js);
      return result?.toString();
    } catch (_) {
      return null;
    }
  }

  Future<String?> _resolveHlsMasterUrl(String mediaUrl, Map<String, String> headers) async {
    try {
      final mediaText = await _fetchText(mediaUrl, headers) ?? await _fetchWithWebView(mediaUrl);
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
          // Un poco más de tiempo entre clics para dejar que el sitio procese el anuncio
          await Future.delayed(const Duration(milliseconds: 800));
        }

        // Click again after a short wait to ensure play trigger
        await Future.delayed(const Duration(milliseconds: 800));
        if (!_isDisposed) {
          await _webviewTouchChannel.invokeMethod('tapAt', {
            'x': (offset.dx + w / 2) * dpr,
            'y': (offset.dy + h / 2) * dpr
          });
        }
      }
    } catch (e) {
      print("Error Algoritmo 2 Descarga: $e");
    }
  }

  Future<void> _runAlgorithm3() async {
    if (_isDisposed || !mounted) return;
    try {
      final dpr = MediaQuery.of(context).devicePixelRatio;
      final box = _webViewKey.currentContext?.findRenderObject() as RenderBox?;
      
      // 1. Clics JS (Copiados del reproductor para asegurar activación de Videasy)
      _webViewController?.evaluateJavascript(source: r"""
          (function() {
            function isVisible(el) {
               if (!el) return false;
               var r = el.getBoundingClientRect();
               return r.width > 0 && r.height > 0;
            }
            function forceClick(el) {
              if (!el) return;
              ["touchstart", "touchend", "mousedown", "click", "mouseup"].forEach(t => {
                var ev = new MouseEvent(t, { bubbles: true, cancelable: true, view: window });
                el.dispatchEvent(ev);
              });
            }
            function findByText(root, text, exact = false) {
              var all = root.querySelectorAll('*');
              for (var el of all) {
                var t = el.textContent.trim().toLowerCase();
                if (exact ? t === text.toLowerCase() : t.includes(text.toLowerCase())) {
                   if (isVisible(el)) return el;
                }
                if (el.shadowRoot) {
                  var found = findByText(el.shadowRoot, text, exact);
                  if (found) return found;
                }
              }
              return null;
            }
            function findGear(root) {
              var btn = root.querySelector('button[aria-label*="Setting"], button[aria-label*="Config"], .vds-settings-button, .vjs-settings-control');
              if (btn && isVisible(btn)) return btn;
              var all = root.querySelectorAll('button, div[role="button"]');
              for (var b of all) {
                var svg = b.querySelector('svg');
                if (svg && (svg.innerHTML.includes('M19.43') || svg.innerHTML.includes('12.98') || svg.innerHTML.includes('M12 15.5'))) {
                  if (isVisible(b)) return b;
                }
              }
              return null;
            }

            // === PASO 1: ¿Menú de pestañas visible? ===
            var tabList = document.querySelector('[role="tablist"]') || document.querySelector('.vds-menu-items') || findByText(document, 'Quality');
            if (tabList) {
               console.log('🔍 Menú de ajustes detectado en Extractor');
               var serversTab = findByText(document, 'Servers', true) || findByText(document, 'Servidores', true);
               
               if (serversTab) {
                  var state = serversTab.getAttribute('data-state') || serversTab.getAttribute('aria-selected');
                  if (state === 'active' || state === 'true') {
                     // === PASO 2: Extracción y Auto-Selección ===
                     var panel = document.querySelector('[role="tabpanel"][data-state="active"]') || serversTab.parentElement.parentElement;
                     var serverBtns = Array.from(panel.querySelectorAll('button, [role="radio"], [role="menuitem"]'));
                     
                     var target = serverBtns.find(b => b.textContent.toLowerCase().includes('gekko'));
                     if (!target) {
                        target = serverBtns.find(b => {
                           var t = b.textContent.toLowerCase();
                           return t.includes('spanish') || t.includes('latino') || t.includes('español') || t.includes('castellano');
                        });
                     }
                     if (target) {
                        console.log('🎯 [AUTO-SELECT] Seleccionando servidor prioritario: ' + target.textContent);
                        if (window.flutter_inappwebview) window.flutter_inappwebview.callHandler('onServerSelected', target.textContent);
                        forceClick(target);
                     } else {
                        var firstInPanel = document.querySelector('[role="tabpanel"] button');
                        if (firstInPanel) {
                           if (window.flutter_inappwebview) window.flutter_inappwebview.callHandler('onServerSelected', firstInPanel.textContent);
                           forceClick(firstInPanel);
                        }
                     }
                  } else {
                     console.log('🖱️ Pestaña Servers inactiva, clickeando...');
                     forceClick(serversTab);
                     return;
                  }
               }
            } else {
               // === PASO 0: Abrir el engranaje ===
               var gear = findGear(document);
               if (gear) {
                  console.log('⚙️ Engranaje encontrado, abriendo menú...');
                  forceClick(gear);
               } else {
                  // Fallback: Si no hay engranaje pero hay botones de servers directamente
                  var allButtons = document.querySelectorAll('button, [role="radio"], [role="menuitem"]');
                  var fallbackTarget = null;
                  for (var b of allButtons) {
                     if (b.textContent.toLowerCase().includes('gekko') && isVisible(b)) {
                        fallbackTarget = b; break;
                     }
                  }
                  if (!fallbackTarget) {
                     for (var b of allButtons) {
                        var t = b.textContent.toLowerCase();
                        if ((t.includes('spanish') || t.includes('latino') || t.includes('español') || t.includes('castellano')) && isVisible(b)) {
                           fallbackTarget = b; break;
                        }
                     }
                  }
                  if (fallbackTarget) {
                     console.log('🎯 [AUTO-SELECT] Fallback clic: ' + fallbackTarget.textContent);
                     if (window.flutter_inappwebview) window.flutter_inappwebview.callHandler('onServerSelected', fallbackTarget.textContent);
                     forceClick(fallbackTarget);
                  }
               }
            }
          })();
      """);

      // 2. Clics Nativos (Copiados exactamente del reproductor)
      if (box != null && box.hasSize) {
        final offset = box.localToGlobal(Offset.zero);
        final w = box.size.width;
        final h = box.size.height;

        print("[SNIFFER] Ejecutando Algoritmo 3 de Clics Humanos para descarga...");

        final points = [
          Offset(w / 2, h / 2),
          Offset(w / 2 + 20, h / 2),
          Offset(w / 2, h / 2 + 20),
          Offset(w / 2 - 25, h / 2 - 25)
        ];

        for (var p in points) {
          if (_isDisposed) break; // Solo parar si el widget fue destruido
          await _webviewTouchChannel.invokeMethod('tapAt', {
            'x': (offset.dx + p.dx) * dpr,
            'y': (offset.dy + p.dy) * dpr
          });
          await Future.delayed(const Duration(milliseconds: 600));
        }
      }
    } catch (e) {
      print("Error Algoritmo 3 Descarga: $e");
    }
  }

  String _getGhostSnifferCode() {
    return r'''
      (function() {
        if (window._ghostPowered) return;
        window._ghostPowered = true;
        console.log('[DEBUG_JS] GHOST_SNIFFER_v5.5_DEEP_ENGINE_ACTIVE');

        function notify(url, meta) {
          if (!url || typeof url !== 'string' || url.startsWith('blob:') || url.length < 15) return;
          if (url.includes('.js') || url.includes('.css') || url.includes('.png') || url.includes('analytics')) return;
          try {
            window.flutter_inappwebview.callHandler('snifferUrl', url, meta || {source: 'unknown'});
          } catch(e) {}
        }

        // 1. Hook de URL.createObjectURL para capturar Blobs (Muy común en reproductores modernos)
        const _createObjectURL = URL.createObjectURL;
        URL.createObjectURL = function(blob) {
          const url = _createObjectURL.apply(this, arguments);
          if (blob.type && (blob.type.includes('mpegurl') || blob.type.includes('video'))) {
             console.log('[DEBUG_JS] Blob Video Detectado: ' + url);
             // No notificamos el blob, pero esto nos dice que el video está cargando por partes
          }
          return url;
        };

        // 2. Extraer de Motores de Streaming (HLS.js / Video.js)
        const scanEngine = () => {
          // HLS.js
          if (window.Hls && window.Hls.instances) {
            window.Hls.instances.forEach(h => notify(h.url, {engine: 'hls_instance'}));
          }
          // Video.js
          if (window.videojs && window.videojs.getPlayers) {
            const players = window.videojs.getPlayers();
            for (let p in players) notify(players[p].currentSrc(), {engine: 'videojs'});
          }
          // JWPlayer (Global)
          if (window.jwplayer && typeof jwplayer === 'function') {
            try { 
              const playlist = jwplayer().getPlaylist();
              if (playlist) playlist.forEach(p => p.sources.forEach(s => notify(s.file, {engine: 'jwplayer'})));
            } catch(e){}
          }
        };

        // 3. Escaneo de reproducción activa (ReadyState > 2)
        const deepScan = () => {
          const videos = document.querySelectorAll('video');
          videos.forEach(v => {
            if (v.readyState >= 2) { // Video ya tiene datos o está reproduciendo
               const src = v.src || v.currentSrc;
               if (src && !src.startsWith('blob:')) notify(src, {status: 'playing', area: 'active_dom'});
               
               // Si es un Blob, intentamos buscar el playlist origen en el historial de red
               if (src && src.startsWith('blob:')) {
                 console.log('[DEBUG_JS] Video reproduciendo mediante BLOB. Buscando manifiesto...');
               }
            }
          });
          scanEngine();
        };

        // Interceptación de Red (Fetch/XHR)
        const _fetch = window.fetch;
        window.fetch = function(...args) {
          let url = typeof args[0] === 'string' ? args[0] : (args[0] && args[0].url);
          if (url && (url.includes('.m3u8') || url.includes('.mp4'))) notify(url, {source: 'fetch_active'});
          return _fetch.apply(this, args);
        };

        const _open = XMLHttpRequest.prototype.open;
        XMLHttpRequest.prototype.open = function(m, u) {
          if (u && (u.includes('.m3u8') || u.includes('.mp4'))) notify(u, {source: 'xhr_active'});
          return _open.apply(this, arguments);
        };

        setInterval(deepScan, 1000);
        setInterval(() => window.flutter_inappwebview.callHandler('debugLog', 'GHOST_HEARTBEAT_v5.5'), 3000);
        
        notify('READY_SIGNAL', {status: 'v5.5_ready'});
      })();
    ''';
  }
}
