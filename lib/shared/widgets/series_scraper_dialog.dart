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
        const regex = /(capitulo|episodio|ep|cap)\\s*\\d+/i;
        const numRegex = /^\\d+\\s*\$/;

        links.forEach(a => {
          const text = a.innerText.trim();
          const href = a.href;
          if (!href || href.startsWith('javascript:')) return;
          
          if (regex.test(text) || numRegex.test(text)) {
            if (!episodes.find(e => e.url === href)) {
              episodes.push({title: text, url: href});
            }
          }
        });
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
                     const Text('Temporada: ', style: TextStyle(color: Colors.white70)),
                     DropdownButton<int>(
                       dropdownColor: const Color(0xFF2C2C2C),
                       value: _targetSeason,
                       items: List.generate(10, (i) => DropdownMenuItem(value: i + 1, child: Text('${i + 1}', style: const TextStyle(color: Colors.white)))),
                       onChanged: (val) => setState(() => _targetSeason = val ?? 1),
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
                          contentBlockers: _contentBlockers,
                          useShouldOverrideUrlLoading: true,
                        ),
                        onWebViewCreated: (controller) {
                          _webViewController = controller;
                        },
                        onLoadStop: (controller, url) {
                          setState(() => _isLoading = false);
                          // Inject cleaner on every load
                          controller.evaluateJavascript(source: _scraperJs);
                        },
                        shouldOverrideUrlLoading: (controller, navigationAction) async {
                          var uri = navigationAction.request.url;
                          if (uri != null) {
                            final initialHost = Uri.parse(widget.url).host;
                            if (uri.host != initialHost && !uri.host.contains('google') && !uri.host.contains('facebook')) {
                              print('Blocking redirect to: ${uri.host}');
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
