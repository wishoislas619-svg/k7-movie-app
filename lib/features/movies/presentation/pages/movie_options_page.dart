import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../providers.dart';
import '../../domain/entities/movie.dart';
import '../../../player/data/datasources/video_service.dart';
import '../../../player/presentation/pages/video_player_page.dart';
import '../providers/movie_provider.dart';

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
        ),
      ),
    );
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
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: const Color(0xFF151515),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: Colors.white.withOpacity(0.05)),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withOpacity(0.3),
                              blurRadius: 10,
                              offset: const Offset(0, 4),
                            ),
                          ],
                        ),
                        child: Row(
                          children: [
                            // Server Icon
                            Container(
                              width: 60,
                              height: 60,
                              decoration: BoxDecoration(
                                color: Colors.blue.withOpacity(0.1),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(12),
                                child: option.serverImagePath.startsWith('http')
                                    ? Image.network(
                                        option.serverImagePath,
                                        fit: BoxFit.cover,
                                        errorBuilder: (_, __, ___) => const Icon(Icons.dns, color: Colors.blue),
                                      )
                                    : const Icon(Icons.dns, color: Colors.blue, size: 30),
                              ),
                            ),
                            const SizedBox(width: 20),
                            // Quality and Server Info
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Servidor ${index + 1}',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 18,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    'Calidad: ${option.resolution}',
                                    style: TextStyle(
                                      color: Colors.grey[500],
                                      fontSize: 14,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            // Play Icon with Gradient background hint
                            Container(
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                color: const Color(0xFF00A3FF).withOpacity(0.1),
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(
                                Icons.play_arrow_rounded,
                                color: Color(0xFF00A3FF),
                                size: 30,
                              ),
                            ),
                          ],
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
