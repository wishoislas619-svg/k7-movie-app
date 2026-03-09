import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/movie_provider.dart';
import '../providers/category_provider.dart';
import '../../domain/entities/movie.dart';
import '../../domain/entities/category.dart';
import 'movie_details_page.dart';
import 'category_page.dart';
import '../../../../core/constants/app_constants.dart';
import '../../../auth/presentation/providers/auth_provider.dart';
import '../../../../shared/widgets/marquee_text.dart';

class MovieGridPage extends ConsumerStatefulWidget {
  const MovieGridPage({super.key});

  @override
  ConsumerState<MovieGridPage> createState() => _MovieGridPageState();
}

class _MovieGridPageState extends ConsumerState<MovieGridPage> {
  final PageController _carouselController = PageController();
  int _currentCarouselPage = 0;
  int _currentTabIndex = 0;

  @override
  void dispose() {
    _carouselController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final moviesAsync = ref.watch(moviesProvider);
    final categoriesAsync = ref.watch(categoriesProvider);

    return Scaffold(
      backgroundColor: Colors.black,
      body: moviesAsync.when(
        data: (allMovies) {
          final popularMovies = allMovies.where((m) => m.isPopular).toList();
          return categoriesAsync.when(
            data: (categories) {
              return Stack(
                children: [
                   CustomScrollView(
                    slivers: [
                      _buildHeader(),
                      if (popularMovies.isNotEmpty)
                        SliverToBoxAdapter(
                          child: _buildCarousel(popularMovies),
                        ),
                      SliverPadding(
                        padding: const EdgeInsets.only(top: 20, bottom: 100),
                        sliver: SliverList(
                          delegate: SliverChildListDelegate([
                            _buildMovieSection(
                              context, 
                              'RECIÉN AGREGADAS', 
                              allMovies.take(20).toList()
                            ),
                            ...categories.map((cat) {
                              final catMovies = allMovies.where((m) => m.categoryId == cat.id).toList();
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
                ],
              );
            },
            loading: () => const Center(child: CircularProgressIndicator(color: Color(0xFF00A3FF))),
            error: (e, s) => Center(child: Text('Error: $e', style: const TextStyle(color: Colors.white))),
          );
        },
        loading: () => const Center(child: CircularProgressIndicator(color: Color(0xFF00A3FF))),
        error: (e, s) => Center(child: Text('Error: $e', style: const TextStyle(color: Colors.white))),
      ),
      bottomNavigationBar: _buildBottomNav(),
    );
  }

  Widget _buildHeader() {
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
        IconButton(icon: const Icon(Icons.cast, color: Colors.white70), onPressed: () {}),
        IconButton(icon: const Icon(Icons.notifications_none, color: Colors.white70), onPressed: () {}),
        IconButton(
          icon: const Icon(Icons.logout, color: Colors.white70),
          onPressed: () => ref.read(authStateProvider.notifier).logout(),
        ),
      ],
    );
  }

  Widget _buildCarousel(List<Movie> popularMovies) {
    return Column(
      children: [
        SizedBox(
          height: 350,
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
                            child: ElevatedButton.icon(
                              onPressed: () {
                                Navigator.push(context, MaterialPageRoute(builder: (_) => MovieDetailsPage(movie: movie)));
                              },
                              icon: const Icon(Icons.play_arrow, size: 20),
                              label: const Text('Play Now', style: TextStyle(fontWeight: FontWeight.bold)),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.white,
                                foregroundColor: Colors.black,
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                padding: const EdgeInsets.symmetric(vertical: 14),
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
          height: 220,
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
                ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: Container(
                    width: 120,
                    height: 160,
                    color: Colors.white10,
                    child: Image.network(
                      movie.imagePath, 
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => const Icon(Icons.movie, color: Colors.white24, size: 50),
                    ),
                  ),
                ),
                Positioned(
                  top: 8,
                  left: 8,
                  child: Container(
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.5),
                      shape: BoxShape.circle,
                    ),
                    child: const Text('K7', style: TextStyle(color: Colors.white, fontSize: 8, fontWeight: FontWeight.bold)),
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

  Widget _buildBottomNav() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.9),
        border: const Border(top: BorderSide(color: Colors.white10, width: 0.5)),
      ),
      child: BottomNavigationBar(
        currentIndex: _currentTabIndex,
        onTap: (index) => setState(() => _currentTabIndex = index),
        backgroundColor: Colors.transparent,
        elevation: 0,
        type: BottomNavigationBarType.fixed,
        selectedItemColor: Colors.white,
        unselectedItemColor: Colors.white38,
        selectedFontSize: 10,
        unselectedFontSize: 10,
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.home_filled), label: 'HOME'),
          BottomNavigationBarItem(icon: Icon(Icons.search), label: 'SEARCH'),
          BottomNavigationBarItem(icon: Icon(Icons.download_rounded), label: 'DOWNLOADS'),
          BottomNavigationBarItem(icon: Icon(Icons.person_outline), label: 'PROFILE'),
        ],
      ),
    );
  }
}
