import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import '../services/supabase_service.dart';

class UpdateService {
  static HeadlessInAppWebView? _headlessWebView;
  static const _installChannel = MethodChannel('com.luis.movieapp/install_apk');

  static Future<void> checkVersion(BuildContext context) async {
    try {
      final packageInfo = await PackageInfo.fromPlatform();
      final currentVersion = packageInfo.version;

      final response = await SupabaseService.client
          .from('app_config')
          .select()
          .limit(1)
          .maybeSingle();

      if (response == null) return;

      final latestVersion = response['latest_version'] as String?;
      final updateUrl = response['update_url'] as String?;

      if (latestVersion != null && latestVersion != currentVersion && updateUrl != null && updateUrl.isNotEmpty) {
        if (!context.mounted) return;
        _showUpdateDialog(context, latestVersion, updateUrl);
      }
    } catch (e) {
      print('Error checking update: $e');
    }
  }

  static void _showUpdateDialog(BuildContext context, String version, String url) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => WillPopScope(
        onWillPop: () async => false,
        child: AlertDialog(
          backgroundColor: const Color(0xFF1A1A1A),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20), side: const BorderSide(color: Color(0xFF00A3FF), width: 0.5)),
          title: const Text('Actualización Disponible', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Se ha detectado una nueva versión: $version', style: const TextStyle(color: Colors.white70)),
              const SizedBox(height: 15),
              const Text('Es obligatorio actualizar para seguir usando K7 MOVIE con todas las funciones.', style: TextStyle(color: Colors.white54, fontSize: 13)),
            ],
          ),
          actions: [
            Padding(
              padding: const EdgeInsets.all(9.0),
              child: SizedBox(
                width: double.infinity,
                height: 80,
                child: ElevatedButton(
                  onPressed: () => _doUpdate(context, url),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF00A3FF),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  child: const Text('DESCARGAR E INSTALAR', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static void _doUpdate(BuildContext context, String url) async {
    Navigator.pop(context);

    final progressNotifier = ValueNotifier<double>(0.0);
    final statusNotifier = ValueNotifier<String>('Conectando con el servidor...');

    _showProgressDialog(context, progressNotifier, statusNotifier);

    String? apkPath;
    int retryCount = 0;

    while (apkPath == null) {
      try {
        if (retryCount > 0) {
          statusNotifier.value = 'Reintentando descarga (Intento $retryCount)...';
          await Future.delayed(const Duration(seconds: 3));
        }

        // PASO 1: Usar HeadlessWebView SOLO para resolver la URL directa de MediaFire
        final directUrl = await _resolveMediaFireUrl(url, statusNotifier);

        if (directUrl == null || directUrl.isEmpty) {
          statusNotifier.value = 'No se pudo obtener el enlace. Reintentando...';
          retryCount++;
          continue;
        }

        print('✅ [UPDATE] URL directa resuelta: $directUrl');
        statusNotifier.value = 'Iniciando descarga...';

        // PASO 2: Descargar con http directamente en Dart
        apkPath = await _downloadApkWithProgress(directUrl, progressNotifier, statusNotifier);

        if (apkPath == null) {
          statusNotifier.value = 'Fallo en descarga. Reintentando en breve...';
          retryCount++;
          // Pequeño delay adicional antes de reintentar el loop
          await Future.delayed(const Duration(seconds: 2));
        }
      } catch (e) {
        print('❌ [UPDATE] Error en bucle de reintento: $e');
        retryCount++;
        statusNotifier.value = 'Error de red. Reintentando...';
        await Future.delayed(const Duration(seconds: 4));
      }
    }

    // PASO 3: Instalar con el canal nativo (FileProvider)
    print('✅ [UPDATE] APK listo en: $apkPath. Abriendo instalador...');
    statusNotifier.value = '¡Descarga completa! Abriendo instalador...';
    
    await Future.delayed(const Duration(milliseconds: 500));
    try {
      final success = await _installChannel.invokeMethod<bool>('installApk', {
        'filePath': apkPath,
      });
      print('📢 [UPDATE] Resultado nativo: $success');
      statusNotifier.value = 'Instalador de Android abierto. Sigue las instrucciones.';
    } on PlatformException catch (e) {
      print('❌ [UPDATE] Error nativo: ${e.code} - ${e.message}');
      statusNotifier.value = 'Error al abrir instalador: ${e.message}';
    }
  }

  /// Usa HeadlessInAppWebView para resolver el redirect de MediaFire y obtener la URL directa del APK.
  static Future<String?> _resolveMediaFireUrl(String mediafireUrl, ValueNotifier<String> statusNotifier) async {
    _headlessWebView?.dispose();
    _headlessWebView = null;

    final result = await Future<String?>(() async {
      final resolved = Completer<String?>();

      _headlessWebView = HeadlessInAppWebView(
        initialUrlRequest: URLRequest(url: WebUri(mediafireUrl)),
        initialSettings: InAppWebViewSettings(
          javaScriptEnabled: true,
          useOnDownloadStart: true,
          domStorageEnabled: true,
          userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
        ),
        onDownloadStartRequest: (controller, downloadRequest) async {
          final url = downloadRequest.url.toString();
          print('🌐 [UPDATE] URL directa capturada: $url');
          if (!resolved.isCompleted) resolved.complete(url);
          _headlessWebView?.dispose();
          _headlessWebView = null;
        },
        onLoadStop: (controller, url) async {
          statusNotifier.value = 'Analizando enlace de descarga...';
          await Future.delayed(const Duration(seconds: 3));
          const jsTrigger = '''
            (function() {
               function findByText(text, selector) {
                 const items = document.querySelectorAll(selector || '*');
                 for(let i=0; i<items.length; i++) {
                   let t = items[i].textContent.trim().toUpperCase();
                   if(t === text.toUpperCase() || t.includes(text.toUpperCase())) return items[i];
                 }
                 return null;
               }
               const btn = document.querySelector('#downloadButton') 
                        || document.querySelector('.download_link')
                        || findByText('Download', 'a, div, button');
               if (btn) { btn.click(); return "CLICKED"; }
               return "NOT_FOUND";
            })();
          ''';
          final clickResult = await controller.evaluateJavascript(source: jsTrigger);
          print('🖱️ [UPDATE] JS click result: $clickResult');
        },
      );

      await _headlessWebView!.run();

      // Timeout de 30 segundos para resolver
      final timeoutFuture = Future.delayed(const Duration(seconds: 30), () => null as String?);
      return await Future.any([resolved.future, timeoutFuture]);
    });

    return result;
  }

  /// Descarga el APK usando http con seguimiento de progreso en Dart puro.
  static Future<String?> _downloadApkWithProgress(
    String url,
    ValueNotifier<double> progressNotifier,
    ValueNotifier<String> statusNotifier,
  ) async {
    try {
      final dir = await getApplicationSupportDirectory();
      final updatesDir = Directory('${dir.path}/updates');
      await updatesDir.create(recursive: true);
      final apkFile = File('${updatesDir.path}/k7movie_update.apk');

      // Borrar APK anterior si existe
      if (await apkFile.exists()) {
        await apkFile.delete();
        print('🗑️ [UPDATE] APK anterior eliminado.');
      }

      final client = http.Client();
      try {
        final request = http.Request('GET', Uri.parse(url));
        final response = await client.send(request);

        if (response.statusCode != 200) {
          statusNotifier.value = 'Error HTTP: ${response.statusCode}';
          return null;
        }

        final totalBytes = response.contentLength ?? 0;
        int downloadedBytes = 0;
        final sink = apkFile.openWrite();

        await for (final chunk in response.stream) {
          sink.add(chunk);
          downloadedBytes += chunk.length;
          if (totalBytes > 0) {
            final progress = downloadedBytes / totalBytes;
            progressNotifier.value = progress;
            statusNotifier.value = 'Descargando: ${(progress * 100).toInt()}% (${_formatBytes(downloadedBytes)} / ${_formatBytes(totalBytes)})';
          } else {
            statusNotifier.value = 'Descargando: ${_formatBytes(downloadedBytes)}...';
          }
        }

        await sink.flush();
        await sink.close();
        progressNotifier.value = 1.0;

        print('✅ [UPDATE] Descarga completada: ${await apkFile.length()} bytes');
        return apkFile.path;
      } finally {
        client.close();
      }
    } catch (e) {
      print('❌ [UPDATE] Error de descarga: $e');
      statusNotifier.value = 'Error de descarga: $e';
      return null;
    }
  }

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  static void _showProgressDialog(BuildContext context, ValueNotifier<double> progress, ValueNotifier<String> status) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => WillPopScope(
        onWillPop: () async => false,
        child: AlertDialog(
          backgroundColor: const Color(0xFF0A0A0B),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: const BorderSide(color: Color(0xFF00A3FF), width: 0.5)
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.all(15),
                decoration: BoxDecoration(
                  color: const Color(0xFF00A3FF).withOpacity(0.1),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.system_update, color: Color(0xFF00A3FF), size: 40),
              ),
              const SizedBox(height: 25),
              ValueListenableBuilder<String>(
                valueListenable: status,
                builder: (context, val, _) {
                  return Text(
                    val,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                  );
                },
              ),
              const SizedBox(height: 25),
              ValueListenableBuilder<double>(
                valueListenable: progress,
                builder: (context, val, _) {
                  return Column(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: LinearProgressIndicator(
                          value: val > 0 ? val : null,
                          backgroundColor: Colors.white10,
                          color: const Color(0xFF00A3FF),
                          minHeight: 10,
                        ),
                      ),
                      if (val > 0) ...[
                        const SizedBox(height: 10),
                        Text('${(val * 100).toInt()}%', style: const TextStyle(color: Color(0xFF00A3FF), fontWeight: FontWeight.bold, fontSize: 12)),
                      ]
                    ],
                  );
                },
              ),
              const SizedBox(height: 20),
              const Text(
                'No cierres la aplicación hasta completar el proceso.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white38, fontSize: 11),
              ),
              const SizedBox(height: 10),
            ],
          ),
          actions: [
            ValueListenableBuilder<double>(
              valueListenable: progress,
              builder: (context, val, _) {
                if (val >= 1.0 || status.value.contains('Error') || status.value.contains('instalador') || status.value.contains('Instalador')) {
                  return TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('CERRAR', style: TextStyle(color: Color(0xFF00A3FF))),
                  );
                }
                return const SizedBox.shrink();
              }
            )
          ],
        ),
      ),
    );
  }
}
