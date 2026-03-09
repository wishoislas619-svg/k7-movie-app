import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../providers.dart';
import '../providers/movie_provider.dart';
import '../../domain/entities/movie.dart';

class AdminPopularMoviesPage extends ConsumerStatefulWidget {
  const AdminPopularMoviesPage({super.key});

  @override
  ConsumerState<AdminPopularMoviesPage> createState() => _AdminPopularMoviesPageState();
}

class _AdminPopularMoviesPageState extends ConsumerState<AdminPopularMoviesPage> {
  String _searchQuery = "";
  final TextEditingController _searchController = TextEditingController();

  @override
  Widget build(BuildContext context) {
    final moviesAsync = ref.watch(moviesProvider);

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: const Color(0xFF0A0A0A),
        elevation: 0,
        title: const Text(
          'POPULARES',
          style: TextStyle(color: Color(0xFF00A3FF), fontWeight: FontWeight.bold, letterSpacing: 2, fontSize: 16),
        ),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(60),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: TextField(
              controller: _searchController,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                hintText: 'Buscar película...',
                hintStyle: const TextStyle(color: Colors.white38),
                prefixIcon: const Icon(Icons.search, color: Colors.white70),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: Colors.white.withOpacity(0.1)),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: Color(0xFF00A3FF)),
                ),
                filled: true,
                fillColor: Colors.white.withOpacity(0.04),
                contentPadding: const EdgeInsets.symmetric(vertical: 12),
              ),
              onChanged: (value) => setState(() => _searchQuery = value.toLowerCase()),
            ),
          ),
        ),
      ),
      body: moviesAsync.when(
        data: (movies) {
          final filteredMovies = movies.where((m) => m.name.toLowerCase().contains(_searchQuery)).toList();
          final popularCount = movies.where((m) => m.isPopular).length;

          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(12.0),
                child: Text(
                  'Seleccionadas: $popularCount / 10',
                  style: TextStyle(
                    color: popularCount > 10 ? Colors.red : Colors.greenAccent,
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                  ),
                ),
              ),
              Expanded(
                child: ListView.builder(
                  padding: const EdgeInsets.only(bottom: 120),
                  itemCount: filteredMovies.length,
                  itemBuilder: (context, index) {
                    final movie = filteredMovies[index];
                    return Container(
                      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.03),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: movie.isPopular 
                            ? const Color(0xFF00A3FF).withOpacity(0.5) 
                            : Colors.white.withOpacity(0.05)
                        ),
                      ),
                      child: CheckboxListTile(
                        title: Text(movie.name, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                        secondary: ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: Image.network(
                            movie.imagePath,
                            width: 40,
                            height: 60,
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => const Icon(Icons.movie, size: 40, color: Colors.white24),
                          ),
                        ),
                        value: movie.isPopular,
                        activeColor: const Color(0xFF00A3FF),
                        checkColor: Colors.white,
                        onChanged: (val) async {
                        if (val == true && popularCount >= 10) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Límite de 10 películas alcanzado')),
                          );
                          return;
                        }
                        
                        final updatedMovie = Movie(
                          id: movie.id,
                          name: movie.name,
                          imagePath: movie.imagePath,
                          categoryId: movie.categoryId,
                          description: movie.description,
                          detailsUrl: movie.detailsUrl,
                          backdrop: movie.backdrop,
                          backdropUrl: movie.backdropUrl,
                          views: movie.views,
                          rating: movie.rating,
                          year: movie.year,
                          duration: movie.duration,
                          subtitleUrl: movie.subtitleUrl,
                          isPopular: val ?? false,
                          createdAt: movie.createdAt,
                        );

                        await ref.read(movieRepositoryProvider).updateMovie(updatedMovie);
                        ref.invalidate(moviesProvider);
                      },
                    ),
                    );
                  },
                ),
              ),
            ],
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, s) => Center(child: Text('Error: $e')),
      ),
    );
  }
}
