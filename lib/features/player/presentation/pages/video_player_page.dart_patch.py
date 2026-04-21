
import sys
import re

path = 'lib/features/player/presentation/pages/video_player_page.dart'
with open(path, 'r', encoding='utf-8') as f:
    content = f.read()

# 1. Update initialSettings
if 'useShouldInterceptRequest: true,' not in content:
    content = content.replace('useOnDownloadStart: true,', 'useOnDownloadStart: true,\n                            useShouldInterceptRequest: true,')

# 2. Add onLoadStart
if 'onLoadStart: (controller, url) async {' not in content:
    injection_code = r'''
                          onLoadStart: (controller, url) async {
                             const injectNetMonitor = r"''' + r'''
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
                             ''' + r'''";
                             await controller.evaluateJavascript(source: injectNetMonitor);
                          },'''
    content = content.replace('userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",\n                          ),', 
        'userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",\n                          ),' + injection_code)

# 3. Simplify onLoadResource inner logic - match the if block precisely
# Start from print and go until the next } }
inner_block_pattern = re.compile(r'print\(.*?VIDEO_DETECTADO: \$url.*?\);.*?isSameBase = currentBase == newBase;.*?\}\s*\}\s*\}', re.DOTALL)
if inner_block_pattern.search(content):
    content = inner_block_pattern.sub('_handleDetectedVideoUrl(url);\n                            }', content)

# 4. Fix isVideasyStream pattern
content = content.replace("lcUrl.contains('/stream/')) &&", "lcUrl.contains('/stream/') || lcUrl.contains('playlist')) &&")

with open(path, 'w', encoding='utf-8') as f:
    f.write(content)
print("Patch applied successfully")
