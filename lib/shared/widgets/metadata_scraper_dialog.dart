import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

class MetadataScraperDialog extends StatefulWidget {
  final String url;
  
  const MetadataScraperDialog({super.key, required this.url});

  @override
  State<MetadataScraperDialog> createState() => _MetadataScraperDialogState();
}

class _MetadataScraperDialogState extends State<MetadataScraperDialog> {
  InAppWebViewController? _webViewController;
  bool _isLoading = true;
  String? _scrapedName;
  String? _scrapedDescription;
  String? _scrapedRating;
  String? _scrapedYear;
  String? _scrapedImage;

  final String _metadataJs = '''
    (function() {
      // Helper to find text by common patterns
      function findByText(regex) {
        const elements = document.querySelectorAll('p, div, span, li, b, strong');
        for (let el of elements) {
          if (regex.test(el.innerText)) return el.innerText;
        }
        return null;
      }

      const metadata = {
        name: document.querySelector('h1')?.innerText?.trim(),
        description: document.querySelector('meta[name="description"]')?.content || 
                     document.querySelector('.description')?.innerText || 
                     document.querySelector('#description')?.innerText,
        image: document.querySelector('meta[property="og:image"]')?.content || 
               document.querySelector('meta[name="twitter:image"]')?.content,
        rating: null,
        year: null
      };

      // Try to find rating
      const ratingRegex = /(\\d+(\\.\\d+)?)\\s*\\/\\s*10|nota:\\s*(\\d+(\\.\\d+)?)/i;
      const ratingText = findByText(ratingRegex);
      if (ratingText) {
        const match = ratingText.match(ratingRegex);
        metadata.rating = match[1] || match[3];
      }

      // Try to find year
      const yearRegex = /(19|20)\\d{2}/;
      const yearText = findByText(yearRegex);
      if (yearText) {
        const match = yearText.match(yearRegex);
        metadata.year = match[0];
      }

      // If description still null, try some common containers
      if (!metadata.description) {
        const commonDescClasses = ['.synopsis', '.plot', '.storyline', '.entry-content'];
        for (let cls of commonDescClasses) {
          const el = document.querySelector(cls);
          if (el) {
            metadata.description = el.innerText.trim();
            break;
          }
        }
      }

      return metadata;
    })();
  ''';

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xFF0A0A0A),
      insetPadding: const EdgeInsets.all(20),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: const BoxDecoration(
              gradient: LinearGradient(colors: [Color(0xFF00A3FF), Color(0xFFD400FF)]),
            ),
            child: Row(
              children: [
                const Icon(Icons.psychology_alt, color: Colors.white),
                const SizedBox(width: 12),
                const Expanded(child: Text('EXTRACCIÓN INTELIGENTE', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold))),
                IconButton(icon: const Icon(Icons.close, color: Colors.white), onPressed: () => Navigator.pop(context)),
              ],
            ),
          ),
          Expanded(
            child: Row(
              children: [
                Expanded(
                  flex: 1,
                  child: Stack(
                    children: [
                      InAppWebView(
                        initialUrlRequest: URLRequest(url: WebUri(widget.url)),
                        initialSettings: InAppWebViewSettings(
                          javaScriptEnabled: true,
                          useShouldOverrideUrlLoading: true,
                        ),
                        onWebViewCreated: (controller) => _webViewController = controller,
                        onLoadStop: (controller, url) async {
                          setState(() => _isLoading = false);
                          final result = await controller.evaluateJavascript(source: _metadataJs);
                          if (result != null && result is Map) {
                            setState(() {
                              _scrapedName = result['name'];
                              _scrapedDescription = result['description'];
                              _scrapedRating = result['rating'];
                              _scrapedYear = result['year'];
                              _scrapedImage = result['image'];
                            });
                          }
                        },
                      ),
                      if (_isLoading) const Center(child: CircularProgressIndicator()),
                    ],
                  ),
                ),
                Container(width: 1, color: Colors.white12),
                Container(
                  width: 280,
                  padding: const EdgeInsets.all(16),
                  color: Colors.black,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('VISTA PREVIA', style: TextStyle(color: Color(0xFF00A3FF), fontWeight: FontWeight.bold, fontSize: 12, letterSpacing: 1.5)),
                      const SizedBox(height: 16),
                      if (_scrapedImage != null)
                        AspectRatio(
                          aspectRatio: 16/9,
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: Image.network(_scrapedImage!, fit: BoxFit.cover, errorBuilder: (_, __, ___) => const Icon(Icons.broken_image, color: Colors.white24)),
                          ),
                        ),
                      const SizedBox(height: 12),
                      Text(_scrapedName ?? 'Cargando nombre...', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          const Icon(Icons.star, color: Colors.amber, size: 16),
                          const SizedBox(width: 4),
                          Text(_scrapedRating ?? '?', style: const TextStyle(color: Colors.amber, fontWeight: FontWeight.bold)),
                          const SizedBox(width: 16),
                          const Icon(Icons.calendar_today, color: Colors.white54, size: 14),
                          const SizedBox(width: 4),
                          Text(_scrapedYear ?? '?', style: const TextStyle(color: Colors.white54)),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Expanded(
                        child: SingleChildScrollView(
                          child: Text(
                            _scrapedDescription ?? 'Buscando descripción...',
                            style: const TextStyle(color: Colors.white70, fontSize: 12, height: 1.4),
                          ),
                        ),
                      ),
                      const SizedBox(height: 20),
                      ElevatedButton(
                        onPressed: () {
                          Navigator.pop(context, {
                            'name': _scrapedName,
                            'description': _scrapedDescription,
                            'rating': double.tryParse(_scrapedRating ?? '0'),
                            'year': _scrapedYear,
                            'image': _scrapedImage,
                          });
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF00A3FF),
                          foregroundColor: Colors.white,
                          minimumSize: const Size(double.infinity, 50),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                        child: const Text('CONFIRMAR Y LLENAR', style: TextStyle(fontWeight: FontWeight.bold)),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
