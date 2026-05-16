import 'package:flutter/material.dart';
import '../../domain/entities/series.dart';
import '../../domain/entities/series_category.dart';
import 'series_details_page.dart';
import '../../../../shared/widgets/marquee_text.dart';
import '../../../../shared/widgets/energy_flow_border.dart';
import '../../../../shared/utils/responsive_layout.dart';

class SeriesCategoryPage extends StatefulWidget {
  final SeriesCategory category;
  final List<Series> seriesList;

  const SeriesCategoryPage({
    super.key, 
    required this.category, 
    required this.seriesList
  });

  @override
  State<SeriesCategoryPage> createState() => _SeriesCategoryPageState();
}

class _SeriesCategoryPageState extends State<SeriesCategoryPage> {
  String _searchQuery = "";
  final TextEditingController _searchController = TextEditingController();

  @override
  Widget build(BuildContext context) {
    final filteredSeries = widget.seriesList.where((s) => s.name.toLowerCase().contains(_searchQuery.toLowerCase())).toList();

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: const Color(0xFF0A0A0A),
        elevation: 0,
        title: Text(
          widget.category.name.toUpperCase(),
          style: const TextStyle(color: Color(0xFFD400FF), fontWeight: FontWeight.bold, letterSpacing: 2, fontSize: 16),
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
                  borderSide: const BorderSide(color: Color(0xFFD400FF)),
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
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: ResponsiveLayout.getGridCrossAxisCount(context),
          crossAxisSpacing: 12,
          mainAxisSpacing: 20,
          mainAxisExtent: ResponsiveLayout.getPosterHeight(context) + 50,
        ),
        itemCount: filteredSeries.length,
        itemBuilder: (context, index) {
          final series = filteredSeries[index];
          return GestureDetector(
            onTap: () {
              Navigator.push(
                context, 
                MaterialPageRoute(builder: (_) => SeriesDetailsPage(series: series))
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
                        child: SizedBox(
                          width: double.infinity,
                          height: ResponsiveLayout.getPosterHeight(context),
                          child: Image.network(
                            (ResponsiveLayout.isLandscape(context) && series.backdropUrl?.isNotEmpty == true)
                                ? series.backdropUrl!
                                : series.imagePath,
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => const Icon(Icons.live_tv, color: Colors.white24, size: 40),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                MarqueeText(
                  text: series.name,
                  style: TextStyle(
                    fontSize: ResponsiveLayout.isLandscape(context) ? 12 : 14, 
                    fontWeight: FontWeight.bold, 
                    color: Colors.white
                  ),
                  width: double.infinity,
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
