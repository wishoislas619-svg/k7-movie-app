import 'package:flutter/material.dart';
import '../../domain/entities/movie.dart';
import '../../domain/entities/category.dart';
import 'movie_details_page.dart';
import '../../../../core/constants/app_constants.dart';
import '../../../../shared/widgets/marquee_text.dart';
import 'package:movie_app/shared/widgets/energy_flow_border.dart';

class CategoryPage extends StatefulWidget {
  final Category category;
  final List<Movie> movies;

  const CategoryPage({
    super.key, 
    required this.category, 
    required this.movies
  });

  @override
  State<CategoryPage> createState() => _CategoryPageState();
}

class _CategoryPageState extends State<CategoryPage> {
  String _searchQuery = "";
  final TextEditingController _searchController = TextEditingController();

  @override
  Widget build(BuildContext context) {
    final filteredMovies = widget.movies.where((m) => m.name.toLowerCase().contains(_searchQuery.toLowerCase())).toList();

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: const Color(0xFF0A0A0A),
        elevation: 0,
        title: Text(
          widget.category.name.toUpperCase(),
          style: const TextStyle(color: Color(0xFF00A3FF), fontWeight: FontWeight.bold, letterSpacing: 2, fontSize: 16),
        ),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(60),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: TextField(
              controller: _searchController,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                hintText: 'Buscar en ${widget.category.name}...',
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
              onChanged: (value) => setState(() => _searchQuery = value),
            ),
          ),
        ),
      ),
      body: GridView.builder(
        padding: const EdgeInsets.only(left: 16, right: 16, top: 16, bottom: 40),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          crossAxisSpacing: 12,
          mainAxisSpacing: 20,
          mainAxisExtent: 220,
        ),
        itemCount: filteredMovies.length,
        itemBuilder: (context, index) {
          final movie = filteredMovies[index];
          return GestureDetector(
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
                    EnergyFlowBorder(
                      borderRadius: 16,
                      borderWidth: 1.2,
                      backgroundColor: Colors.white10,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(15),
                        child: Container(
                          width: double.infinity,
                          height: 170,
                          child: movie.imagePath.startsWith('http') 
                            ? Image.network(movie.imagePath, fit: BoxFit.cover)
                            : const Icon(Icons.movie, color: Colors.white24, size: 40),
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
                const SizedBox(height: 8),
                MarqueeText(
                  text: movie.name,
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.white),
                  width: 100,
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
