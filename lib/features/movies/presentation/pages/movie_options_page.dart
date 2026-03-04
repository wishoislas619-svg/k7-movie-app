import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/constants/app_constants.dart';
import '../../../../providers.dart';
import '../../domain/entities/movie.dart';
import '../../../player/data/datasources/video_service.dart';
import '../../../player/presentation/pages/video_player_page.dart';

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

  void _handleOptionSelect(VideoOption option) async {
    // Show loading dialog
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );

    final directUrl = await VideoService.findDirectVideoUrl(option.videoUrl);
    
    if (mounted) Navigator.pop(context); // Close loading

    if (directUrl != null) {
      if (mounted) {
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => MinimalVideoPlayer(videoUrl: directUrl)),
        );
      }
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No se pudo detectar el video real en el enlace')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.movie.name)),
      body: FutureBuilder<List<VideoOption>>(
        future: _optionsFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          final options = snapshot.data ?? [];
          if (options.isEmpty) {
            return const Center(child: Text('No hay opciones de video disponibles'));
          }
          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: options.length,
            itemBuilder: (context, index) {
              final option = options[index];
              return GestureDetector(
                onTap: () => _handleOptionSelect(option),
                child: Container(
                  height: AppConstants.optionRowHeight,
                  margin: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      Container(
                        width: AppConstants.serverImageSize,
                        height: AppConstants.serverImageSize,
                        color: Colors.blueAccent,
                        child: option.serverImagePath.startsWith('http')
                          ? Image.network(option.serverImagePath, fit: BoxFit.cover)
                          : const Icon(Icons.dns, size: 8, color: Colors.white),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        option.resolution,
                        style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
