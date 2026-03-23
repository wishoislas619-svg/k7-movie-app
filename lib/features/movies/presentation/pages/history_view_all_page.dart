import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:movie_app/features/movies/presentation/providers/history_provider.dart';
import 'package:movie_app/features/movies/domain/entities/watch_history.dart';
import 'package:movie_app/features/movies/presentation/pages/movie_details_page.dart';
import 'package:movie_app/providers.dart';
import 'package:movie_app/features/series/presentation/pages/series_details_page.dart';
import 'package:movie_app/features/series/presentation/providers/series_provider.dart';
import 'package:movie_app/features/movies/presentation/providers/movie_provider.dart';

class HistoryViewAllPage extends ConsumerStatefulWidget {
  const HistoryViewAllPage({super.key});

  @override
  ConsumerState<HistoryViewAllPage> createState() => _HistoryViewAllPageState();
}

class _HistoryViewAllPageState extends ConsumerState<HistoryViewAllPage> {
  String _searchQuery = "";
  final TextEditingController _searchController = TextEditingController();

  @override
  Widget build(BuildContext context) {
    final historyAsync = ref.watch(historyProvider);

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text('Continuar Viendo', style: TextStyle(fontWeight: FontWeight.bold)),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(60),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: TextField(
              controller: _searchController,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                hintText: 'Buscar en tu historial...',
                hintStyle: const TextStyle(color: Colors.white38),
                prefixIcon: const Icon(Icons.search, color: Color(0xFF00A3FF)),
                filled: true,
                fillColor: Colors.white.withOpacity(0.05),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
              ),
              onChanged: (val) => setState(() => _searchQuery = val),
            ),
          ),
        ),
      ),
      body: historyAsync.when(
        data: (history) {
          final Map<String, WatchHistory> uniqueHistory = {};
          for (var item in history) {
            if (!uniqueHistory.containsKey(item.mediaId)) {
              uniqueHistory[item.mediaId] = item;
            }
          }

          final filtered = uniqueHistory.values.where((item) => 
            item.title.toLowerCase().contains(_searchQuery.toLowerCase()) ||
            (item.subtitle?.toLowerCase().contains(_searchQuery.toLowerCase()) ?? false)
          ).toList();

          if (filtered.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                   Icon(Icons.history, size: 80, color: Colors.grey[800]),
                   const SizedBox(height: 16),
                   Text(
                     _searchQuery.isEmpty ? 'No tienes historial de reproducción' : 'No se encontraron resultados',
                     style: const TextStyle(color: Colors.grey),
                   ),
                ],
              ),
            );
          }

          return GridView.builder(
            padding: const EdgeInsets.all(16),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              crossAxisSpacing: 16,
              mainAxisSpacing: 20,
              mainAxisExtent: 280,
            ),
            itemCount: filtered.length,
            itemBuilder: (context, index) => _buildHistoryItem(filtered[index]),
          );
        },
        loading: () => const Center(child: CircularProgressIndicator(color: Color(0xFF00A3FF))),
        error: (e, s) => Center(child: Text('Error: $e', style: const TextStyle(color: Colors.white))),
      ),
    );
  }

  Widget _buildHistoryItem(WatchHistory item) {
    final progress = item.lastPosition / item.totalDuration;

    return GestureDetector(
      onTap: () {
        if (item.mediaType == 'movie') {
           final movie = (ref.read(moviesProvider).value ?? []).firstWhere((m) => m.id == item.mediaId);
           Navigator.push(context, MaterialPageRoute(builder: (_) => MovieDetailsPage(movie: movie)));
        } else {
           final series = (ref.read(seriesListProvider).value ?? []).firstWhere((s) => s.id == item.mediaId);
           Navigator.push(context, MaterialPageRoute(builder: (_) => SeriesDetailsPage(series: series)));
        }
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Stack(
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
                        SizedBox.expand(
                          child: Image.network(
                            item.imagePath, 
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => const Icon(Icons.movie, color: Colors.white24, size: 50),
                          ),
                        ),
                        Positioned(
                          bottom: 0,
                          left: 0,
                          right: 0,
                          child: Container(
                            height: 4,
                            width: double.infinity,
                            color: Colors.white24,
                            alignment: Alignment.centerLeft,
                            child: FractionallySizedBox(
                              widthFactor: progress.clamp(0.0, 1.0),
                              child: Container(
                                decoration: const BoxDecoration(
                                  gradient: LinearGradient(colors: [Color(0xFF00A3FF), Color(0xFFD400FF)]),
                                ),
                              ),
                            ),
                          ),
                        ),
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
                Positioned(
                  top: 8,
                  right: 8,
                  child: IconButton(
                    icon: const Icon(Icons.close, color: Colors.white, size: 20),
                    onPressed: () => ref.read(historyProvider.notifier).removeHistory(item.id),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Text(
            item.title,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Colors.white),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          if (item.subtitle != null)
            Text(
              item.subtitle!,
              style: const TextStyle(fontSize: 12, color: Colors.white54),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
        ],
      ),
    );
  }
}
