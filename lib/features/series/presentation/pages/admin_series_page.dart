import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/series_provider.dart';
import '../providers/series_category_provider.dart';
import '../../../auth/presentation/providers/auth_provider.dart';
import '../../domain/entities/series_category.dart';
import 'edit_series_page.dart';
import 'admin_popular_series_page.dart';

class AdminSeriesPage extends ConsumerStatefulWidget {
  const AdminSeriesPage({super.key});

  @override
  ConsumerState<AdminSeriesPage> createState() => _AdminSeriesPageState();
}

class _AdminSeriesPageState extends ConsumerState<AdminSeriesPage> {
  String _searchQuery = '';
  String? _selectedCategoryId;

  @override
  Widget build(BuildContext context) {
    final seriesAsync = ref.watch(seriesListProvider);
    final categoriesAsync = ref.watch(seriesCategoriesProvider);

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: const Color(0xFF0A0A0A),
        elevation: 0,
        title: const Text(
          'SERIES',
          style: TextStyle(color: Color(0xFF00A3FF), fontWeight: FontWeight.bold, letterSpacing: 2, fontSize: 16),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.star_border, color: Color(0xFFD400FF)),
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const AdminPopularSeriesPage())),
          ),
          IconButton(
            icon: const Icon(Icons.logout, color: Colors.white70),
            onPressed: () => ref.read(authStateProvider.notifier).logout(),
          ),
        ],
      ),
      body: Column(
        children: [
          // Filter Section
          categoriesAsync.when(
            data: (categories) => Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: [
                  Expanded(
                    flex: 2,
                    child: TextField(
                      style: const TextStyle(color: Colors.white, fontSize: 13),
                      decoration: InputDecoration(
                        hintText: 'Buscar serie...',
                        hintStyle: const TextStyle(color: Colors.white38),
                        prefixIcon: const Icon(Icons.search, color: Color(0xFF00A3FF), size: 20),
                        filled: true,
                        fillColor: Colors.white.withOpacity(0.05),
                        contentPadding: const EdgeInsets.symmetric(vertical: 0),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                      ),
                      onChanged: (val) => setState(() => _searchQuery = val),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 1,
                    child: Container(
                      height: 48,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.05),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<String>(
                          isExpanded: true,
                          dropdownColor: const Color(0xFF1E1E1E),
                          value: _selectedCategoryId,
                          hint: const Text('Categoría', style: TextStyle(color: Colors.white38, fontSize: 13)),
                          icon: const Icon(Icons.arrow_drop_down, color: Color(0xFF00A3FF)),
                          items: [
                            const DropdownMenuItem<String>(
                              value: null,
                              child: Text('Todas', style: TextStyle(color: Colors.white, fontSize: 13)),
                            ),
                            ...categories.map((c) => DropdownMenuItem(
                              value: c.id,
                              child: Text(c.name, style: const TextStyle(color: Colors.white, fontSize: 13), overflow: TextOverflow.ellipsis),
                            )),
                          ],
                          onChanged: (val) => setState(() => _selectedCategoryId = val),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            loading: () => const SizedBox.shrink(),
            error: (_, __) => const SizedBox.shrink(),
          ),
          
          Expanded(
            child: seriesAsync.when(
              data: (seriesList) => categoriesAsync.when(
                data: (categories) {
                  final filteredSeries = seriesList.where((s) {
                    final matchesQuery = s.name.toLowerCase().contains(_searchQuery.toLowerCase());
                    final matchesCat = _selectedCategoryId == null || s.categoryId == _selectedCategoryId;
                    return matchesQuery && matchesCat;
                  }).toList();

                  if (filteredSeries.isEmpty) {
                    return const Center(child: Text('No hay series que coincidan', style: TextStyle(color: Colors.white54)));
                  }

                  return ListView.builder(
                    padding: const EdgeInsets.only(bottom: 120),
                    itemCount: filteredSeries.length,
                    itemBuilder: (context, index) {
                      final series = filteredSeries[index];
                      final category = categories.cast<SeriesCategory?>().firstWhere(
                        (c) => c?.id == series.categoryId, 
                        orElse: () => null
                      );

                      return Container(
                        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.03),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: Colors.white.withOpacity(0.05)),
                        ),
                        child: ListTile(
                          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                          leading: ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: Image.network(
                              series.imagePath,
                              width: 50,
                              height: 70,
                              fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) => const Icon(Icons.movie, size: 50, color: Colors.white24),
                            ),
                          ),
                          title: Text(series.name, style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
                          subtitle: Text(category?.name ?? 'Sin Categoría', style: const TextStyle(color: Color(0xFF00A3FF), fontSize: 12)),
                          trailing: Container(
                            decoration: BoxDecoration(
                              color: Colors.white.withOpacity(0.1),
                              shape: BoxShape.circle,
                            ),
                            child: IconButton(
                              icon: const Icon(Icons.edit, color: Colors.white70, size: 20),
                              onPressed: () {
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(builder: (_) => EditSeriesPage(series: series)),
                                );
                              },
                            ),
                          ),
                        ),
                      );
                    },
                  );
                },
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (e, s) => Center(child: Text('Error: $e')),
              ),
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, s) => Center(child: Text('Error: $e')),
            ),
          ),
        ],
      ),
      floatingActionButton: Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Container(
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [Color(0xFF00A3FF), Color(0xFFD400FF)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(30),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF00A3FF).withOpacity(0.3),
                blurRadius: 10,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: FloatingActionButton(
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const EditSeriesPage()),
              );
            },
            backgroundColor: Colors.transparent,
            elevation: 0,
            foregroundColor: Colors.white,
            child: const Icon(Icons.add),
          ),
        ),
      ),
    );
  }
}
