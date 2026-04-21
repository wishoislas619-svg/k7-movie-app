
import sys
import re

path = 'lib/features/player/presentation/pages/video_player_page.dart'
with open(path, 'r', encoding='utf-8') as f:
    content = f.read()

# 1. Add onUrlDetected handler
if 'onUrlDetected' not in content:
    content = content.replace("print(\"🌍 SERVIDORES VIDEASY ENCONTRADOS: \", _videasyServers.length);", 
                               "print(\"🌍 SERVIDORES VIDEASY ENCONTRADOS: \", _videasyServers.length);\n                                  }\n                                }\n                              });\n\n                              // MONITOR DE RED (FETCH/XHR)\n                              controller.addJavaScriptHandler(handlerName: 'onUrlDetected', callback: (args) {\n                                if (args.isNotEmpty && args[0] != null) {\n                                  _handleDetectedVideoUrl(args[0].toString());\n                                }\n                              });")
    # Actually I used a slightly different print in my previous check. Let's fix.
    content = content.replace('🌍 SERVIDORES VIDEASY ENCONTRADOS: ${_videasyServers.length}', '🌍 SERVIDORES VIDEASY ENCONTRADOS: ${_videasyServers.length}')

# 2. Update initialSettings
content = content.replace('useOnDownloadStart: true,', 'useOnDownloadStart: true,\n                            useShouldInterceptRequest: true,')

# 3. Add onLoadStart
if 'onLoadStart: (controller, url) async {' not in content:
    injection = '''
                          onLoadStart: (controller, url) async {
                             const injectNetMonitor = r\"\"\"
                                (function() {
                                  if (window._netMonitorInjected) return;
                                  window._netMonitorInjected = true;
                                  const oldFetch = window.fetch;
                                  window.fetch = function() {
                                    const arg = arguments[0];
                                    const url = (typeof arg === "string") ? arg : (arg.url || "");
                                    if (url && (url.includes(".m3u8") || url.includes(".mp4") || url.includes("/stream/") || url.includes(".txt") || url.includes("playlist"))) {
                                       window.flutter_inappwebview.callHandler("onUrlDetected", url);
                                    }
                                    return oldFetch.apply(this, arguments);
                                  };
                                  const oldXHR = window.XMLHttpRequest.prototype.open;
                                  window.XMLHttpRequest.prototype.open = function() {
                                    const url = arguments[1];
                                    if (url && (url.includes(".m3u8") || url.includes(".mp4") || url.includes("/stream/") || url.includes(".txt") || url.includes("playlist"))) {
                                       window.flutter_inappwebview.callHandler("onUrlDetected", url);
                                    }
                                    return oldXHR.apply(this, arguments);
                                  };
                                })();
                             \"\"\";
                             await controller.evaluateJavascript(source: injectNetMonitor);
                          },'''
    content = content.replace('userAgent: \"Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1\",\n                          ),',
                               'userAgent: \"Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1\",\n                          ),' + injection)

# 4. Refactor onLoadResource
# Using a regex to find the onLoadResource block
resource_pattern = re.compile(r'onLoadResource: \(controller, resource\) \{.*?\},', re.DOTALL)
replacement_resource = '''onLoadResource: (controller, resource) {
                            final url = resource.url?.toString() ?? '';
                            final lcUrl = url.toLowerCase();
                            
                            final bool hasVideoExt = lcUrl.contains('.mp4?') || lcUrl.endsWith('.mp4') || lcUrl.contains('.m3u8?') || lcUrl.endsWith('.m3u8') || lcUrl.contains('.m3u?') || lcUrl.endsWith('.m3u') || lcUrl.contains('.webm') || lcUrl.contains('.ts') || lcUrl.contains('.mov') || lcUrl.contains('.avi') || lcUrl.contains('.mkv');
                            final bool isVideasyStream = (lcUrl.contains('videasy') || widget.extractionAlgorithm == 3) && 
                                                 (lcUrl.contains('.js') || lcUrl.contains('.txt') || lcUrl.contains('/stream/') || lcUrl.contains('playlist')) && 
                                                 !lcUrl.contains('script.js') && !lcUrl.contains('ab.js') && !lcUrl.contains('beacon.min.js') && !lcUrl.contains('_next/static');

                            if ((hasVideoExt || isVideasyStream) && (_isWebViewExtracting || _isSwitchingStream)) {
                               _handleDetectedVideoUrl(url);
                            }
                          },'''
content = resource_pattern.sub(replacement_resource, content)

with open(path, 'w', encoding='utf-8') as f:
    f.write(content)
print("Patch applied successfully")
