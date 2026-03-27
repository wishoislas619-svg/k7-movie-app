import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:movie_app/providers.dart';
import 'package:movie_app/features/movies/domain/entities/movie.dart';
import 'package:movie_app/features/player/data/datasources/video_service.dart';
import 'package:movie_app/features/player/presentation/pages/video_player_page.dart';
import 'package:movie_app/features/movies/presentation/providers/movie_provider.dart';
import 'package:movie_app/features/movies/data/repositories/download_repository_impl.dart';
import 'package:movie_app/features/movies/domain/entities/download_task.dart';
import 'package:movie_app/shared/widgets/video_extractor_dialog.dart';
import 'package:uuid/uuid.dart';

class MovieOptionsPage extends ConsumerStatefulWidget {
  final Movie movie;
  const MovieOptionsPage({super.key, required this.movie});

  @override
  ConsumerState<MovieOptionsPage> createState() => _MovieOptionsPageState();
}

class _MovieOptionsPageState extends ConsumerState<MovieOptionsPage> {
  late Future<List<VideoOption>> _optionsFuture;

  @override
  void initState() {
    super.initState();
    _optionsFuture = ref.read(movieRepositoryProvider).getVideoOptions(widget.movie.id);
  }

  void _handleOptionSelect(VideoOption option, List<VideoOption> allOptions) {
    // Increment views only when a server is selected
    ref.read(moviesProvider.notifier).incrementViews(widget.movie.id);

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => VideoPlayerPage(
          movieName: widget.movie.name,
          videoOptions: [option, ...allOptions.where((o) => o.id != option.id)],
          subtitleUrl: widget.movie.subtitleUrl,
          mediaId: widget.movie.id,
          mediaType: 'movie',
          imagePath: widget.movie.imagePath,
          creditsStartTime: widget.movie.creditsStartTime,
          extractionAlgorithm: option.extractionAlgorithm,
        ),
      ),
    );
  }

  void _handleDownload(VideoOption option) async {
    final VideoExtractionData? result = await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => VideoExtractorDialog(url: option.videoUrl),
    );

    if (result == null) return;

    final selectedQuality = result.qualities.firstOrNull;

    if (selectedQuality != null && mounted) {
      final headers = <String, String>{};
      if (result.headers != null) {
        headers.addAll(result.headers!);
      }
      if (result.cookies != null) headers['Cookie'] = result.cookies!;
      if (result.userAgent != null) headers['User-Agent'] = result.userAgent!;
      headers['Referer'] = option.videoUrl;
      headers['Origin'] = option.videoUrl.split('/').take(3).join('/');

      final task = DownloadTask(
        id: const Uuid().v4(),
        movieId: widget.movie.id,
        movieName: widget.movie.name,
        imagePath: widget.movie.imagePath,
        videoUrl: selectedQuality.url,
        resolution: selectedQuality.resolution,
        status: DownloadStatus.pending,
        createdAt: DateTime.now(),
        headers: headers,
      );
      
      ref.read(downloadsListProvider.notifier).addDownload(task);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Iniciando descarga..."), backgroundColor: Colors.green),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: Text(widget.movie.name, style: const TextStyle(fontWeight: FontWeight.bold)),
      ),
      body: FutureBuilder<List<VideoOption>>(
        future: _optionsFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator(color: Color(0xFF00A3FF)));
          }
          final options = snapshot.data ?? [];
          if (options.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.video_library_outlined, size: 80, color: Colors.grey[800]),
                  const SizedBox(height: 16),
                  const Text(
                    'No hay opciones disponibles',
                    style: TextStyle(color: Colors.grey, fontSize: 18),
                  ),
                ],
              ),
            );
          }

          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                child: Text(
                  'Selecciona un Servidor',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              Expanded(
                child: ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: options.length,
                  itemBuilder: (context, index) {
                    final option = options[index];
                    return GestureDetector(
                      onTap: () => _handleOptionSelect(option, options),
                      child: Container(
                        margin: const EdgeInsets.only(bottom: 16),
                        padding: const EdgeInsets.all(1), // Border width
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(16),
                          gradient: LinearGradient(
                            colors: [
                              Colors.blue.withOpacity(0.6),
                              Colors.purple.withOpacity(0.6),
                              Colors.blue.withOpacity(0.6),
                              Colors.purple.withOpacity(0.6),
                            ],
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withOpacity(0.5),
                              blurRadius: 10,
                              offset: const Offset(0, 4),
                            ),
                          ],
                        ),
                        child: Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: const Color(0xFF0D031A), // Cosmic purple feeling
                            borderRadius: BorderRadius.circular(15),
                          ),
                          child: Row(
                            children: [
                              // Server Icon
                              Container(
                                width: 32,
                                height: 32,
                                decoration: BoxDecoration(
                                  color: Colors.blue.withOpacity(0.1),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(8),
                                  child: option.serverImagePath.startsWith('http')
                                      ? Image.network(
                                          option.serverImagePath,
                                          fit: BoxFit.cover,
                                          errorBuilder: (_, __, ___) => const Icon(Icons.dns, color: Colors.blue, size: 18),
                                        )
                                      : const Icon(Icons.dns, color: Colors.blue, size: 18),
                                ),
                              ),
                              const SizedBox(width: 12),
                              // Quality and Server Info
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'Servidor ${index + 1}',
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 16,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      'Calidad: ${option.resolution}',
                                      style: TextStyle(
                                        color: Colors.grey[400],
                                        fontSize: 12,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              // Language Flag
                              if (option.language != null && option.language!.isNotEmpty)
                                Container(
                                  margin: const EdgeInsets.only(right: 12),
                                  width: 34,
                                  height: 34,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    border: Border.all(color: Colors.white10, width: 1),
                                  ),
                                  child: ClipOval(
                                    child: Image.asset(
                                      option.language == 'Latino' ? 'assets/images/flags/latino.png' :
                                      option.language == 'Castellano' ? 'assets/images/flags/castellano.png' :
                                      option.language == 'Japonés' ? 'assets/images/flags/japones.png' :
                                      'assets/images/flags/ingles.png',
                                      fit: BoxFit.cover,
                                    ),
                                  ),
                                ),
                                // Download Icon
                                GestureDetector(
                                  onTap: () => _handleDownload(option),
                                  child: Container(
                                    width: 38,
                                    height: 38,
                                    decoration: BoxDecoration(
                                      color: const Color(0xFFD400FF).withOpacity(0.1),
                                      shape: BoxShape.circle,
                                    ),
                                    child: const Icon(
                                      Icons.download_for_offline_rounded,
                                      color: Color(0xFFD400FF),
                                      size: 38,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                // Play Icon
                                Container(
                                  width: 38,
                                  height: 38,
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF00A3FF).withOpacity(0.1),
                                    shape: BoxShape.circle,
                                  ),
                                  child: const Icon(
                                    Icons.play_arrow_rounded,
                                    color: Color(0xFF00A3FF),
                                    size: 26,
                                  ),
                                ),
                              ],
                            ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
