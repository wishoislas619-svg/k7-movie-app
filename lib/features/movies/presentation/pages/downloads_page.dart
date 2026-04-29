
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:storage_space/storage_space.dart';
import 'package:movie_app/features/movies/data/repositories/download_repository_impl.dart';
import 'package:movie_app/features/movies/domain/entities/download_task.dart';
import 'package:movie_app/features/movies/domain/entities/movie.dart';
import 'package:movie_app/features/player/presentation/pages/video_player_page.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:movie_app/core/constants/app_constants.dart';
import 'package:path_provider/path_provider.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

String _formatSize(int bytes) {
  if (bytes <= 0) return "0 B";
  const suffixes = ["B", "KB", "MB", "GB", "TB"];
  var i = (math.log(bytes) / math.log(1024)).floor();
  return ((bytes / math.pow(1024, i)).toStringAsFixed(1)) + ' ' + suffixes[i];
}

class DownloadsPage extends ConsumerStatefulWidget {
  const DownloadsPage({super.key});

  @override
  ConsumerState<DownloadsPage> createState() => _DownloadsPageState();
}

class _DownloadsPageState extends ConsumerState<DownloadsPage> {
  @override
  void initState() {
    super.initState();
    _requestPermissions();
    WakelockPlus.enable();
  }

  @override
  void dispose() {
    WakelockPlus.disable();
    super.dispose();
  }

  Future<void> _requestPermissions() async {
    if (Platform.isAndroid) {
      final androidInfo = await DeviceInfoPlugin().androidInfo;
      if (androidInfo.version.sdkInt >= 33) {
        if (await Permission.videos.isDenied) {
          await Permission.videos.request();
        }
      } else {
        if (await Permission.storage.isDenied) {
          await Permission.storage.request();
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final downloads = ref.watch(downloadsListProvider);
    final movieDownloads = downloads.where((d) => !d.isSeries).toList();
    final seriesDownloads = downloads.where((d) => d.isSeries).toList();

    return DefaultTabController(
      length: 3,
      child: Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          title: const Text('MIS DESCARGAS', style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1.5)),
          bottom: const TabBar(
            indicatorColor: Color(0xFF00A3FF),
            labelColor: Colors.white,
            unselectedLabelColor: Colors.white54,
            isScrollable: false,
            tabs: [
              Tab(text: 'Películas'),
              Tab(text: 'Series'),
              Tab(text: 'Local'),
            ],
          ),
          actions: [
            IconButton(
              icon: const Icon(Icons.refresh, color: Colors.white70),
              onPressed: () => ref.refresh(downloadsListProvider),
            ),
            IconButton(
              icon: const Icon(Icons.delete_sweep, color: Colors.redAccent),
              onPressed: downloads.any((d) => d.status == DownloadStatus.error)
                  ? () async {
                      final ok = await showDialog<bool>(
                        context: context,
                        builder: (ctx) => AlertDialog(
                          backgroundColor: const Color(0xFF1E1E1E),
                          title: const Text('Limpiar errores', style: TextStyle(color: Colors.white)),
                          content: const Text(
                            'Se eliminarán las descargas con error y cualquier archivo residual.',
                            style: TextStyle(color: Colors.white70),
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(ctx, false),
                              child: const Text('Cancelar', style: TextStyle(color: Colors.white54)),
                            ),
                            TextButton(
                              onPressed: () => Navigator.pop(ctx, true),
                              child: const Text('Eliminar', style: TextStyle(color: Colors.redAccent)),
                            ),
                          ],
                        ),
                      );
                      if (ok == true) {
                        await ref.read(downloadsListProvider.notifier).clearFailedDownloads();
                      }
                    }
                  : null,
            ),
          ],
        ),
        body: Column(
          children: [
            // Guía de descarga
            Container(
              width: double.infinity,
              margin: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    const Color(0xFF00A3FF).withOpacity(0.12),
                    const Color(0xFFD400FF).withOpacity(0.12),
                  ],
                ),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFF00A3FF).withOpacity(0.3)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.info_outline, color: Color(0xFF00A3FF), size: 18),
                  const SizedBox(width: 10),
                  Expanded(
                    child: RichText(
                      text: const TextSpan(
                        style: TextStyle(color: Colors.white70, fontSize: 12.5, height: 1.5),
                        children: [
                          TextSpan(text: '¿Cómo descargar? ', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                          TextSpan(text: 'Entra a una '),
                          TextSpan(text: 'película o episodio', style: TextStyle(color: Color(0xFF00A3FF), fontWeight: FontWeight.w600)),
                          TextSpan(text: ', abre el reproductor y presiona el icono '),
                          TextSpan(text: '⬇ Descargar', style: TextStyle(color: Color(0xFFD400FF), fontWeight: FontWeight.w600)),
                          TextSpan(text: ' en el enlace de tu preferencia. '),
                          TextSpan(text: '(De preferencia HLS)', style: TextStyle(color: Colors.orangeAccent, fontWeight: FontWeight.bold)),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: TabBarView(
                physics: const NeverScrollableScrollPhysics(),
                children: [
                  _buildList(movieDownloads, context, ref),
                  _buildSeriesMapList(seriesDownloads, context, ref),
                  const _LocalFilesView(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildList(List<DownloadTask> tasks, BuildContext context, WidgetRef ref) {
    if (tasks.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
             Icon(Icons.download_for_offline_outlined, size: 80, color: Colors.grey[800]),
             const SizedBox(height: 16),
             const Text("No tienes descargas aún", style: TextStyle(color: Colors.grey, fontSize: 18)),
          ],
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: tasks.length,
      itemBuilder: (context, index) {
        return _buildDownloadItem(context, ref, tasks[index]);
      },
    );
  }

  Widget _buildSeriesMapList(List<DownloadTask> tasks, BuildContext context, WidgetRef ref) {
    if (tasks.isEmpty) return _buildList(tasks, context, ref);

    final seriesMap = <String, Map<int, List<DownloadTask>>>{};
    for(var t in tasks) {
        final parts = t.movieName.split(' - S');
        final seriesName = parts.isNotEmpty ? parts[0] : t.movieName;
        if(!seriesMap.containsKey(seriesName)) seriesMap[seriesName] = {};
        final seasonNum = t.seasonNumber ?? 1;
        if(!seriesMap[seriesName]!.containsKey(seasonNum)) seriesMap[seriesName]![seasonNum] = [];
        seriesMap[seriesName]![seasonNum]!.add(t);
    }

    final sortedSeriesNames = seriesMap.keys.toList()..sort();
    final groupedTasks = <dynamic>[];
    for(var name in sortedSeriesNames) {
       final seasonMap = seriesMap[name]!;
       final sortedSeasons = seasonMap.keys.toList()..sort();
       for(var sNum in sortedSeasons) {
           groupedTasks.add('$name - Temporada $sNum');
           final epTasks = seasonMap[sNum]!;
           epTasks.sort((a,b) => (a.episodeNumber ?? 0).compareTo(b.episodeNumber ?? 0));
           groupedTasks.addAll(epTasks);
       }
    }

    return ListView.builder(
       padding: const EdgeInsets.all(16),
       itemCount: groupedTasks.length,
       itemBuilder: (context, index) {
          final item = groupedTasks[index];
          if(item is String) {
              return Padding(
                 padding: const EdgeInsets.only(top: 16.0, bottom: 8.0, left: 4.0),
                 child: Text(item, style: const TextStyle(color: Color(0xFF00A3FF), fontWeight: FontWeight.bold, fontSize: 18)),
              );
          } else {
             final DownloadTask task = item;
             return _buildDownloadItem(context, ref, task.copyWith(movieName: 'Episodio ${task.episodeNumber ?? 1}'));
          }
       }
    );
  }

  Widget _buildDownloadItem(BuildContext context, WidgetRef ref, DownloadTask task) {
    final isConverting = (task.speed ?? '').contains('Convirtiendo');
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E1E),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withOpacity(0.05)),
      ),
      child: Row(
        children: [
          // Poster
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.network(
              task.imagePath,
              width: 60,
              height: 90,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => Container(color: Colors.white10, width: 60, height: 90, child: const Icon(Icons.movie, color: Colors.white24)),
            ),
          ),
          const SizedBox(width: 16),
          // Info
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  task.movieName,
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Builder(
                  builder: (context) {
                    String label = task.resolution.contains('Resolución Auto (HLS)') 
                        ? 'HLS Adaptive' 
                        : task.resolution;
                    
                    if (task.status == DownloadStatus.completed && task.savePath != null) {
                      try {
                        final path = task.savePath!;
                        final file = File(path);
                        if (file.existsSync()) {
                          label += " • ${_formatSize(file.lengthSync())}";
                        } else {
                          // Probar si es carpeta HLS
                          final dir = Directory(path);
                          if (dir.existsSync()) {
                             int totalSize = 0;
                             dir.listSync().forEach((f) {
                               if (f is File) totalSize += f.lengthSync();
                             });
                             label += " • ${_formatSize(totalSize)}";
                          }
                        }
                      } catch(_) {}
                    }

                    return Text(
                      label,
                      style: const TextStyle(color: Color(0xFF00A3FF), fontSize: 12, fontWeight: FontWeight.bold),
                    );
                  }
                ),
                const SizedBox(height: 8),
                // Progress Bar
                if (task.status == DownloadStatus.downloading)
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (isConverting)
                        const Padding(
                          padding: EdgeInsets.only(bottom: 6),
                          child: Text(
                            'Convirtiendo...',
                            style: TextStyle(color: Colors.orangeAccent, fontSize: 12, fontWeight: FontWeight.w600),
                          ),
                        ),
                       ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: LinearProgressIndicator(
                          value: isConverting ? null : task.progress,
                          backgroundColor: Colors.white12,
                          color: const Color(0xFFD400FF),
                          minHeight: 6,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          if (!isConverting)
                            Text(
                              "${(task.progress * 100).toInt()}%",
                              style: const TextStyle(color: Colors.white54, fontSize: 10),
                            )
                          else
                            const SizedBox.shrink(),
                          Text(
                            task.speed ?? "0 KB/s",
                            style: const TextStyle(color: Color(0xFF00A3FF), fontSize: 10, fontWeight: FontWeight.bold),
                          ),
                        ],
                      ),
                    ],
                  )
                else
                  Text(
                    _getStatusText(task.status),
                    style: TextStyle(
                      color: _getStatusColor(task.status),
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
              ],
            ),
          ),
          // Actions
          _buildActions(context, ref, task),
        ],
      ),
    );
  }

  Widget _buildActions(BuildContext context, WidgetRef ref, DownloadTask task) {
    if (task.status == DownloadStatus.downloading) {
      return IconButton(
        icon: const Icon(Icons.pause_circle_filled, color: Colors.white70, size: 30),
        onPressed: () => ref.read(downloadsListProvider.notifier).pauseDownload(task.id),
      );
    } else if (task.status == DownloadStatus.paused) {
      return IconButton(
        icon: const Icon(Icons.play_circle_filled, color: Color(0xFF00A3FF), size: 30),
        onPressed: () => ref.read(downloadsListProvider.notifier).resumeDownload(task.id),
      );
    } else if (task.status == DownloadStatus.error) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Icons.play_circle_filled, color: Color(0xFF00A3FF), size: 30),
            onPressed: () => ref.read(downloadsListProvider.notifier).resumeDownload(task.id),
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline, color: Colors.redAccent, size: 24),
            onPressed: () => ref.read(downloadsListProvider.notifier).deleteDownload(task.id),
          ),
        ],
      );
    } else if (task.status == DownloadStatus.completed) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Icons.play_circle_fill, color: Colors.greenAccent, size: 30),
            onPressed: () async {
              final messenger = ScaffoldMessenger.of(context);
              print('[PLAY] Tap: id=${task.id} name=${task.movieName} savePath=${task.savePath}');
              messenger.showSnackBar(
                const SnackBar(content: Text('Verificando formato...')),
              );

              final path = await ref.read(downloadsListProvider.notifier).ensurePlayableFile(task.id);
              if (path == null) {
                print('[PLAY] Failed: id=${task.id}');
                messenger.showSnackBar(
                  const SnackBar(content: Text('No se encontró el archivo o no se pudo convertir.')),
                );
                return;
              }
              print('[PLAY] Using path: $path');

              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => VideoPlayerPage(
                    movieName: task.movieName,
                    isLocal: true,
                    mediaId: task.movieId,
                    mediaType: task.isSeries ? 'series' : 'movie',
                    imagePath: task.imagePath,
                    subtitleLabel: task.isSeries ? 'S${task.seasonNumber} E${task.episodeNumber}' : null,
                    videoOptions: [
                      VideoOption(
                        id: 'local',
                        movieId: task.movieId,
                        serverImagePath: '',
                        resolution: 'Local',
                        videoUrl: path,
                      )
                    ],
                  ),
                ),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline, color: Colors.redAccent, size: 24),
            onPressed: () => ref.read(downloadsListProvider.notifier).deleteDownload(task.id),
          ),
        ],
      );
    }
    return const SizedBox.shrink();
  }

  String _getStatusText(DownloadStatus status) {
    switch (status) {
      case DownloadStatus.completed: return "Completado";
      case DownloadStatus.error: return "Error";
      case DownloadStatus.paused: return "Pausado";
      case DownloadStatus.pending: return "Pendiente";
      default: return "";
    }
  }

  Color _getStatusColor(DownloadStatus status) {
    switch (status) {
      case DownloadStatus.completed: return Colors.greenAccent;
      case DownloadStatus.error: return Colors.redAccent;
      case DownloadStatus.paused: return Colors.orangeAccent;
      default: return Colors.white38;
    }
  }
}

class _LocalFilesView extends StatefulWidget {
  const _LocalFilesView();

  @override
  State<_LocalFilesView> createState() => _LocalFilesViewState();
}

class _LocalFilesViewState extends State<_LocalFilesView> {
  List<Map<String, dynamic>> _filesData = [];
  bool _isLoading = true;
  StorageSpace? _storageSpace;

  @override
  void initState() {
    super.initState();
    _handleRefresh();
  }

  Future<void> _handleRefresh() async {
    await _requestPermissions();
    await _scanFiles();
  }

  Future<void> _requestPermissions() async {
    if (Platform.isAndroid) {
      final androidInfo = await DeviceInfoPlugin().androidInfo;
      if (androidInfo.version.sdkInt >= 33) {
        if (await Permission.videos.isDenied) {
          await Permission.videos.request();
        }
      } else {
        if (await Permission.storage.isDenied) {
          await Permission.storage.request();
        }
      }
    }
  }



  Future<void> _scanFiles() async {
    setState(() => _isLoading = true);
    try {
      // 1. Obtener espacio en disco (Corregido para v1.2.0)
      _storageSpace = await getStorageSpace(
        lowOnSpaceThreshold: 512 * 1024 * 1024, // 512 MB
        fractionDigits: 1,
      );

      Directory dir;
      if (AppConstants.secureSave) {
        final appDocDir = await getApplicationDocumentsDirectory();
        dir = Directory('${appDocDir.path}/downloads');
      } else {
        dir = Directory('/storage/emulated/0/Download/K7-MOVIE');
      }

      if (await dir.exists()) {
// ... rest of logic stays same but ensured ...
        final entities = dir.listSync();
        final List<Map<String, dynamic>> data = [];

        for (var entity in entities) {
          final path = entity.path.toLowerCase();
          final isDir = entity is Directory;
          
          if (path.endsWith('.mp4') || 
              path.endsWith('.mkv') || 
              path.endsWith('.m3u8') ||
              (isDir && !path.split('/').last.startsWith('.'))) {
            
            final stat = entity.statSync();
            int size = 0;
            if (isDir) {
               // Para carpetas HLS sumamos el tamaño de los fragmentos
               try {
                 entity.listSync().forEach((f) {
                   if (f is File) size += f.lengthSync();
                 });
               } catch(_) {}
            } else if (entity is File) {
              size = entity.lengthSync();
            }

            data.add({
              'entity': entity,
              'name': entity.path.split('/').last,
              'isDirectory': isDir,
              'size': size,
              'date': stat.modified,
            });
          }
        }
        
        data.sort((a, b) => b['date'].compareTo(a['date'])); // Más recientes primero
        
        setState(() {
          _filesData = data;
          _isLoading = false;
        });
      } else {
        setState(() => _isLoading = false);
      }
    } catch (e) {
      print("[LOCAL_SCAN] Error: $e");
      setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator(color: Color(0xFF00A3FF)));
    }

    return Column(
      children: [
        // BARRA DE ALMACENAMIENTO
        if (_storageSpace != null)
          Container(
            padding: const EdgeInsets.all(16),
            margin: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFF1E1E1E),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.white.withOpacity(0.05)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text("Almacenamiento del dispositivo", style: TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.bold)),
                    Text("${_storageSpace!.freeSize}", style: const TextStyle(color: Colors.white70, fontSize: 11)),
                  ],
                ),
                const SizedBox(height: 10),
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: LinearProgressIndicator(
                    value: _storageSpace!.usageValue,
                    backgroundColor: Colors.white12,
                    color: _storageSpace!.usageValue > 0.9 ? Colors.redAccent : const Color(0xFF00A3FF),
                    minHeight: 8,
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text("Usado: ${_storageSpace!.usedSize}", style: const TextStyle(color: Colors.white38, fontSize: 11)),
                    Text("Libre: ${_storageSpace!.freeSize}", style: const TextStyle(color: Color(0xFF00A3FF), fontSize: 11, fontWeight: FontWeight.bold)),
                  ],
                ),
                const SizedBox(height: 12),
                if (Platform.isAndroid)
                  InkWell(
                    onTap: () async {
                      if (await Permission.manageExternalStorage.request().isGranted) {
                        _handleRefresh();
                      }
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
                      decoration: BoxDecoration(
                        color: const Color(0xFF00A3FF).withOpacity(0.1),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: const Color(0xFF00A3FF).withOpacity(0.3)),
                      ),
                      child: const Row(
                        children: [
                          Icon(Icons.security, color: Color(0xFF00A3FF), size: 14),
                          SizedBox(width: 8),
                          Text("Solicitar acceso total para borrar archivos", style: TextStyle(color: Color(0xFF00A3FF), fontSize: 10, fontWeight: FontWeight.bold)),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),

        Expanded(
          child: _filesData.isEmpty 
          ? _buildEmpty() 
          : RefreshIndicator(
            onRefresh: _handleRefresh,
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: _filesData.length,
              itemBuilder: (context, index) {
                final item = _filesData[index];
                final entity = item['entity'] as FileSystemEntity;
                final name = item['name'] as String;
                final isDirectory = item['isDirectory'] as bool;
                final sizeStr = _formatSize(item['size'] as int);
                final dateStr = DateFormat('dd/MM/yyyy HH:mm').format(item['date'] as DateTime);

                return Container(
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1E1E1E),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: ListTile(
                    leading: Icon(
                      isDirectory ? Icons.folder : Icons.movie_outlined,
                      color: isDirectory ? Colors.amber : const Color(0xFF00A3FF),
                    ),
                    title: Text(
                      name,
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w500, fontSize: 14),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text("$sizeStr • $dateStr", style: const TextStyle(color: Colors.white38, fontSize: 11)),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.play_circle_outline, color: Colors.greenAccent),
                          onPressed: () => _playFile(context, entity),
                        ),
                        PopupMenuButton<String>(
                          icon: const Icon(Icons.more_vert, color: Colors.white54),
                          onSelected: (value) {
                            if (value == 'rename') _renameFile(context, entity);
                            if (value == 'delete') _deleteFile(context, entity);
                          },
                          itemBuilder: (context) => [
                            const PopupMenuItem(
                              value: 'rename',
                              child: Row(
                                children: [
                                  Icon(Icons.edit, color: Colors.white70, size: 20),
                                  SizedBox(width: 8),
                                  Text("Renombrar", style: TextStyle(color: Colors.white)),
                                ],
                              ),
                            ),
                            const PopupMenuItem(
                              value: 'delete',
                              child: Row(
                                children: [
                                  Icon(Icons.delete_forever, color: Colors.redAccent, size: 20),
                                  SizedBox(width: 8),
                                  Text("Borrar", style: TextStyle(color: Colors.redAccent)),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                    onTap: () => _playFile(context, entity),
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }


  Widget _buildEmpty() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.folder_open, size: 80, color: Colors.grey[800]),
          const SizedBox(height: 16),
          const Text("Carpeta K7-MOVIE vacía", style: TextStyle(color: Colors.grey, fontSize: 16)),
          const SizedBox(height: 8),
          ElevatedButton.icon(
            onPressed: _handleRefresh,
            icon: const Icon(Icons.refresh),
            label: const Text("Refrescar"),
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF1E1E1E)),
          )
        ],
      ),
    );
  }

  Future<void> _renameFile(BuildContext context, FileSystemEntity file) async {
    final name = file.path.split('/').last;
    final controller = TextEditingController(text: name);

    final newName = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        title: const Text("Renombrar", style: TextStyle(color: Colors.white)),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(
            hintText: "Nuevo nombre",
            hintStyle: TextStyle(color: Colors.white38),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("Cancelar")),
          TextButton(onPressed: () => Navigator.pop(ctx, controller.text), child: const Text("Aceptar")),
        ],
      ),
    );

    if (newName != null && newName.isNotEmpty && newName != name) {
      try {
        final pathParts = file.path.split('/');
        pathParts.removeLast();
        final newPath = "${pathParts.join('/')}/$newName";
        await file.rename(newPath);
        _scanFiles();
      } catch (e) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Error al renombrar: $e")));
      }
    }
  }

  Future<void> _deleteFile(BuildContext context, FileSystemEntity file) async {
    final name = file.path.split('/').last;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        title: const Text("¿Borrar definitivamente?", style: TextStyle(color: Colors.white)),
        content: Text("Se eliminará '$name' para siempre.", style: const TextStyle(color: Colors.white70)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text("Cancelar")),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text("Borrar", style: TextStyle(color: Colors.redAccent))),
        ],
      ),
    );

    if (confirmed == true) {
      try {
        // Intento 1: Borrado directo (más rápido)
        if (await file.exists()) {
          await file.delete(recursive: true);
        } else {
          // Intento 2: Búsqueda manual por nombre (evita errores de codificación/acentos)
          final parent = file.parent;
          if (await parent.exists()) {
            final name = file.path.split('/').last;
            final entities = parent.listSync();
            FileSystemEntity? target;
            for (var e in entities) {
              if (e.path.split('/').last == name) {
                target = e;
                break;
              }
            }
            if (target != null) {
              await target.delete(recursive: true);
            } else {
              throw PathNotFoundException(file.path, const OSError("", 2), "Archivo no localizado físicamente");
            }
          } else {
            throw PathNotFoundException(file.path, const OSError("", 2), "Directorio raíz no disponible");
          }
        }
        _scanFiles();
      } catch (e) {
        print("[DELETE_LOCAL] Error: $e");
        String errorMsg = "Error al borrar: $e";
        
        bool isPermissionIssue = e.toString().contains("Permission denied") || e is PathNotFoundException;
        
        if (isPermissionIssue && Platform.isAndroid) {
          errorMsg = "Android bloqueó el borrado. Necesitas otorgar 'Acceso Total' para gestionar esta carpeta.";
          
          final status = await Permission.manageExternalStorage.status;
          if (!status.isGranted) {
             final request = await showDialog<bool>(
               context: context,
               builder: (ctx) => AlertDialog(
                 backgroundColor: const Color(0xFF1E1E1E),
                 title: const Text("Acceso denegado", style: TextStyle(color: Colors.white)),
                 content: const Text("Android requiere un permiso especial para borrar archivos en carpetas públicas. ¿Deseas otorgar acceso total?"),
                 actions: [
                   TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text("No, borraré manual")),
                   TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text("Dar acceso", style: TextStyle(color: Color(0xFF00A3FF)))),
                 ],
               ),
             );
             if (request == true) {
               await Permission.manageExternalStorage.request();
               return _deleteFile(context, file);
             }
          }
        }

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(errorMsg), backgroundColor: Colors.red),
        );
      }
    }
  }

  void _playFile(BuildContext context, FileSystemEntity entity) {
    String playPath = entity.path;
    
    // Si es un directorio, buscar un index.m3u8 o master.m3u8 adentro
    if (entity is Directory) {
      final m3u8 = File('${entity.path}/index.m3u8');
      final master = File('${entity.path}/master.m3u8');
      if (m3u8.existsSync()) {
        playPath = m3u8.path;
      } else if (master.existsSync()) {
        playPath = master.path;
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No se encontró un archivo reproducible en la carpeta')),
        );
        return;
      }
    }

    final name = entity.path.split('/').last;

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => VideoPlayerPage(
          movieName: name,
          isLocal: true,
          mediaId: 'local_${name.hashCode}',
          mediaType: 'movie',
          imagePath: '', // No tenemos imagen para archivos locales sueltos
          videoOptions: [
            VideoOption(
              id: 'local',
              movieId: 'local',
              serverImagePath: '',
              resolution: 'Local File',
              videoUrl: playPath,
            )
          ],
        ),
      ),
    );
  }
}

