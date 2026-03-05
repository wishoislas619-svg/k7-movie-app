import 'package:flutter/material.dart';
import '../../../movies/domain/entities/movie.dart';
import '../../data/datasources/video_service.dart';
import 'package:video_player/video_player.dart';

class VideoPlayerPage extends StatefulWidget {
  final String movieName;
  final List<VideoOption> videoOptions;

  const VideoPlayerPage({
    super.key, 
    required this.movieName, 
    required this.videoOptions
  });

  @override
  State<VideoPlayerPage> createState() => _VideoPlayerPageState();
}

class _VideoPlayerPageState extends State<VideoPlayerPage> {
  VideoPlayerController? _controller;
  bool _isLoading = true;
  String? _errorMessage;
  late VideoOption _currentOption;

  @override
  void initState() {
    super.initState();
    _currentOption = widget.videoOptions.first;
    _initializePlayer();
  }

  Future<void> _initializePlayer() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final directUrl = await VideoService.findDirectVideoUrl(_currentOption.videoUrl);
      if (directUrl == null) {
        throw Exception('No se pudo encontrar un enlace directo de video.');
      }

      _controller?.dispose();
      _controller = VideoPlayerController.networkUrl(Uri.parse(directUrl))
        ..initialize().then((_) {
          setState(() => _isLoading = false);
          _controller?.play();
        });
    } catch (e) {
      setState(() {
        _isLoading = false;
        _errorMessage = e.toString();
      });
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        title: Text(widget.movieName),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: _showResolutionDialog,
          ),
        ],
      ),
      body: Center(
        child: _isLoading
            ? const CircularProgressIndicator()
            : _errorMessage != null
                ? Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.error, color: Colors.red, size: 60),
                      const SizedBox(height: 20),
                      Text(_errorMessage!, style: const TextStyle(color: Colors.white)),
                      const SizedBox(height: 20),
                      ElevatedButton(
                        onPressed: _initializePlayer,
                        child: const Text('Reintentar'),
                      ),
                    ],
                  )
                : AspectRatio(
                    aspectRatio: _controller!.value.aspectRatio,
                    child: Stack(
                      alignment: Alignment.bottomCenter,
                      children: [
                        VideoPlayer(_controller!),
                        VideoProgressIndicator(
                          _controller!,
                          allowScrubbing: true,
                          colors: const VideoProgressColors(
                            playedColor: Color(0xFF00D1FF),
                            bufferedColor: Colors.white24,
                            backgroundColor: Colors.black26,
                          ),
                        ),
                      ],
                    ),
                  ),
      ),
    );
  }

  void _showResolutionDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Seleccionar Resolución'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: widget.videoOptions.map((opt) {
            return ListTile(
              title: Text(opt.resolution),
              leading: Image.network(opt.serverImagePath, width: 30, height: 30, errorBuilder: (_, __, ___) => const Icon(Icons.dns)),
              onTap: () {
                Navigator.pop(context);
                if (_currentOption != opt) {
                  setState(() => _currentOption = opt);
                  _initializePlayer();
                }
              },
            );
          }).toList(),
        ),
      ),
    );
  }
}
