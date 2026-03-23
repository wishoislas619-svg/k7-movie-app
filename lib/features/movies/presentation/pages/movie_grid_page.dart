import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:movie_app/features/movies/presentation/providers/movie_provider.dart';
import 'package:movie_app/features/movies/presentation/providers/category_provider.dart';
import 'package:movie_app/features/movies/domain/entities/movie.dart';
import 'package:movie_app/features/movies/domain/entities/category.dart';
import 'package:movie_app/features/movies/presentation/pages/movie_details_page.dart';
import 'package:movie_app/features/movies/presentation/pages/category_page.dart';
import 'package:movie_app/core/constants/app_constants.dart';
import 'package:movie_app/features/auth/presentation/providers/auth_provider.dart';
import 'package:movie_app/shared/widgets/marquee_text.dart';
import 'package:movie_app/features/movies/presentation/pages/downloads_page.dart';
import 'package:movie_app/features/series/presentation/pages/series_grid_page.dart';
import 'package:movie_app/features/auth/presentation/pages/profile_page.dart';
import 'package:movie_app/features/movies/presentation/providers/history_provider.dart';
import 'package:movie_app/features/movies/domain/entities/watch_history.dart';
import 'package:movie_app/features/series/domain/entities/series.dart';
import 'package:movie_app/features/series/presentation/pages/series_details_page.dart';
import 'package:movie_app/features/movies/presentation/pages/history_view_all_page.dart';
import 'package:movie_app/features/series/presentation/providers/series_provider.dart';
import 'package:movie_app/features/player/presentation/pages/video_player_page.dart';
import 'package:movie_app/providers.dart';

class MovieGridPage extends ConsumerStatefulWidget {
  const MovieGridPage({super.key});

  @override
  ConsumerState<MovieGridPage> createState() => _MovieGridPageState();
}

class _MovieGridPageState extends ConsumerState<MovieGridPage> {
  final PageController _carouselController = PageController();
  final PageController _pageController = PageController();
  int _currentCarouselPage = 0;
  int _currentTabIndex = 0;
  String? _selectedCategoryFilter;
  bool _isSearching = false;
  String _searchQuery = "";
  final TextEditingController _searchController = TextEditingController();

  @override
  void dispose() {
    _carouselController.dispose();
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: PageView(
        controller: _pageController,
        onPageChanged: (index) {
          setState(() => _currentTabIndex = index);
        },
        physics: const ClampingScrollPhysics(),
        children: [
          _buildMoviesView(),
          const SeriesGridPage(),
          const DownloadsPage(),
          const ProfilePage(),
        ],
      ),
      bottomNavigationBar: _buildBottomNav(),
    );
  }

  Widget _buildMoviesView() {
    final moviesAsync = ref.watch(moviesProvider);
    final categoriesAsync = ref.watch(categoriesProvider);

    return moviesAsync.when(
      data: (allMovies) {
        // Filtering logic
        var filteredMovies = allMovies;
        if (_selectedCategoryFilter != null) {
          filteredMovies = allMovies.where((m) => m.categoryId == _selectedCategoryFilter).toList();
        }
        if (_searchQuery.isNotEmpty) {
          filteredMovies = filteredMovies.where((m) => m.name.toLowerCase().contains(_searchQuery.toLowerCase())).toList();
        }

        final popularMovies = filteredMovies.where((m) => m.isPopular).toList();

        return categoriesAsync.when(
          data: (categories) {
            return Stack(
              children: [
                 RefreshIndicator(
                  onRefresh: () async {
                    await ref.read(moviesProvider.notifier).loadMovies();
                    await ref.read(categoriesProvider.notifier).loadCategories();
                  },
                  color: const Color(0xFF00A3FF),
                  backgroundColor: const Color(0xFF1A1A1A),
                  child: CustomScrollView(
                    slivers: [
                      _buildHeader(categories),
                      if (_isSearching)
                        SliverToBoxAdapter(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                            child: TextField(
                              controller: _searchController,
                              autofocus: true,
                              style: const TextStyle(color: Colors.white),
                              decoration: InputDecoration(
                                hintText: 'Buscar películas...',
                                hintStyle: const TextStyle(color: Colors.white38),
                                prefixIcon: const Icon(Icons.search, color: Color(0xFF00A3FF)),
                                suffixIcon: IconButton(
                                  icon: const Icon(Icons.close, color: Colors.white70),
                                  onPressed: () {
                                    setState(() {
                                      _isSearching = false;
                                      _searchQuery = "";
                                      _searchController.clear();
                                    });
                                  },
                                ),
                                filled: true,
                                fillColor: Colors.white.withOpacity(0.05),
                                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                              ),
                              onChanged: (val) => setState(() => _searchQuery = val),
                            ),
                          ),
                        ),
                      if (popularMovies.isNotEmpty && !_isSearching && _selectedCategoryFilter == null)
                        SliverToBoxAdapter(
                          child: _buildCarousel(popularMovies),
                        ),
                      SliverPadding(
                        padding: const EdgeInsets.only(top: 0, bottom: 100),
                        sliver: SliverList(
                          delegate: SliverChildListDelegate([
                            if (filteredMovies.isNotEmpty && !_isSearching && _selectedCategoryFilter == null) ...[
                              ref.watch(historyProvider).when(
                                data: (history) {
                                  if (history.isEmpty) return const SizedBox.shrink();

                                  final Map<String, WatchHistory> uniqueHistory = {};
                                  for (var item in history) {
                                    if (!uniqueHistory.containsKey(item.mediaId)) {
                                      uniqueHistory[item.mediaId] = item;
                                    }
                                  }
                                  
                                  return _buildHistorySection(context, uniqueHistory.values.take(20).toList());
                                },
                                loading: () => const SizedBox.shrink(),
                                error: (_, __) => const SizedBox.shrink(),
                              ),
                              _buildMovieSection(
                                context, 
                                'RECIÉN AGREGADAS', 
                                filteredMovies.where((m) => true).toList()..sort((a,b) => b.createdAt.compareTo(a.createdAt)),
                              ),
                            ],
                            if (_isSearching || _selectedCategoryFilter != null)
                              Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 16),
                                child: GridView.builder(
                                  shrinkWrap: true,
                                  physics: const NeverScrollableScrollPhysics(),
                                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                                    crossAxisCount: 3,
                                    crossAxisSpacing: 12,
                                    mainAxisSpacing: 20,
                                    mainAxisExtent: 240,
                                  ),
                                  itemCount: filteredMovies.length,
                                  itemBuilder: (context, index) => _buildMovieCard(context, filteredMovies[index]),
                                ),
                              )
                            else
                              ...categories.map((cat) {
                                final catMovies = filteredMovies.where((m) => m.categoryId == cat.id).toList();
                                if (catMovies.isEmpty) return const SizedBox.shrink();
                                return _buildMovieSection(
                                  context, 
                                  cat.name.toUpperCase(), 
                                  catMovies,
                                  category: cat
                                );
                              }),
                          ]),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
          loading: () => const Center(child: CircularProgressIndicator(color: Color(0xFF00A3FF))),
          error: (e, s) => Center(child: Text('Error: $e', style: const TextStyle(color: Colors.white))),
        );
      },
      loading: () => const Center(child: CircularProgressIndicator(color: Color(0xFF00A3FF))),
      error: (e, s) => Center(child: Text('Error: $e', style: const TextStyle(color: Colors.white))),
    );
  }

  Widget _buildHeader(List<Category> categories) {
    return SliverAppBar(
      backgroundColor: Colors.black.withOpacity(0.5),
      floating: true,
      elevation: 0,
      title: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              gradient: const LinearGradient(colors: [Color(0xFF4A90FF), Color(0xFFBC00FF)]),
              borderRadius: BorderRadius.circular(4),
            ),
            child: const Text('K7', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Colors.white)),
          ),
          const SizedBox(width: 8),
          const Text('MOVIE', style: TextStyle(letterSpacing: 2, fontWeight: FontWeight.normal, fontSize: 16, color: Colors.white)),
        ],
      ),
      actions: [
        DropdownButtonHideUnderline(
          child: DropdownButton<String?>(
            value: _selectedCategoryFilter,
            dropdownColor: const Color(0xFF121212),
            icon: const Icon(Icons.filter_list, color: Color(0xFF00A3FF)),
            items: [
              const DropdownMenuItem(value: null, child: Text("Todas", style: TextStyle(color: Colors.white))),
              ...categories.map((c) => DropdownMenuItem(value: c.id, child: Text(c.name, style: const TextStyle(color: Colors.white)))),
            ],
            onChanged: (val) => setState(() => _selectedCategoryFilter = val),
          ),
        ),
        IconButton(
          icon: Icon(_isSearching ? Icons.search_off : Icons.search, color: Colors.white70), 
          onPressed: () => setState(() => _isSearching = !_isSearching)
        ),
      ],
    );
  }

  Widget _buildCarousel(List<Movie> popularMovies) {
    return Column(
      children: [
        SizedBox(
          height: 300,
          child: PageView.builder(
            controller: _carouselController,
            onPageChanged: (index) => setState(() => _currentCarouselPage = index),
            itemCount: popularMovies.length,
            itemBuilder: (context, index) {
              final movie = popularMovies[index];
              return _buildCarouselItem(movie);
            },
          ),
        ),
        const SizedBox(height: 12),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: List.generate(
            popularMovies.length,
            (index) => AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              margin: const EdgeInsets.symmetric(horizontal: 4),
              width: _currentCarouselPage == index ? 10 : 8,
              height: _currentCarouselPage == index ? 10 : 8,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _currentCarouselPage == index ? const Color(0xFF00A3FF) : Colors.white24,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildCarouselItem(Movie movie) {
    return GestureDetector(
      onTap: () {
        Navigator.push(context, MaterialPageRoute(builder: (_) => MovieDetailsPage(movie: movie)));
      },
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        padding: const EdgeInsets.all(1.5), // Border width for iridescent effect
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(25),
          gradient: LinearGradient(
            colors: [
              Colors.blue.withOpacity(0.7),
              Colors.purple.withOpacity(0.7),
              Colors.blue.withOpacity(0.7),
              Colors.purple.withOpacity(0.7),
            ],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(24),
          child: Stack(
            fit: StackFit.expand,
            children: [
              Image.network((movie.backdropUrl != null && movie.backdropUrl!.isNotEmpty) ? movie.backdropUrl! : movie.imagePath, fit: BoxFit.cover),
              Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.transparent,
                      Colors.black.withOpacity(0.4),
                      Colors.black.withOpacity(0.9),
                    ],
                  ),
                ),
              ),
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: Container(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'TRENDING NOW',
                        style: TextStyle(color: Color(0xFF00E5FF), fontWeight: FontWeight.bold, letterSpacing: 1.2, fontSize: 11),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        movie.name.toUpperCase(),
                        style: const TextStyle(color: Colors.white, fontSize: 26, fontWeight: FontWeight.w900, height: 1.1),
                      ),
                      const SizedBox(height: 10),
                      if (movie.description != null)
                        Text(
                          movie.description!,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: Colors.white.withOpacity(0.7), fontSize: 13),
                        ),
                      const SizedBox(height: 20),
                      Row(
                        children: [
                          Expanded(
                            child: Container(
                              height: 48,
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
                              child: ElevatedButton.icon(
                                onPressed: () {
                                  Navigator.push(context, MaterialPageRoute(builder: (_) => MovieDetailsPage(movie: movie)));
                                },
                                icon: const Icon(Icons.play_arrow, size: 20),
                                label: const Text('Play Now', style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1.1)),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.transparent,
                                  shadowColor: Colors.transparent,
                                  foregroundColor: Colors.white,
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Container(
                            decoration: BoxDecoration(
                              color: Colors.white.withOpacity(0.1),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: IconButton(
                              icon: const Icon(Icons.add, color: Colors.white),
                              onPressed: () {},
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMovieSection(BuildContext context, String title, List<Movie> movies, {Category? category}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Container(
                    width: 3,
                    height: 18,
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [Color(0xFF00A3FF), Color(0xFFD400FF)],
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                      ),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    title,
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w900, letterSpacing: 1.5, color: Colors.white),
                  ),
                ],
              ),
              if (category != null)
                TextButton(
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => CategoryPage(category: category, movies: movies))
                    );
                  },
                  child: const Text('VIEW ALL', style: TextStyle(color: Colors.white38, fontSize: 10, fontWeight: FontWeight.bold)),
                ),
            ],
          ),
        ),
        SizedBox(
          height: 240,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: movies.length,
            itemBuilder: (context, index) {
              final movie = movies[index];
              return _buildMovieCard(context, movie);
            },
          ),
        ),
        const SizedBox(height: 20),
      ],
    );
  }

  Widget _buildMovieCard(BuildContext context, Movie movie) {
    return Container(
      width: 120,
      margin: const EdgeInsets.only(right: 16),
      child: GestureDetector(
        onTap: () {
          Navigator.push(
            context, 
            MaterialPageRoute(builder: (_) => MovieDetailsPage(movie: movie))
          );
        },
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Stack(
              children: [
                Container(
                  padding: const EdgeInsets.all(1.2),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(16),
                    gradient: LinearGradient(
                      colors: [
                        const Color(0xFF00A3FF).withOpacity(0.5),
                        const Color(0xFFD400FF).withOpacity(0.5),
                      ],
                    ),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(15),
                    child: Container(
                      width: 120,
                      height: 180,
                      color: Colors.white10,
                      child: Image.network(
                        movie.imagePath, 
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => const Icon(Icons.movie, color: Colors.white24, size: 50),
                      ),
                    ),
                  ),
                ),
                Positioned(
                  top: 8,
                  left: 8,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                    decoration: BoxDecoration(
                      color: const Color(0xFF00A3FF).withOpacity(0.8),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: const Text('MOVIE', style: TextStyle(color: Colors.white, fontSize: 8, fontWeight: FontWeight.bold)),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            MarqueeText(
              text: movie.name,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white),
              width: 120,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHistorySection(BuildContext context, List<WatchHistory> history) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Container(
                    width: 3,
                    height: 18,
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [Color(0xFF00A3FF), Color(0xFFD400FF)],
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                      ),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(width: 10),
                  const Text(
                    'CONTINUAR VIENDO',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w900, letterSpacing: 1.5, color: Colors.white),
                  ),
                ],
              ),
              TextButton(
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const HistoryViewAllPage())
                  );
                },
                child: const Text('VIEW ALL', style: TextStyle(color: Colors.white38, fontSize: 10, fontWeight: FontWeight.bold)),
              ),
            ],
          ),
        ),
        SizedBox(
          height: 260,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: history.length,
            itemBuilder: (context, index) {
              return _buildHistoryCard(context, history[index]);
            },
          ),
        ),
        const SizedBox(height: 20),
      ],
    );
  }

  Widget _buildHistoryCard(BuildContext context, WatchHistory item) {
    final progress = item.lastPosition / item.totalDuration;
    
    return Container(
      width: 140,
      margin: const EdgeInsets.only(right: 16),
      child: GestureDetector(
        onTap: () => _showHistoryOptionsModal(context, item),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Stack(
              children: [
                Container(
                  padding: const EdgeInsets.all(1.2),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(16),
                    gradient: LinearGradient(
                      colors: [
                        const Color(0xFF00A3FF).withOpacity(0.5),
                        const Color(0xFFD400FF).withOpacity(0.5),
                      ],
                    ),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(15),
                    child: Stack(
                      children: [
                        Container(
                          width: 140,
                          height: 200,
                          color: Colors.white10,
                          child: Image.network(
                            item.imagePath, 
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => const Icon(Icons.movie, color: Colors.white24, size: 50),
                          ),
                        ),
                        // Progress bar at the bottom of the card image
                        Positioned(
                          bottom: 0,
                          left: 0,
                          right: 0,
                          child: Column(
                            children: [
                              Container(
                                height: 4,
                                width: double.infinity,
                                color: Colors.white24,
                                alignment: Alignment.centerLeft,
                                child: FractionallySizedBox(
                                  widthFactor: progress.clamp(0.0, 1.0),
                                  child: Container(
                                    height: 4,
                                    decoration: const BoxDecoration(
                                      gradient: LinearGradient(colors: [Color(0xFF00A3FF), Color(0xFFD400FF)]),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        // Play icon overlay
                        Positioned.fill(
                          child: Center(
                            child: Container(
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                color: Colors.black.withOpacity(0.4),
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(Icons.play_arrow_rounded, color: Colors.white, size: 30),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              item.title,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.white),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            if (item.subtitle != null)
              Text(
                item.subtitle!,
                style: const TextStyle(fontSize: 11, color: Colors.white54),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildBottomNav() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.9),
        border: const Border(top: BorderSide(color: Colors.white10, width: 0.5)),
      ),
      child: BottomNavigationBar(
        currentIndex: _currentTabIndex,
        onTap: (index) {
          _pageController.animateToPage(
            index,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeInOut,
          );
        },
        backgroundColor: Colors.transparent,
        elevation: 0,
        type: BottomNavigationBarType.fixed,
        selectedItemColor: Colors.white,
        unselectedItemColor: Colors.white38,
        selectedFontSize: 10,
        unselectedFontSize: 10,
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.movie_creation_outlined), label: 'PELÍCULAS'),
          BottomNavigationBarItem(icon: Icon(Icons.live_tv_outlined), label: 'SERIES'),
          BottomNavigationBarItem(icon: Icon(Icons.download_rounded), label: 'DESCARGAS'),
          BottomNavigationBarItem(icon: Icon(Icons.person_outline), label: 'PERFIL'),
        ],
      ),
    );
  }

  void _showHistoryOptionsModal(BuildContext context, WatchHistory item) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF141414),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (BuildContext ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                margin: const EdgeInsets.only(top: 10, bottom: 20),
                height: 4,
                width: 40,
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.play_circle_fill, color: Color(0xFF00A3FF)),
                title: const Text('Reanudar reproducción', style: TextStyle(color: Colors.white)),
                onTap: () {
                  Navigator.pop(ctx);
                  _launchMedia(context, item, resume: true);
                },
              ),
              ListTile(
                leading: const Icon(Icons.replay, color: Colors.white70),
                title: const Text('Ver desde el principio', style: TextStyle(color: Colors.white)),
                onTap: () {
                  Navigator.pop(ctx);
                  _launchMedia(context, item, resume: false);
                },
              ),
              ListTile(
                leading: const Icon(Icons.info_outline, color: Colors.white70),
                title: const Text('Selecionar Enlace', style: TextStyle(color: Colors.white)),
                onTap: () {
                  Navigator.pop(ctx);
                  _goToDetails(context, item);
                },
              ),
              const SizedBox(height: 10),
            ],
          ),
        );
      },
    );
  }

  void _goToDetails(BuildContext context, WatchHistory item) {
    if (item.mediaType == 'movie') {
      final movie = (ref.read(moviesProvider).value ?? []).firstWhere(
        (m) => m.id == item.mediaId,
        orElse: () => throw Exception('Movie not found'),
      );
      Navigator.push(context, MaterialPageRoute(builder: (_) => MovieDetailsPage(movie: movie)));
    } else {
      final series = (ref.read(seriesListProvider).value ?? []).firstWhere(
        (s) => s.id == item.mediaId,
        orElse: () => throw Exception('Series not found'),
      );
      Navigator.push(context, MaterialPageRoute(builder: (_) => SeriesDetailsPage(series: series)));
    }
  }

  /// Método factorizado para iniciar el contenido.
  Future<void> _launchMedia(BuildContext context, WatchHistory item, {required bool resume}) async {
    final startPos = resume ? Duration(milliseconds: item.lastPosition) : Duration.zero;

    if (item.mediaType == 'movie') {
      final allOptions = await ref.read(movieRepositoryProvider).getVideoOptions(item.mediaId);
      if (allOptions.isEmpty) {
        if (!context.mounted) return;
        _goToDetails(context, item);
        return;
      }

      // Fetch the movie to get creditsStartTime
      final movie = (ref.read(moviesProvider).value ?? []).firstWhere(
        (m) => m.id == item.mediaId,
        orElse: () => throw Exception('Movie not found'),
      );

      // Preferir el enlace que el usuario eligió la última vez
      final preferredOption = item.videoOptionId != null
          ? allOptions.firstWhere((o) => o.id == item.videoOptionId, orElse: () => allOptions.first)
          : allOptions.first;

      if (!context.mounted) return;
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => VideoPlayerPage(
            movieName: item.title,
            mediaId: item.mediaId,
            mediaType: 'movie',
            imagePath: item.imagePath,
            videoOptions: [preferredOption, ...allOptions.where((o) => o.id != preferredOption.id)],
            startPosition: startPos,
            creditsStartTime: movie.creditsStartTime,
          ),
        ),
      );
    } else {
      // Series: ir a detalles con parámetros de auto-play
      if (!context.mounted) return;
      final series = (ref.read(seriesListProvider).value ?? []).firstWhere(
        (s) => s.id == item.mediaId,
        orElse: () => throw Exception('Series not found'),
      );

      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => SeriesDetailsPage(
            series: series,
            autoPlayEpisodeId: item.episodeId,
            autoPlayVideoOptionId: item.videoOptionId,
            autoPlayStartPosition: startPos,
          ),
        ),
      );
    }
  }
}
