
import sys
import re

path = 'lib/features/player/presentation/pages/video_player_page.dart'
with open(path, 'r', encoding='utf-8') as f:
    content = f.read()

# Final Videasy scraper (v4.1) with robust trigger detection
final_scraper_js = r"""          (function() {
            console.log("🕵️ Scraper Videasy v4.1...");
            
            var keywords = ['neon', 'yoru', 'cypher', 'sage', 'jett', 'reyna', 'gekko', 'latino', 'castellano', 'english', 'español', 'spanish', 'audio', 'original'];
            
            function isRealServer(el) {
               if (el.offsetParent === null) return false; // Ignorar ocultos
               
               var t = el.innerText.trim().toLowerCase();
               if (t.length === 0 || t.length > 60) return false;
               
               // Filtro de navegación estructural (botones del menú principal)
               var navWords = ['quality', 'calidad', 'subs', 'subtítulos', 'subtitles', 'speed', 'velocidad', 'back', 'atrás', 'settings', 'configuración'];
               if (navWords.some(w => t === w)) return false;
               // El botón "Servers" en sí mismo no es un servidor
               if (t === 'servers' || t === 'servidores') return false;

               var hasFlag = el.querySelector('img[src*="flagsapi"]') || el.querySelector('img[src*="imgur.com"]') || el.querySelector('img[src*="flag"]');
               var isKnownName = keywords.some(k => t.includes(k));
               
               return hasFlag || isKnownName;
            }

            // 1. Intentar extraer servidores
            var allElements = Array.from(document.querySelectorAll('button, div[role="button"], .jw-settings-content-item, .art-setting-item, .item, li, a, .play-server, .server-item'));
            var possibleServers = allElements.filter(isRealServer);

            if (possibleServers.length > 0) {
               console.log("✅ Servidores detectados: " + possibleServers.length);
               var results = [];
               possibleServers.forEach(function(el) {
                  var img = el.querySelector('img') || (el.tagName === 'IMG' ? el : null);
                  var text = el.innerText.trim() || el.title || el.alt;
                  var lang = "";
                  var content = text.toLowerCase();
                  
                  if (content.includes('latino')) lang = "Latino";
                  else if (content.includes('castellano')) lang = "Castellano";
                  else if (content.includes('español') || content.includes('spanish')) lang = "Español";
                  else if (content.includes('english') || content.includes('original')) lang = "English";

                  text = text.split('\n')[0].trim();
                  results.push({ id: text, label: text, flagUrl: img ? img.src : '', language: lang });
               });

               var uniqueResults = results.filter((v, i, a) => a.findIndex(t => t.label === v.label) === i);
               if (uniqueResults.length > 0) {
                 window.flutter_inappwebview.callHandler('onServersFound', uniqueResults);
               }
               return; 
            }

            // 2. Si no hay, buscar el botón para entrar al menú de servidores
            var serversTrigger = allElements.find(el => {
                var t = el.innerText.trim().toLowerCase();
                return (t === 'servers' || t === 'servidores') && el.offsetParent !== null;
            });

            if (serversTrigger) {
               console.log("🖱️ Entrando al submenú [Servers]...");
               serversTrigger.click();
               return;
            }

            // 3. Si nada funciona, abrir el menú de la nube
            var allSvgs = Array.from(document.querySelectorAll('svg'));
            var cloudIcon = allSvgs.find(s => s.innerHTML.includes('M19.43 12.98') || s.innerHTML.includes('M12 15.5') || s.innerHTML.includes('M12 2C6.48 2'));
            if (cloudIcon) {
               var cloudBtn = cloudIcon.closest('button') || cloudIcon.parentElement;
               if (cloudBtn && cloudBtn.offsetParent !== null) {
                  console.log("🖱️ Abriendo menú principal (nube)...");
                  cloudBtn.click();
               }
            }
          })();"""

# Replace the previous block
js_pattern = re.compile(r'evaluateJavascript\(source: """\n\s+\(function\(\) \{.*?\}\)\(\);', re.DOTALL)
content = js_pattern.sub(f'evaluateJavascript(source: """\n{final_scraper_js}', content)

with open(path, 'w', encoding='utf-8') as f:
    f.write(content)
print("SCRAPER ENHANCED V4.1")
