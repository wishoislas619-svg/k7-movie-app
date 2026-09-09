import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/services/storage_service.dart';
import '../../../../core/services/tmdb_service.dart';
import '../../../addons/presentation/pages/stream_list_page.dart';

class SmartSearchPage extends ConsumerStatefulWidget {
  const SmartSearchPage({super.key});

  @override
  ConsumerState<SmartSearchPage> createState() => _SmartSearchPageState();
}

class _SmartSearchPageState extends ConsumerState<SmartSearchPage> {
  final TextEditingController _controller = TextEditingController();
  Timer? _debounce;
  List<Map<String, dynamic>> _results = [];
  List<Map<String, dynamic>> _history = [];
  bool _historyLoaded = false;
  bool _loading = false;
  bool _searched = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadHistory();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  Future<void> _loadHistory() async {
    final history = await StorageService.loadSearchHistory();
    if (mounted) {
      setState(() {
        _history = history;
        _historyLoaded = true;
      });
    }
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    if (value.trim().isEmpty) {
      setState(() {
        _results = [];
        _searched = false;
        _loading = false;
      });
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 500), () => _search(value));
  }

  Future<void> _search(String query) async {
    setState(() {
      _loading = true;
      _error = null;
      _searched = true;
    });
    try {
      final movies = await TmdbService.searchMovies(query);
      final series = await TmdbService.searchSeries(query);
      if (mounted) {
        setState(() {
          _results = [...movies, ...series];
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = 'Error buscando: $e';
          _loading = false;
        });
      }
    }
  }

  Future<void> _openResult(Map<String, dynamic> movie) async {
    // Persiste la búsqueda localmente (últimas 20) para acceder rápido.
    StorageService.saveSearchEntry(movie);
    final rawType = (movie['mediaType'] as String?)?.toLowerCase() ?? '';
    final isSeries = rawType == 'series' || rawType == 'tv' || rawType.contains('series');
    if (mounted) {
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => StreamListPage(
            movieName: movie['name'] as String? ?? 'Película',
            poster: movie['image'] as String? ?? '',
            year: movie['year'] as String?,
            tmdbId: '${movie['tmdbId']}',
            isSeries: isSeries,
          ),
        ),
      );
    }
    _loadHistory();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: const Text('Búsqueda inteligente',
            style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1.5)),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(
              controller: _controller,
              onChanged: _onChanged,
              style: const TextStyle(color: Colors.white, fontSize: 16),
              decoration: InputDecoration(
                hintText: 'Buscar películas o series...',
                hintStyle: const TextStyle(color: Colors.white38),
                prefixIcon: const Icon(Icons.search, color: Color(0xFF00A3FF)),
                filled: true,
                fillColor: const Color(0xFF1A1A1A),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          Expanded(child: _buildBody()),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(
        child: CircularProgressIndicator(color: Color(0xFF00A3FF)),
      );
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(_error!,
              style: const TextStyle(color: Colors.redAccent),
              textAlign: TextAlign.center),
        ),
      );
    }
    if (!_searched) {
      if (!_historyLoaded) {
        return const Center(
          child: CircularProgressIndicator(color: Color(0xFF00A3FF)),
        );
      }
      if (_history.isNotEmpty) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Búsquedas recientes',
                      style: TextStyle(
                          color: Colors.white70,
                          fontSize: 13,
                          fontWeight: FontWeight.w600),
                    ),
                  ),
                  TextButton.icon(
                    onPressed: () async {
                      await StorageService.clearSearchHistory();
                      if (mounted) {
                        setState(() => _history = []);
                      }
                    },
                    icon: const Icon(Icons.delete_outline,
                        size: 16, color: Colors.white54),
                    label: const Text('Borrar',
                        style: TextStyle(
                            color: Colors.white54, fontSize: 12)),
                  ),
                ],
              ),
            ),
            Expanded(
              child: GridView.builder(
                padding: const EdgeInsets.all(16),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3,
                  childAspectRatio: 0.58,
                  crossAxisSpacing: 10,
                  mainAxisSpacing: 10,
                ),
                itemCount: _history.length,
                itemBuilder: (context, index) {
                  final movie = _history[index];
                  return _MovieCard(
                      movie: movie, onTap: () => _openResult(movie));
                },
              ),
            ),
          ],
        );
      }
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: const [
            Icon(Icons.travel_explore, color: Colors.white24, size: 64),
            SizedBox(height: 16),
            Text(
              'Escribe un nombre para buscar coincidencias\nen la base de datos de TMDB.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white38),
            ),
          ],
        ),
      );
    }
    if (_results.isEmpty) {
      return const Center(
        child: Text('Sin resultados.',
            style: TextStyle(color: Colors.white38)),
      );
    }
    return GridView.builder(
      padding: const EdgeInsets.all(16),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        childAspectRatio: 0.58,
        crossAxisSpacing: 10,
        mainAxisSpacing: 10,
      ),
      itemCount: _results.length,
      itemBuilder: (context, index) {
        final movie = _results[index];
        return _MovieCard(movie: movie, onTap: () => _openResult(movie));
      },
    );
  }
}

class _MovieCard extends StatelessWidget {
  final Map<String, dynamic> movie;
  final VoidCallback onTap;
  const _MovieCard({required this.movie, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final image = movie['image'] as String? ?? '';
    final name = movie['name'] as String? ?? '';
    final year = movie['year'] as String? ?? '';
    final rating = (movie['rating'] as num?)?.toDouble() ?? 0;

    return GestureDetector(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Container(
              width: double.infinity,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                color: const Color(0xFF1A1A1A),
              ),
              clipBehavior: Clip.antiAlias,
              child: image.isEmpty
                  ? const Center(
                      child: Icon(Icons.movie_outlined,
                          color: Colors.white24, size: 32),
                    )
                  : Image.network(
                      image,
                      fit: BoxFit.cover,
                      loadingBuilder: (c, child, progress) => progress == null
                          ? child
                          : const Center(
                              child: CircularProgressIndicator(
                                  color: Color(0xFF00A3FF), strokeWidth: 2),
                            ),
                      errorBuilder: (c, e, s) => const Center(
                        child: Icon(Icons.broken_image_outlined,
                            color: Colors.white24, size: 32),
                      ),
                    ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white, fontSize: 12, height: 1.2),
          ),
          const SizedBox(height: 2),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (year.isNotEmpty)
                Text(year,
                    style:
                        const TextStyle(color: Colors.white54, fontSize: 11)),
              if (rating > 0)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.star, color: Colors.amber, size: 12),
                    const SizedBox(width: 2),
                    Text(rating.toStringAsFixed(1),
                        style: const TextStyle(
                            color: Colors.amber, fontSize: 11)),
                  ],
                ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                decoration: BoxDecoration(
                  color: movie['mediaType'] == 'series'
                      ? const Color(0xFF3A3A5C)
                      : const Color(0xFF0E2E4A),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  movie['mediaType'] == 'series' ? 'SERIE' : 'PELÍCULA',
                  style: const TextStyle(
                      color: Colors.white70, fontSize: 8),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
