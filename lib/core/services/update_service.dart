import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

class UpdateInfo {
  final String latestVersion;
  final String downloadUrl;
  final String releaseNotes;
  final bool hasUpdate;

  UpdateInfo({
    required this.latestVersion,
    required this.downloadUrl,
    required this.releaseNotes,
    required this.hasUpdate,
  });
}

class UpdateService {
  static const String _owner = 'wishoislas619-svg';
  static const String _repo = 'k7-movie-app';
  static const String _apiUrl = 'https://api.github.com/repos/$_owner/$_repo/releases/latest';

  static Future<UpdateInfo?> checkForUpdates() async {
    try {
      final response = await http.get(Uri.parse(_apiUrl));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final latestTag = data['tag_name'].toString().replaceAll('v', '');
        final downloadUrl = data['html_url'];
        final body = data['body'] ?? '';

        final packageInfo = await PackageInfo.fromPlatform();
        final currentVersion = packageInfo.version;

        bool hasUpdate = _isVersionGreater(latestTag, currentVersion);

        return UpdateInfo(
          latestVersion: latestTag,
          downloadUrl: downloadUrl,
          releaseNotes: body,
          hasUpdate: hasUpdate,
        );
      }
    } catch (e) {
      debugPrint('❌ [UPDATE_SERVICE] Error checking updates: $e');
    }
    return null;
  }

  static bool _isVersionGreater(String latest, String current) {
    List<int> latestParts = latest.split('.').map(int.parse).toList();
    List<int> currentParts = current.split('.').map(int.parse).toList();

    for (int i = 0; i < latestParts.length && i < currentParts.length; i++) {
      if (latestParts[i] > currentParts[i]) return true;
      if (latestParts[i] < currentParts[i]) return false;
    }
    return latestParts.length > currentParts.length;
  }

  static void showUpdateDialog(BuildContext context, UpdateInfo info) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF0D0D0D),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20), side: const BorderSide(color: Color(0xFF00A3FF), width: 1)),
        title: Row(
          children: [
            const Icon(Icons.system_update, color: Color(0xFF00A3FF)),
            const SizedBox(width: 10),
            const Text('Nueva Versión', style: TextStyle(color: Colors.white)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('¡La versión ${info.latestVersion} ya está disponible!', 
              style: const TextStyle(color: Colors.white70, fontWeight: FontWeight.bold)),
            const SizedBox(height: 10),
            if (info.releaseNotes.isNotEmpty) ...[
              const Text('Novedades:', style: TextStyle(color: Colors.white54, fontSize: 12)),
              const SizedBox(height: 5),
              Text(info.releaseNotes, style: const TextStyle(color: Colors.white38, fontSize: 12)),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('MÁS TARDE', style: TextStyle(color: Colors.white38)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF00A3FF),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            onPressed: () async {
              final url = Uri.parse(info.downloadUrl);
              if (await canLaunchUrl(url)) {
                await launchUrl(url, mode: LaunchMode.externalApplication);
              }
            },
            child: const Text('ACTUALIZAR AHORA', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }
}
