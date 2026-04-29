import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:movie_app/providers.dart';
import 'package:movie_app/features/movies/domain/entities/movie.dart';
import 'package:movie_app/features/player/data/datasources/video_service.dart';
import 'package:movie_app/features/player/presentation/pages/video_player_page.dart';
import 'package:movie_app/features/auth/presentation/providers/auth_provider.dart';
import 'package:movie_app/features/movies/presentation/providers/movie_provider.dart';
import 'package:movie_app/features/movies/data/repositories/download_repository_impl.dart';
import 'package:movie_app/features/movies/domain/entities/download_task.dart';
import 'package:movie_app/shared/widgets/video_extractor_dialog.dart';
import 'package:uuid/uuid.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:movie_app/core/services/ad_service.dart';
import 'package:movie_app/features/cast/presentation/widgets/cast_button.dart';
import 'dart:async';

class MovieOptionsPage extends ConsumerStatefulWidget {
  final Movie movie;
  const MovieOptionsPage({super.key, required this.movie});

  @override
  ConsumerState<MovieOptionsPage> createState() => _MovieOptionsPageState();
}

class _MovieOptionsPageState extends ConsumerState<MovieOptionsPage> {
  late Future<List<VideoOption>> _optionsFuture;
  bool _isAdLoading = false;
  String? _adErrorMessage;

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

  Future<bool> _pollVerification(String ticketId) async {
    int retries = 15; // Increased to 15 retries (30 sec)
    while (retries > 0) {
      if (!mounted) return false;
      print('--- [POLL] Checking verification for ticket: $ticketId (retries left: $retries) ---');
      try {
        final response = await Supabase.instance.client.functions.invoke(
          'secure-video-link',
          body: {
            'ticket_id': ticketId,
            'media_type': 'movie',
            'media_id': widget.movie.id,
          },
        );
        print('--- [POLL] Response status: ${response.status} ---');
        if (response.status == 200) return true;
      } catch (e) {
        print('--- [POLL] Error: $e ---');
      }
      retries--;
      await Future.delayed(const Duration(seconds: 2));
    }
    return false;
  }

  void _handleDownload(VideoOption option) async {
    // 1. Check Ad Requirement using updated Riverpod state
    final appUser = ref.read(authStateProvider);
    if (appUser == null) return;

    final role = appUser.role.toLowerCase();
    final isAdminOrVip = role == 'admin' || role == 'uservip';

    if (!isAdminOrVip) {
      setState(() {
        _isAdLoading = true;
        _adErrorMessage = null;
      });

      try {
        final ticketId = const Uuid().v4();
        await Supabase.instance.client.from('ad_tickets').insert({
          'id': ticketId,
          'user_id': appUser.id,
          'media_type': 'movie',
          'media_id': widget.movie.id,
        });

        final adCompleter = Completer<bool>();
        bool adWatched = false;

        AdService.showRewardedAd(
          ticketId: ticketId,
          onAdWatched: (String tid) {
            adWatched = true;
            if (!adCompleter.isCompleted) adCompleter.complete(true);
          },
          onAdFailed: (String err) {
            if (mounted) setState(() => _adErrorMessage = err);
            if (!adCompleter.isCompleted) adCompleter.complete(false);
          },
          onAdDismissedIncomplete: () {
            if (mounted) {
              setState(() {
                _isAdLoading = false;
                _adErrorMessage = 'Anuncio incompleto. Debes verlo para descargar.';
              });
            }
            if (!adCompleter.isCompleted) adCompleter.complete(false);
          },
        );

        final adResult = await adCompleter.future;
        print('--- [DOWNLOAD_AD] Result: $adResult, Watched: $adWatched ---');
        
        if (mounted) setState(() => _isAdLoading = false);
        
        if (!adResult || !adWatched) return;

        // 2. Poll Verification (Background activity)
        _pollVerification(ticketId); // Don't await
      } catch (e) {
        if (mounted) {
           setState(() {
             _isAdLoading = false;
             _adErrorMessage = 'Error al procesar el anuncio: $e';
           });
        }
        return;
      }
    }

    // 3. Continue with extraction flow
    if (!mounted) return;
    
    final VideoExtractionData? result = await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => VideoExtractorDialog(
        url: option.videoUrl, 
        extractionAlgorithm: option.extractionAlgorithm,
      ),
    );

    if (result == null) return;

    final selectedQuality = result.qualities.firstOrNull;

    if (selectedQuality != null && mounted) {
      // Normalizar URL si es relativa
      var downloadUrl = selectedQuality.url;
      if (downloadUrl.startsWith('/') && !downloadUrl.startsWith('//')) {
        final uri = Uri.parse(option.videoUrl);
        downloadUrl = '${uri.scheme}://${uri.host}${uri.port != 80 && uri.port != 443 && uri.port != 0 ? ":${uri.port}" : ""}$downloadUrl';
      }

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
        videoUrl: downloadUrl,
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
      body: Stack(
        children: [
          FutureBuilder<List<VideoOption>>(
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
                                          size: 22,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    // Cast Icon
                                    GestureDetector(
                                      onTap: () {
                                        _showCastSelector(context, option);
                                      },
                                      child: Container(
                                        width: 38,
                                        height: 38,
                                        decoration: BoxDecoration(
                                          color: const Color(0xFF00FF87).withOpacity(0.1),
                                          shape: BoxShape.circle,
                                        ),
                                        child: const Icon(
                                          Icons.cast_rounded,
                                          color: Color(0xFF00FF87),
                                          size: 22,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    // Play Icon
                                    GestureDetector(
                                      onTap: () => _handleOptionSelect(option, options),
                                      child: Container(
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
          if (_isAdLoading)
            Container(
              color: Colors.black.withOpacity(0.85),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const CircularProgressIndicator(color: Color(0xFF00A3FF)),
                    const SizedBox(height: 20),
                    const Text(
                      "PREPARANDO ANUNCIO...",
                      style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, letterSpacing: 1.2),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      "Verifica tu sesión publicitaria para descargar",
                      style: TextStyle(color: Colors.white.withOpacity(0.6), fontSize: 12),
                    ),
                  ],
                ),
              ),
            ),
          if (_adErrorMessage != null)
            Positioned(
              bottom: 20,
              left: 20,
              right: 20,
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.red.withOpacity(0.9),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.error_outline, color: Colors.white),
                    const SizedBox(width: 12),
                    Expanded(child: Text(_adErrorMessage!, style: const TextStyle(color: Colors.white))),
                    IconButton(icon: const Icon(Icons.close, color: Colors.white), onPressed: () => setState(() => _adErrorMessage = null)),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  void _showCastSelector(BuildContext context, VideoOption option) {
    // Para el selector de cast necesitamos los datos del video.
    // Usamos el widget CastButton de forma invisible o simplemente disparamos su lógica
    // pero es mejor crear un método estático o reutilizable.
    // Por ahora, para ser rápidos y efectivos, mostraremos el diálogo de selección.
    
    // Mostramos un modal similar al de CastButton
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF141414),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (context) => CastSelectionModal(
        videoUrl: option.videoUrl,
        title: widget.movie.name,
        imageUrl: widget.movie.imagePath,
        headers: {
          'Referer': option.videoUrl,
          'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/123.0.0.0 Safari/537.36',
        },
        algorithm: option.extractionAlgorithm,
      ),
    );
  }
}

// Widget auxiliar para reutilizar el modal de selección en varios sitios
class CastSelectionModal extends StatelessWidget {
  final String videoUrl;
  final String title;
  final String imageUrl;
  final Map<String, String>? headers;
  final int? algorithm;

  const CastSelectionModal({
    super.key,
    required this.videoUrl,
    required this.title,
    required this.imageUrl,
    this.headers,
    this.algorithm,
  });

  @override
  Widget build(BuildContext context) {
    // Básicamente el contenido que pusimos en CastButton._openCastSelection
    // pero aquí lo pasamos a un widget reutilizable.
    // Por simplicidad en este paso, voy a mover la lógica de CastButton a un sitio común si fuera necesario,
    // pero por ahora lo duplicaré o haré referencia al CastButton si puedo.
    
    // Mejor: Usamos un CastButton "fantasma" que solo abre el modal
    return CastButton(
      videoUrl: videoUrl,
      title: title,
      imageUrl: imageUrl,
      headers: headers,
      algorithm: algorithm ?? 1,
      // Lo envolvemos para que al montarse dispare el modal
      showImmediately: true, 
    );
  }
}
