import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/movie_provider.dart';
import '../providers/category_provider.dart';
import '../../../auth/presentation/providers/auth_provider.dart';
import '../../domain/entities/category.dart';
import 'edit_movie_page.dart';

class AdminMoviePage extends ConsumerWidget {
  const AdminMoviePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final moviesAsync = ref.watch(moviesProvider);
    final categoriesAsync = ref.watch(categoriesProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Admin - Películas'),
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: () => ref.read(authStateProvider.notifier).logout(),
          ),
        ],
      ),
      body: moviesAsync.when(
        data: (movies) => categoriesAsync.when(
          data: (categories) => ListView.builder(
            itemCount: movies.length,
            itemBuilder: (context, index) {
              final movie = movies[index];
              final category = categories.cast<Category?>().firstWhere(
                (c) => c?.id == movie.categoryId, 
                orElse: () => null
              );

              return ListTile(
                title: Text(movie.name),
                subtitle: Text(category?.name ?? 'Sin Categoría'),
                trailing: const Icon(Icons.edit),
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => EditMoviePage(movie: movie)),
                  );
                },
              );
            },
          ),
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, s) => Center(child: Text('Error: $e')),
        ),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, s) => Center(child: Text('Error: $e')),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () {
          Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const EditMoviePage()),
          );
        },
        child: const Icon(Icons.add),
      ),
    );
  }
}
