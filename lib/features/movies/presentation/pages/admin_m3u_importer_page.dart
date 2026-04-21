import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:http/http.dart' as http;
import '../../../../core/services/supabase_service.dart';

class RawM3uItem {
  final String title;
  final String url;
  final String? groupTitle;
  final String? logo; // tvg-logo

  RawM3uItem({
    required this.title,
    required this.url,
    this.groupTitle,
    this.logo,
  });
}

class AdminM3uImporterPage extends StatefulWidget {
  const AdminM3uImporterPage({super.key});

  @override
  State<AdminM3uImporterPage> createState() => _AdminM3uImporterPageState();
}

class _AdminM3uImporterPageState extends State<AdminM3uImporterPage> {
  final TextEditingController _urlController = TextEditingController();
  List<RawM3uItem> _importedItems = [];
  bool _isLoading = false;

  void _parseM3uText(String content) {
    List<RawM3uItem> results = [];
    final lines = content.split('\n');
    
    String? currentTitle;
    String? currentGroup;
    String? currentLogo;
    
    for (int i = 0; i < lines.length; i++) {
        String line = lines[i].trim();
        if (line.isEmpty) continue;
        
        if (line.startsWith('#EXTINF:')) {
            // Extract group-title
            final groupMatch = RegExp(r'group-title="([^"]*)"').firstMatch(line);
            currentGroup = groupMatch?.group(1);
            
            // Extract tvg-logo
            final logoMatch = RegExp(r'tvg-logo="([^"]*)"').firstMatch(line);
            currentLogo = logoMatch?.group(1);
            
            // Extract Title (text after the last comma)
            final commaSplit = line.split(',');
            if (commaSplit.length > 1) {
               currentTitle = commaSplit.last.trim();
            } else {
               currentTitle = 'Unknown Title';
            }
        } else if (!line.startsWith('#')) {
            // It's a URL
            if (currentTitle != null) {
               results.add(RawM3uItem(
                  title: currentTitle,
                  url: line,
                  groupTitle: currentGroup,
                  logo: currentLogo,
               ));
               // Reset for next item
               currentTitle = null;
               currentGroup = null;
               currentLogo = null;
            }
        }
    }
    
    setState(() {
       _importedItems = results;
       _isLoading = false;
    });
    
    ScaffoldMessenger.of(context).showSnackBar(
       SnackBar(content: Text('¡Se importaron \${results.length} elementos M3U!')),
    );
  }

  Future<void> _importFromUrl() async {
     final url = _urlController.text.trim();
     if (url.isEmpty) return;
     
     setState(() => _isLoading = true);
     try {
       final response = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 30));
       if (response.statusCode == 200) {
          _parseM3uText(response.body);
       } else {
          throw Exception('Status code: \${response.statusCode}');
       }
     } catch (e) {
        setState(() => _isLoading = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error descargando M3U: \$e'), backgroundColor: Colors.red));
     }
  }

  Future<void> _importFromFile() async {
    try {
      FilePickerResult? result = await FilePicker.pickFiles(
        type: FileType.any,
        allowMultiple: false,
      );

      if (result != null && result.files.single.path != null) {
        setState(() => _isLoading = true);
        File file = File(result.files.single.path!);
        String content = await file.readAsString();
        _parseM3uText(content);
      }
    } catch (e) {
        setState(() => _isLoading = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error leyendo archivo: \$e'), backgroundColor: Colors.red));
    }
  }

  Future<void> _saveAllToDatabase() async {
     if (_importedItems.isEmpty) return;
     
     setState(() => _isLoading = true);
     int count = 0;
     try {
       // Opcional: Se recomienda que el admin cree la tabla "tv_channels" con [id, name, logo_url, stream_url, group_name] en su Supabase.
       for (var item in _importedItems) {
         await SupabaseService.client.from('tv_channels').insert({
            'name': item.title,
            'logo_url': item.logo ?? '',
            'stream_url': item.url,
            'group_name': item.groupTitle ?? 'General',
         });
         count++;
       }
       if (mounted) {
         ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('¡ÉXITO! Se guardaron \$count canales en TV VIVO.', style: const TextStyle(fontWeight: FontWeight.bold))));
       }
       setState(() => _importedItems.clear());
     } catch (e) {
       if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
             content: Text('Error al guardar: \$e. Asegurate de tener creada la tabla "tv_channels" en Supabase.'), 
             backgroundColor: Colors.redAccent, 
             duration: const Duration(seconds: 5)
          ));
       }
     } finally {
       if (mounted) setState(() => _isLoading = false);
     }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
         title: const Text('IMPORTADOR MASIVO M3U', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
         backgroundColor: const Color(0xFF0A0A0A),
      ),
      body: Column(
         children: [
            Padding(
               padding: const EdgeInsets.all(16.0),
               child: Column(
                  children: [
                     const Text('Sube un listado M3U para procesar cientos de Canales, Películas o Series en segundos. (Formatos: .m3u, .txt)', style: TextStyle(color: Colors.white54, fontSize: 13)),
                     const SizedBox(height: 16),
                     Row(
                        children: [
                           Expanded(
                              child: TextField(
                                 controller: _urlController,
                                 style: const TextStyle(color: Colors.white),
                                 decoration: InputDecoration(
                                    labelText: 'URL Directo (ej: http://.../list.m3u)',
                                    labelStyle: const TextStyle(color: Colors.white38),
                                    filled: true,
                                    fillColor: Colors.white.withOpacity(0.05),
                                    hintText: 'https://...',
                                    hintStyle: const TextStyle(color: Colors.white24),
                                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                                 ),
                              ),
                           ),
                           const SizedBox(width: 8),
                           ElevatedButton(
                              onPressed: _isLoading ? null : _importFromUrl,
                              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00A3FF), padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                              child: const Icon(Icons.cloud_download, color: Colors.white),
                           )
                        ],
                     ),
                     const SizedBox(height: 12),
                     const Row(
                        children: [
                           Expanded(child: Divider(color: Colors.white10)),
                           Padding(padding: EdgeInsets.symmetric(horizontal: 8), child: Text('O', style: TextStyle(color: Colors.white38, fontWeight: FontWeight.bold))),
                           Expanded(child: Divider(color: Colors.white10)),
                        ]
                     ),
                     const SizedBox(height: 12),
                     SizedBox(
                        width: double.infinity,
                        height: 50,
                        child: OutlinedButton.icon(
                           onPressed: _isLoading ? null : _importFromFile,
                           icon: const Icon(Icons.folder_open, color: Color(0xFFD400FF)),
                           label: const Text('SUBIR ARCHIVO LOCAL (.m3u)', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                           style: OutlinedButton.styleFrom(
                              side: const BorderSide(color: Color(0xFFD400FF), width: 1.5),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))
                           ),
                        ),
                     )
                  ]
               )
            ),
            const Divider(color: Colors.white10),
            Expanded(
               child: _isLoading
                  ? const Center(child: CircularProgressIndicator(color: Color(0xFF00A3FF)))
                  : _importedItems.isEmpty 
                    ? const Center(child: Text('Ningún archivo procesado.', style: TextStyle(color: Colors.white38)))
                    : ListView.builder(
                        itemCount: _importedItems.length,
                        itemBuilder: (context, index) {
                           final item = _importedItems[index];
                           return ListTile(
                              leading: item.logo != null && item.logo!.isNotEmpty
                                 ? Image.network(item.logo!, width: 40, height: 40, fit: BoxFit.cover, errorBuilder: (_,__,___) => const Icon(Icons.movie, color: Colors.white38))
                                 : const Icon(Icons.play_circle_fill, color: Color(0xFF00A3FF), size: 30),
                              title: Text(item.title, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 14)),
                              subtitle: Text("\${item.groupTitle ?? 'Sin Grupo'} • \${item.url}", style: const TextStyle(color: Colors.white54, fontSize: 11), maxLines: 1, overflow: TextOverflow.ellipsis),
                              trailing: IconButton(
                                 icon: const Icon(Icons.add_circle, color: Color(0xFFD400FF)),
                                 onPressed: () {
                                     // TODO: Logica de vinculación con Supabase / TMDB
                                     ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Proximamente: Vinculación con TMDB y Guardado.')));
                                 },
                              ),
                           );
                        }
                    )
            ),
            if (_importedItems.isNotEmpty)
               Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: SizedBox(
                     width: double.infinity,
                     height: 55,
                     child: ElevatedButton.icon(
                        onPressed: _isLoading ? null : _saveAllToDatabase,
                        icon: const Icon(Icons.auto_awesome, color: Colors.white),
                        label: Text('GUARDAR TODO (\${_importedItems.length}) EN BASE DE DATOS', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                        style: ElevatedButton.styleFrom(
                           backgroundColor: const Color(0xFF00A3FF),
                           shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))
                        ),
                     )
                  )
               )
         ]
      ),
    );
  }
}
