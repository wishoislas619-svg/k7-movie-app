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
  const MovieDetailsPage({super.key, required this.movie});

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
          createdAt: currentMovie.createdAt,
        );
        ref.read(moviesProvider.notifier).updateMovie(updatedMovie);
      }
    } else {
      if (mounted) setState(() => _isLoadingMetadata = false);
    }
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
                  height: 300,
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
                        Colors.black.withOpacity(0.3),
                        Colors.transparent,
                        Colors.black.withOpacity(0.8),
                        Colors.black,
                      ],
                    ),
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

            // 2. Movie Info
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                   Text(
                    currentMovie.name,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 34,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 12),
                  
                  // Metadata row
                  Row(
                    children: [
                      _buildMetaIcon(Icons.remove_red_eye, '${currentMovie.views} Views'),
                      const SizedBox(width: 20),
                      _buildMetaIcon(Icons.star, '${(currentRating * 2).toStringAsFixed(1)} Rating', color: Colors.amber),
                      const SizedBox(width: 20),
                      _buildMetaIcon(Icons.movie_creation_outlined, category.name),
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
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: const Color(0xFF121212),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: Colors.white.withOpacity(0.05)),
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
      children: [
        Icon(icon, color: color, size: 18),
        const SizedBox(width: 8),
        Text(
          text,
          style: const TextStyle(
            color: Colors.white70,
            fontSize: 14,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }
}
