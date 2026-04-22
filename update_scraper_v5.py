
import sys
import re

path = 'lib/features/player/presentation/pages/video_player_page.dart'
with open(path, 'r', encoding='utf-8') as f:
    content = f.read()

# Scraper v5: Emulate exactly what the user wanted: open menu -> click servers -> extract what appears
v5_scraper_js = r"""          (function() {
            console.log("🕵️ Scraper Videasy v5...");
            
            // Todos los elementos potencialmente interactivos
            var allElements = Array.from(document.querySelectorAll('button, div[role="button"], .jw-settings-content-item, .art-setting-item, .item, li, a, .play-server'));
            
            // 1. ¿Estamos en el menú principal? (Quality, Subs, Servers, Speed)
            var menuPrincipalOptions = allElements.filter(el => {
                if (el.offsetParent === null) return false;
                var t = el.innerText.trim().toLowerCase();
                return t === 'quality' || t === 'calidad' || t === 'subs' || t === 'servers' || t === 'servidores' || t === 'speed';
            });

            if (menuPrincipalOptions.length >= 2) { // Si vemos al menos 2 de estas opciones, estamos en el main menu
                var btnServers = menuPrincipalOptions.find(el => {
                    var t = el.innerText.trim().toLowerCase();
                    return t === 'servers' || t === 'servidores';
                });
                
                if (btnServers) {
                    console.log("🖱️ Menú principal detectado. Haciendo click en 'Servers'...");
                    btnServers.click();
                    return; // Terminamos aquí, esperamos al siguiente ciclo
                }
            }

            // 2. Si NO estamos en el menú principal, buscar si estamos en el submenú de servidores
            var isInsideSubmenu = false;
            var buttonBack = allElements.find(el => {
                if (el.offsetParent === null) return false;
                var t = el.innerText.trim().toLowerCase();
                return t === 'back' || t === 'atrás' || t === 'settings';
            });

            if (buttonBack) {
                isInsideSubmenu = true;
            }

            // Mapear lo que veamos en pantalla si hay elementos de servidores
            var possibleServers = allElements.filter(el => {
                if (el.offsetParent === null) return false;
                var t = el.innerText.trim().toLowerCase();
                if (t.length === 0 || t.length > 60) return false;
                
                // Evitar botones estructurales
                if (t === 'back' || t === 'atrás' || t === 'settings' || t === 'quality' || t === 'subs' || t === 'speed' || t === 'servers') return false;

                // Las palabras que reportó el usuario
                var isKnownServer = ['neon', 'yoru', 'cypher', 'sage', 'jett', 'reyna', 'gekko', 'latino', 'castellano', 'english', 'español', 'spanish', 'audio', 'original'].some(k => t.includes(k));
                var hasFlag = el.querySelector('img[src*="flagsapi"]') || el.querySelector('img[src*="imgur.com"]');
                
                return isInsideSubmenu || isKnownServer || hasFlag; 
            });

            if (possibleServers.length > 0) {
               console.log("✅ Mapeando lista de servidores (" + possibleServers.length + " encontrados)");
               var results = [];
               possibleServers.forEach(function(el) {
                  var img = el.querySelector('img') || (el.tagName === 'IMG' ? el : null);
                  var text = el.innerText.trim() || el.title || el.alt;
                  var lang = "";
                  var content = text.toLowerCase();
                  
                  if (content.includes('latino') || content.includes('spanish audio')) lang = "Español";
                  else if (content.includes('castellano')) lang = "Castellano";
                  else if (content.includes('español') || content.includes('spanish')) lang = "Español";
                  else if (content.includes('english') || content.includes('original audio') || content.includes('original')) lang = "English";

                  text = text.split('\n')[0].trim();
                  if (text) {
                     results.push({ id: text, label: text, flagUrl: img ? img.src : '', language: lang });
                  }
               });

               var uniqueResults = results.filter((v, i, a) => a.findIndex(t => t.label === v.label) === i);
               if (uniqueResults.length > 0) {
                 window.flutter_inappwebview.callHandler('onServersFound', uniqueResults);
               }
               return; 
            }

            // 3. Si no hay nada abierto, abrimos la nube
            var allSvgs = Array.from(document.querySelectorAll('svg'));
            var configIcon = allSvgs.find(s => s.innerHTML.includes('M19.43 12.98') || s.innerHTML.includes('M12 15.5') || s.innerHTML.includes('M12 2C6.48 2'));
            if (configIcon) {
               var btn = configIcon.closest('button') || configIcon.parentElement;
               if (btn && btn.offsetParent !== null) {
                  console.log("🖱️ Abriendo el menú de configuración general (nube)...");
                  btn.click();
               }
            }
          })();"""

js_pattern = re.compile(r'evaluateJavascript\(source: """\n\s+\(function\(\) \{.*?\}\)\(\);', re.DOTALL)
content = js_pattern.sub(f'evaluateJavascript(source: """\n{v5_scraper_js}', content)

with open(path, 'w', encoding='utf-8') as f:
    f.write(content)
print("SCRAPER V5 APPLIED")
