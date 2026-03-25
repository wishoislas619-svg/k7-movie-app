import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:background_downloader/background_downloader.dart';
import '../services/supabase_service.dart';

class UpdateService {
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
              padding: const EdgeInsets.all(8.0),
              child: SizedBox(
                width: double.infinity,
                height: 45,
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
    try {
      Navigator.pop(context); // Close dialog
      
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Iniciando descarga de la nueva versión...'), duration: Duration(seconds: 5)),
      );

      final task = DownloadTask(
        url: url,
        filename: 'k7movie_update.apk',
        directory: 'updates',
        updates: Updates.statusAndProgress,
        baseDirectory: BaseDirectory.temporary,
        displayName: 'Actualización K7 MOVIE',
      );

      final result = await FileDownloader().download(task);
      
      if (result.status == TaskStatus.complete) {
        // Try to open/install
        await FileDownloader().openFile(task: task);
      } else {
        if (context.mounted) {
           ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Error al descargar la actualización.')),
          );
        }
      }
    } catch (e) {
      print('Update Error: $e');
    }
  }
}
