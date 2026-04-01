
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:movie_app/features/movies/data/repositories/download_repository_impl.dart';
import 'package:movie_app/features/movies/domain/entities/download_task.dart';
import 'package:movie_app/features/movies/domain/entities/movie.dart';
import 'package:movie_app/features/player/presentation/pages/video_player_page.dart';

class DownloadsPage extends ConsumerWidget {
  const DownloadsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final downloads = ref.watch(downloadsListProvider);
    final movieDownloads = downloads.where((d) => !d.isSeries).toList();
    final seriesDownloads = downloads.where((d) => d.isSeries).toList();

    return DefaultTabController(
      length: 2,
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
            tabs: [
              Tab(text: 'Películas'),
              Tab(text: 'Series'),
            ],
          ),
          actions: [
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
                Text(
                  task.resolution.contains('Resolución Auto (HLS)')
                      ? 'Detectando...'
                      : task.resolution,
                  style: const TextStyle(color: Color(0xFF00A3FF), fontSize: 12, fontWeight: FontWeight.bold),
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
