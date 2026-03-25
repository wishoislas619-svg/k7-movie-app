import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../domain/entities/movie.dart';
import '../../domain/entities/category.dart';
import '../providers/movie_provider.dart';
import '../providers/category_provider.dart';
import '../../../player/presentation/pages/video_player_page.dart';
import 'movie_options_page.dart';
import '../../../player/data/datasources/video_service.dart';
import '../../../../providers.dart';

class MovieDetailsPage extends ConsumerStatefulWidget {
  final Movie movie;
  final String? autoPlayVideoOptionId;
  final Duration? autoPlayStartPosition;

  const MovieDetailsPage({
    super.key, 
    required this.movie,
    this.autoPlayVideoOptionId,
    this.autoPlayStartPosition,
  });

  @override
  ConsumerState<MovieDetailsPage> createState() => _MovieDetailsPageState();
}

class _MovieDetailsPageState extends ConsumerState<MovieDetailsPage> {
  List<VideoOption>? _videoOptions;
  bool _isLoadingMetadata = false;
  String? _scrapedDescription;
  double? _scrapedRating;
  String? _scrapedYear;
  String? _scrapedDuration;
  bool _isDescriptionExpanded = false;

  @override
  void initState() {
    super.initState();
    _loadMetadata();
  }

  Future<void> _loadMetadata() async {
    setState(() => _isLoadingMetadata = true);
    
    // Get the latest movie data from the provider to ensure we have the correct detailsUrl
    final movList = ref.read(moviesProvider).value ?? [];
    Movie currentMovie = widget.movie;
    for (var m in movList) {
      if (m.id == widget.movie.id) {
        currentMovie = m;
        break;
      }
    }

    final options = await ref.read(movieRepositoryProvider).getVideoOptions(currentMovie.id);
    if (mounted) setState(() => _videoOptions = options);

    // 2. Determine which URL to scrape (Prioritize detailsUrl from the LATEST movie data)
    final String? urlToScrape = (currentMovie.detailsUrl != null && currentMovie.detailsUrl!.isNotEmpty)
        ? currentMovie.detailsUrl 
        : (options.isNotEmpty ? options.first.videoUrl : null);

    print('*****************************************');
    print('VERIFICANDO ESCANEO PARA: ${currentMovie.name}');
    print('DETAILS URL EN DB: ${currentMovie.detailsUrl}');
    print('USANDO PARA ESCANEAR: $urlToScrape');
    print('*****************************************');

    // Force scan if we have a detailsUrl and we're missing description or rating
    if (urlToScrape != null && (currentMovie.description == null || currentMovie.rating == 0)) {
      final metadata = await VideoService.scrapeMetadata(urlToScrape);
      if (mounted) {
        setState(() {
          _scrapedDescription = metadata['description'];
          _scrapedRating = metadata['rating'];
          _scrapedYear = metadata['year'];
          _scrapedDuration = metadata['duration'];
          _isLoadingMetadata = false;
        });
        
        // Update movie in DB with gathered information
        final updatedMovie = Movie(
          id: currentMovie.id,
          name: currentMovie.name,
          imagePath: currentMovie.imagePath, // Don't overwrite
          categoryId: currentMovie.categoryId,
          description: currentMovie.description ?? _scrapedDescription,
          detailsUrl: currentMovie.detailsUrl,
          backdrop: currentMovie.backdrop, // Don't overwrite
          backdropUrl: currentMovie.backdropUrl,
          views: currentMovie.views,
          rating: currentMovie.rating > 0 ? currentMovie.rating : (_scrapedRating ?? 0.0),
          year: currentMovie.year ?? _scrapedYear,
          duration: currentMovie.duration ?? _scrapedDuration,
          subtitleUrl: currentMovie.subtitleUrl,
          createdAt: currentMovie.createdAt,
        );
        ref.read(moviesProvider.notifier).updateMovie(updatedMovie);
      }
    } else {
      if (mounted) setState(() => _isLoadingMetadata = false);
    }

    // Auto-play logic
    if (widget.autoPlayVideoOptionId != null && _videoOptions != null && _videoOptions!.isNotEmpty && mounted) {
      _playWithParams(widget.autoPlayVideoOptionId!, widget.autoPlayStartPosition ?? Duration.zero);
    }
  }

  void _playWithParams(String optionId, Duration startPos) {
    final option = _videoOptions!.firstWhere((o) => o.id == optionId, orElse: () => _videoOptions!.first);
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => VideoPlayerPage(
          movieName: widget.movie.name,
          mediaId: widget.movie.id,
          mediaType: 'movie',
          imagePath: widget.movie.imagePath,
          videoOptions: [option, ..._videoOptions!.where((o) => o.id != option.id)],
          startPosition: startPos,
          creditsStartTime: widget.movie.creditsStartTime,
        ),
      ),
    );
  }

  void _playMovie() {
    if (_videoOptions == null || _videoOptions!.isEmpty) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => MovieOptionsPage(
          movie: widget.movie,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final categories = ref.watch(categoriesProvider).value ?? [];
    final movies = (ref.watch(moviesProvider).value ?? []).cast<Movie>();
    final currentMovie = movies.firstWhere((m) => m.id == widget.movie.id, orElse: () => widget.movie);
    
    final category = categories.firstWhere((c) => c.id == currentMovie.categoryId, orElse: () => Category(id: '', name: 'Categoría'));
    final relatedMovies = movies.where((m) => m.categoryId == currentMovie.categoryId && m.id != currentMovie.id).toList();

    final currentDescription = currentMovie.description ?? _scrapedDescription ?? 'No description available.';
    final currentRating = currentMovie.rating > 0 ? currentMovie.rating : (_scrapedRating ?? 0.0);

    return Scaffold(
      backgroundColor: Colors.black,
      body: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 1. Header Image with Gradient overlay
            Stack(
              children: [
                Container(
                  height: 300, // Increased height for better visibility
                  width: double.infinity,
                  decoration: BoxDecoration(
                    image: DecorationImage(
                      image: NetworkImage(
                        (currentMovie.backdropUrl != null && currentMovie.backdropUrl!.isNotEmpty)
                            ? currentMovie.backdropUrl!
                            : currentMovie.imagePath,
                      ),
                      fit: BoxFit.cover,
                    ),
                  ),
                ),
                Container(
                  height: 300,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.black.withOpacity(0.2),
                        Colors.transparent,
                        Colors.black.withOpacity(0.6),
                        Colors.black.withOpacity(0.9),
                      ],
                      stops: const [0.0, 0.4, 0.8, 1.0],
                    ),
                  ),
                ),
                
                // Movie Title on top of image
                Positioned(
                  bottom: 25,
                  left: 20,
                  right: 20,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      // Poster Image on the left
                      Hero(
                        tag: 'poster_${currentMovie.id}',
                        child: Container(
                          width: 120,
                          height: 180,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(12),
                            boxShadow: [
                              BoxShadow(color: const Color(0xFF00A3FF).withOpacity(0.3), blurRadius: 15, spreadRadius: 1),
                            ],
                            border: Border.all(color: const Color(0xFF00A3FF).withOpacity(0.5), width: 1.5),
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(11),
                            child: Image.network(
                              currentMovie.imagePath,
                              fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) => Container(color: Colors.white12, child: const Icon(Icons.movie, color: Colors.white24)),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 20),
                      // Title and Rating Card
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              currentMovie.name,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 28,
                                fontWeight: FontWeight.bold,
                                height: 1.1,
                                shadows: [
                                  Shadow(
                                    color: Colors.black45,
                                    offset: Offset(0, 2),
                                    blurRadius: 10,
                                  ),
                                  Shadow(color: Color(0xFF00A3FF), blurRadius: 10),
                                ],
                              ),
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 8),
                            Row(
                              children: [
                                if (currentMovie.year != null)
                                  Text(
                                    currentMovie.year!,
                                    style: TextStyle(color: Colors.white.withOpacity(0.6), fontSize: 14, fontWeight: FontWeight.w500),
                                  ),
                                if (currentMovie.year != null && currentRating > 0)
                                  const SizedBox(width: 12),
                                if (currentRating > 0)
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                    decoration: BoxDecoration(
                                      color: Colors.amber.withOpacity(0.2),
                                      borderRadius: BorderRadius.circular(8),
                                      border: Border.all(color: Colors.amber.withOpacity(0.5)),
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        const Icon(Icons.star_rounded, color: Colors.amber, size: 16),
                                        const SizedBox(width: 4),
                                        Text(
                                          currentRating.toStringAsFixed(1),
                                          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12),
                                        ),
                                      ],
                                    ),
                                  ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),

                // Top Buttons
                SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        _buildRoundButton(Icons.arrow_back, () => Navigator.pop(context)),
                        _buildRoundButton(Icons.add, () {}),
                      ],
                    ),
                  ),
                ),
              ],
            ),

            // 2. Movie Info (Meta & Content)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20.0, vertical: 0.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Title was here, moved to Stack above
                  
                  // Metadata row
                  Row(
                    children: [
                      _buildMetaIcon(Icons.remove_red_eye, '${currentMovie.views} Views'),
                      const SizedBox(width: 20),
                      Expanded(child: _buildMetaIcon(Icons.movie_creation_outlined, category.name)),
                    ],
                  ),
                  const SizedBox(height: 25),

                  // 3. Play Movie Button (Gradient)
                  GestureDetector(
                    onTap: _playMovie,
                    child: Container(
                      width: double.infinity,
                      height: 56,
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          colors: [Color(0xFF00A3FF), Color(0xFFD400FF)],
                        ),
                        borderRadius: BorderRadius.circular(12),
                        boxShadow: [
                          BoxShadow(
                            color: const Color(0xFF00A3FF).withOpacity(0.35),
                            blurRadius: 15,
                            offset: const Offset(0, 8),
                          ),
                        ],
                      ),
                      child: const Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.play_arrow, color: Colors.white, size: 28),
                          SizedBox(width: 8),
                          Text(
                            'PLAY MOVIE',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 1.1,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 25),

                  // 4. Description Card
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(1.2), // Border width
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(17),
                      gradient: LinearGradient(
                        colors: [
                          Colors.blue.withOpacity(0.5),
                          Colors.purple.withOpacity(0.5),
                          Colors.blue.withOpacity(0.5),
                          Colors.purple.withOpacity(0.5),
                        ],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                    ),
                    child: Container(
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        color: const Color(0xFF121212),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            (!_isDescriptionExpanded && currentDescription.length > 70)
                                ? '${currentDescription.substring(0, 70)}...'
                                : currentDescription,
                            style: TextStyle(
                              color: Colors.white.withOpacity(0.7),
                              fontSize: 15,
                              height: 1.6,
                            ),
                            textAlign: TextAlign.left,
                          ),
                        if (currentDescription.length > 70)
                          GestureDetector(
                            onTap: () => setState(() => _isDescriptionExpanded = !_isDescriptionExpanded),
                            child: Padding(
                              padding: const EdgeInsets.only(top: 8.0),
                              child: Text(
                                _isDescriptionExpanded ? 'Ver menos' : 'Ver más...',
                                style: const TextStyle(
                                  color: Color(0xFF00A3FF),
                                  fontWeight: FontWeight.bold,
                                  fontSize: 14,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 35),

                  // 5. More Like This Header
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'More Like This',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      TextButton(
                        onPressed: () {},
                        child: const Text(
                          'See All',
                          style: TextStyle(color: Color(0xFF00A3FF)),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),

                  // Related Movies Grid
                  SizedBox(
                    height: 190,
                    child: ListView.builder(
                      scrollDirection: Axis.horizontal,
                      itemCount: relatedMovies.length,
                      itemBuilder: (context, index) {
                        final relMovie = relatedMovies[index];
                        return GestureDetector(
                          onTap: () {
                            Navigator.pushReplacement(
                              context,
                              MaterialPageRoute(
                                builder: (_) => MovieDetailsPage(movie: relMovie),
                              ),
                            );
                          },
                          child: Container(
                            width: 130,
                            margin: const EdgeInsets.only(right: 15),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(12),
                              image: DecorationImage(
                                image: NetworkImage(relMovie.imagePath),
                                fit: BoxFit.cover,
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 40),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRoundButton(IconData icon, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.5),
          shape: BoxShape.circle,
        ),
        child: Icon(icon, color: Colors.white, size: 22),
      ),
    );
  }

  Widget _buildMetaIcon(IconData icon, String text, {Color color = Colors.grey}) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, color: color, size: 18),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            text,
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 14,
              fontWeight: FontWeight.w500,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}
