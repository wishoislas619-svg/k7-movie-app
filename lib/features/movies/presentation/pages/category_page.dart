import 'package:flutter/material.dart';
import '../../domain/entities/movie.dart';
import '../../domain/entities/category.dart';
import 'movie_details_page.dart';
import '../../../../core/constants/app_constants.dart';
import '../../../../shared/widgets/marquee_text.dart';

class CategoryPage extends StatelessWidget {
  final Category category;
  final List<Movie> movies;

  const CategoryPage({
    super.key, 
    required this.category, 
    required this.movies
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(category.name)),
      body: GridView.builder(
        padding: const EdgeInsets.all(16),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          crossAxisSpacing: 16,
          mainAxisSpacing: 16,
          mainAxisExtent: 180,
        ),
        itemCount: movies.length,
        itemBuilder: (context, index) {
          final movie = movies[index];
          return GestureDetector(
            onTap: () {
              Navigator.push(
                context, 
                MaterialPageRoute(builder: (_) => MovieDetailsPage(movie: movie))
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
                const SizedBox(height: 4),
                MarqueeText(
                  text: movie.name,
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
                  width: 60,
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
