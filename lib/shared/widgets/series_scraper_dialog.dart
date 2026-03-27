import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import '../../features/series/domain/entities/episode.dart';
import '../../features/series/domain/entities/season.dart';

class ScrapedEpisode {
  final String title;
  final String url;

  ScrapedEpisode({required this.title, required this.url});
}

class SeriesScraperDialog extends StatefulWidget {
  final String url;
  
  const SeriesScraperDialog({super.key, required this.url});

  @override
  State<SeriesScraperDialog> createState() => _SeriesScraperDialogState();
}

class _SeriesScraperDialogState extends State<SeriesScraperDialog> {
  InAppWebViewController? _webViewController;
  bool _isLoading = true;
  List<ScrapedEpisode> _foundEpisodes = [];
  int _targetSeason = 1;
  late TextEditingController _seasonController;

  @override
  void initState() {
    super.initState();
    _seasonController = TextEditingController(text: '1');
  }

  @override
  void dispose() {
    _seasonController.dispose();
    super.dispose();
  }

  final String _scraperJs = '''
    (function() {
      // Remove common ad elements
      const adSelectors = [
        'iframe[id^="aswift"]', 'div[class*="ad-"]', 'div[id*="ad-"]',
        '.overlay', '.popup', '.popup-container', '#popads', '.modal-backdrop'
      ];
      adSelectors.forEach(s => {
        document.querySelectorAll(s).forEach(el => el.remove());
      });

      // Disable window.open to prevent popups
      window.open = function() { return null; };

      function findEpisodes() {
        const episodes = [];
        const links = document.querySelectorAll('a');
        const regex = /(capitulo|episodio|ep|cap|parte)\\s*\\d+/i;
        const videoExtRegex = /\\.(mp4|m3u8|m3u|mkv|webm|txt\\?.*cf-master)/i;
        const numRegex = /^\\d+\\s*\$/;

        links.forEach(a => {
          const text = a.innerText.trim();
          const href = a.href;
          if (!href || href.startsWith('javascript:')) return;
          
          if (regex.test(text) || numRegex.test(text) || videoExtRegex.test(href)) {
            if (!episodes.find(e => e.url === href)) {
              episodes.push({title: text || 'Enlace detectado', url: href});
            }
          }
        });

        // Search for direct <source> tags
        document.querySelectorAll('source, video').forEach(v => {
          const src = v.src || v.getAttribute('src');
          if (src && videoExtRegex.test(src)) {
            if (!episodes.find(e => e.url === src)) {
              episodes.push({title: 'Stream directo detectado', url: src});
            }
          }
        });

        // AUTO-EVASION: Click common close buttons for ads
        const closers = document.querySelectorAll('.close, .closed, .btn-close, [class*="close-"], [id*="close-"], .cerrar, #close_button');
        closers.forEach(c => { if(c.offsetParent !== null) c.click(); });

        // AUTO-PLAY: Click play buttons to trigger network traffic
        const players = document.querySelectorAll('.vjs-big-play-button, .play-button, [aria-label="Play"], .plyr__control--overlaid, .play_icon');
        players.forEach(p => { if(p.offsetParent !== null) p.click(); });

        return episodes;
      }
      return findEpisodes();
    })();
  ''';

  final List<ContentBlocker> _contentBlockers = [
    ContentBlocker(
      trigger: ContentBlockerTrigger(urlFilter: ".*"),
      action: ContentBlockerAction(
        type: ContentBlockerActionType.CSS_DISPLAY_NONE, 
        selector: ".ad, .ads, .advertisement, [id^='ad-'], [class^='ad-'], .overlay, .popup, .popup-container, #popads, .modal-backdrop"
      ),
    ),
    ContentBlocker(
      trigger: ContentBlockerTrigger(urlFilter: ".*(doubleclick.net|googleadservices.com|googlesyndication.com|popads.net|popcash.net|exoclick.com|juicyads.com|propellerads.com|clonamp.com).*"),
      action: ContentBlockerAction(type: ContentBlockerActionType.BLOCK),
    )
  ];

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.black,
      insetPadding: const EdgeInsets.all(16),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: const BoxDecoration(
              gradient: LinearGradient(colors: [Color(0xFF00A3FF), Color(0xFFD400FF)]),
            ),
            child: Row(
              children: [
                const Icon(Icons.auto_awesome, color: Colors.white),
                const SizedBox(width: 8),
                const Expanded(child: Text('ESCÁNER MÁGICO DE EPISODIOS', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold))),
                IconButton(icon: const Icon(Icons.close, color: Colors.white), onPressed: () => Navigator.pop(context)),
              ],
            ),
          ),
          Container(
             color: const Color(0xFF1E1E1E),
             padding: const EdgeInsets.all(8),
             child: Wrap(
               crossAxisAlignment: WrapCrossAlignment.center,
               alignment: WrapAlignment.spaceBetween,
               spacing: 8,
               runSpacing: 8,
               children: [
                 Row(
                   mainAxisSize: MainAxisSize.min,
                   children: [
                     const Text('TEMPORADA: ', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 11)),
                     SizedBox(
                       width: 50,
                       height: 35,
                       child: TextField(
                         controller: _seasonController,
                         keyboardType: TextInputType.number,
                         textAlign: TextAlign.center,
                         style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold),
                         decoration: InputDecoration(
                           contentPadding: EdgeInsets.zero,
                           filled: true,
                           fillColor: Colors.white.withOpacity(0.05),
                           border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFF00A3FF))),
                           enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: Colors.white.withOpacity(0.1))),
                         ),
                         onChanged: (val) {
                           final n = int.tryParse(val);
                           if (n != null) _targetSeason = n;
                         },
                       ),
                     ),
                   ],
                 ),
                 ElevatedButton.icon(
                   onPressed: () async {
                     if (_webViewController != null) {
                       final result = await _webViewController!.evaluateJavascript(source: _scraperJs);
                       if (result != null && result is List) {
                         setState(() {
                           _foundEpisodes.clear();
                           for(var item in result) {
                             if (item is Map) {
                               _foundEpisodes.add(ScrapedEpisode(title: item['title'].toString(), url: item['url'].toString()));
                             }
                           }
                         });
                         ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Se encontraron \${_foundEpisodes.length} episodios!')));
                       }
                     }
                   },
                   icon: const Icon(Icons.search),
                   label: const Text('ESCANEAR'),
                 )
               ],
             )
          ),
          Expanded(
            child: Row(
              children: [
                Expanded(
                  flex: 2,
                  child: Stack(
                    children: [
                      InAppWebView(
                        initialUrlRequest: URLRequest(url: WebUri(widget.url)),
                        initialSettings: InAppWebViewSettings(
                          javaScriptEnabled: true,
                          javaScriptCanOpenWindowsAutomatically: false,
                          supportMultipleWindows: false,
                          userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
                          contentBlockers: _contentBlockers,
                          useShouldOverrideUrlLoading: true,
                          mediaPlaybackRequiresUserGesture: false,
                          allowsInlineMediaPlayback: true,
                        ),
                        onWebViewCreated: (controller) {
                          _webViewController = controller;
                        },
                        onLoadResource: (controller, resource) {
                          final url = resource.url?.toString() ?? '';
                          final lcUrl = url.toLowerCase();
                          
                          // Exclude tracker/analytics domains
                          bool isJunk = lcUrl.contains('analytics') || 
                                       lcUrl.contains('google-analytics') || 
                                       lcUrl.contains('doubleclick') || 
                                       lcUrl.contains('collect?') ||
                                       lcUrl.contains('facebook.com/tr/') ||
                                       lcUrl.contains('yandex') ||
                                       lcUrl.contains('mc.yandex.ru');

                          if (isJunk) return;

                          // Better video detection: extension should be followed by anchor, end, or param
                          bool hasVideoExt = lcUrl.contains('.mp4?') || lcUrl.endsWith('.mp4') ||
                                            lcUrl.contains('.m3u8?') || lcUrl.endsWith('.m3u8') ||
                                            lcUrl.contains('.m3u?') || lcUrl.endsWith('.m3u');
                          
                          bool is4meStream = lcUrl.contains('cf-master') && lcUrl.contains('.txt');

                          if (hasVideoExt || is4meStream) {
                            // Find if already added
                            if (!_foundEpisodes.any((e) => e.url == url)) {
                              setState(() {
                                // Extract a name based on the current page title or similar
                                String title = 'Video detectado (Red)';
                                if (is4meStream) title = 'HLS (4meplayer)';
                                _foundEpisodes.add(ScrapedEpisode(title: title, url: url));
                              });
                            }
                          }
                        },
                        onCreateWindow: (controller, createWindowAction) async {
                          // Prevent ad popups from opening NEW windows
                          return false; 
                        },
                        onLoadStop: (controller, url) {
                          setState(() => _isLoading = false);
                          // Periodically run cleaner and auto-play logic
                          Timer.periodic(const Duration(seconds: 2), (t) {
                            if (!mounted) { t.cancel(); return; }
                            controller.evaluateJavascript(source: _scraperJs);
                          });
                        },
                        shouldOverrideUrlLoading: (controller, navigationAction) async {
                          var uri = navigationAction.request.url;
                          if (uri != null && navigationAction.isForMainFrame) {
                            final initialHost = Uri.tryParse(widget.url)?.host ?? '';
                            final host = uri.host.toLowerCase();
                            
                            // Allow common CDNs and initial host
                            bool isSafe = host == initialHost || 
                                         host.contains('google') || 
                                         host.contains('facebook') ||
                                         host.contains('cloudflare') ||
                                         host.contains('jsdelivr');

                            if (!isSafe) {
                              print('Blocking main-frame redirect to: ${uri.host}');
                              return NavigationActionPolicy.CANCEL;
                            }
                          }
                          return NavigationActionPolicy.ALLOW;
                        },
                      ),
                      if (_isLoading)
                        const Center(child: CircularProgressIndicator()),
                    ],
                  ),
                ),
                Container(width: 1, color: Colors.white12),
                Expanded(
                  flex: 1,
                  child: Container(
                    color: const Color(0xFF121212),
                    child: Column(
                      children: [
                         const Padding(
                           padding: EdgeInsets.all(8.0),
                           child: Text('Extraídos', style: TextStyle(color: Color(0xFF00A3FF), fontWeight: FontWeight.bold)),
                         ),
                         Expanded(
                           child: ListView.builder(
                             itemCount: _foundEpisodes.length,
                             itemBuilder: (context, index) {
                               final ep = _foundEpisodes[index];
                               return ListTile(
                                 visualDensity: VisualDensity.compact,
                                 title: Text(ep.title, style: const TextStyle(color: Colors.white, fontSize: 12)),
                                 subtitle: Text(ep.url, style: const TextStyle(color: Colors.white38, fontSize: 10), maxLines: 1, overflow: TextOverflow.ellipsis),
                                 trailing: IconButton(
                                   icon: const Icon(Icons.remove_circle, color: Colors.redAccent, size: 16),
                                   onPressed: () => setState(() => _foundEpisodes.removeAt(index)),
                                 ),
                               );
                             },
                           ),
                         ),
                         if (_foundEpisodes.isNotEmpty)
                           Padding(
                             padding: const EdgeInsets.all(8.0),
                             child: ElevatedButton(
                               onPressed: () {
                                 Navigator.pop(context, {'seasonNumber': _targetSeason, 'episodes': _foundEpisodes});
                               },
                               style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00A3FF), foregroundColor: Colors.white, minimumSize: const Size(double.infinity, 40)),
                               child: const Text('GUARDAR ESTOS CAPÍTULOS'),
                             ),
                           )
                      ],
                    ),
                  )
                )
              ],
            )
          )
        ],
      )
    );
  }
}
