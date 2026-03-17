import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../providers.dart';
import '../providers/series_provider.dart';
import '../../domain/entities/series.dart';

class AdminPopularSeriesPage extends ConsumerStatefulWidget {
  const AdminPopularSeriesPage({super.key});

  @override
  ConsumerState<AdminPopularSeriesPage> createState() => _AdminPopularSeriesPageState();
}

class _AdminPopularSeriesPageState extends ConsumerState<AdminPopularSeriesPage> {
  String _searchQuery = "";
  final TextEditingController _searchController = TextEditingController();

  @override
  Widget build(BuildContext context) {
    final seriesAsync = ref.watch(seriesListProvider);

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: const Color(0xFF0A0A0A),
        elevation: 0,
        title: const Text(
          'SERIES POPULARES',
          style: TextStyle(color: Color(0xFFD400FF), fontWeight: FontWeight.bold, letterSpacing: 2, fontSize: 16),
        ),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(60),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: TextField(
              controller: _searchController,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                hintText: 'Buscar serie...',
                hintStyle: const TextStyle(color: Colors.white38),
                prefixIcon: const Icon(Icons.search, color: Colors.white70),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: Colors.white.withOpacity(0.1)),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: Color(0xFFD400FF)),
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
      body: seriesAsync.when(
        data: (allSeries) {
          final filteredSeries = allSeries.where((s) => s.name.toLowerCase().contains(_searchQuery)).toList();
          final popularCount = allSeries.where((s) => s.isPopular).length;

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
                  itemCount: filteredSeries.length,
                  itemBuilder: (context, index) {
                    final series = filteredSeries[index];
                    return Container(
                      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.03),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: series.isPopular 
                            ? const Color(0xFFD400FF).withOpacity(0.5) 
                            : Colors.white.withOpacity(0.05)
                        ),
                      ),
                      child: CheckboxListTile(
                        title: Text(series.name, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                        secondary: ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: Image.network(
                            series.imagePath,
                            width: 40,
                            height: 60,
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => const Icon(Icons.live_tv, size: 40, color: Colors.white24),
                          ),
                        ),
                        value: series.isPopular,
                        activeColor: const Color(0xFFD400FF),
                        checkColor: Colors.white,
                        onChanged: (val) async {
                          if (val == true && popularCount >= 10) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('Límite de 10 series alcanzado')),
                            );
                            return;
                          }
                          
                          final updatedSeries = Series(
                            id: series.id,
                            name: series.name,
                            imagePath: series.imagePath,
                            categoryId: series.categoryId,
                            description: series.description,
                            detailsUrl: series.detailsUrl,
                            backdrop: series.backdrop,
                            backdropUrl: series.backdropUrl,
                            views: series.views,
                            rating: series.rating,
                            year: series.year,
                            isPopular: val ?? false,
                            createdAt: series.createdAt,
                          );

                          await ref.read(seriesRepositoryProvider).updateSeries(updatedSeries);
                          ref.invalidate(seriesListProvider);
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
