import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/movie_provider.dart';
import '../providers/category_provider.dart';
import '../../domain/entities/movie.dart';
import '../../domain/entities/category.dart';
import 'movie_options_page.dart';
import 'category_page.dart';
import '../../../../core/constants/app_constants.dart';
import '../../../auth/presentation/providers/auth_provider.dart';

import '../../../../shared/widgets/marquee_text.dart';

class MovieGridPage extends ConsumerWidget {
  const MovieGridPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final moviesAsync = ref.watch(moviesProvider);
    final categoriesAsync = ref.watch(categoriesProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Movies'),
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: () => ref.read(authStateProvider.notifier).logout(),
          ),
        ],
      ),
      body: moviesAsync.when(
        data: (allMovies) {
          return categoriesAsync.when(
            data: (categories) {
              return ListView(
                padding: const EdgeInsets.symmetric(vertical: 16),
                children: [
                  _buildMovieSection(
                    context, 
                    'Recién Agregadas', 
                    allMovies.take(20).toList()
                  ),
                  ...categories.map((cat) {
                    final catMovies = allMovies.where((m) => m.categoryId == cat.id).toList();
                    if (catMovies.isEmpty) return const SizedBox.shrink();
                    return _buildMovieSection(
                      context, 
                      cat.name, 
                      catMovies,
                      category: cat
                    );
                  }),
                ],
              );
            },
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, s) => Center(child: Text('Error categorías: $e')),
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, s) => Center(child: Text('Error películas: $e')),
      ),
    );
  }

  Widget _buildMovieSection(BuildContext context, String title, List<Movie> movies, {Category? category}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: InkWell(
            onTap: category != null ? () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => CategoryPage(category: category, movies: movies))
              );
            } : null,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  title,
                  style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                ),
                if (category != null)
                  const Icon(Icons.chevron_right, size: 28),
              ],
            ),
          ),
        ),
        SizedBox(
          height: 160,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: movies.length,
            itemBuilder: (context, index) {
              final movie = movies[index];
              return Container(
                width: 110,
                margin: const EdgeInsets.only(right: 16),
                child: GestureDetector(
                  onTap: () {
                    Navigator.push(
                      context, 
                      MaterialPageRoute(builder: (_) => MovieOptionsPage(movie: movie))
                    );
                  },
                  child: Column(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: Container(
                          width: AppConstants.movieImageWidth,
                          height: AppConstants.movieImageHeight,
                          color: Colors.grey[800],
                          child: movie.imagePath.startsWith('http') 
                            ? Image.network(movie.imagePath, fit: BoxFit.cover)
                            : const Icon(Icons.movie, color: Colors.white24),
                        ),
                      ),
                      const SizedBox(height: 6),
                      MarqueeText(
                        text: movie.name,
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
                        width: 90,
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
  }
}
