import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/series_provider.dart';
import '../providers/series_category_provider.dart';
import '../../domain/entities/series.dart';
import '../../domain/entities/series_category.dart';
import 'series_details_page.dart';
import '../../../../shared/widgets/marquee_text.dart';

class SeriesGridPage extends ConsumerStatefulWidget {
  const SeriesGridPage({super.key});

  @override
  ConsumerState<SeriesGridPage> createState() => _SeriesGridPageState();
}

class _SeriesGridPageState extends ConsumerState<SeriesGridPage> {
  final PageController _carouselController = PageController();
  int _currentCarouselPage = 0;

  @override
  void dispose() {
    _carouselController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final seriesAsync = ref.watch(seriesListProvider);
    final categoriesAsync = ref.watch(seriesCategoriesProvider);

    return Scaffold(
      backgroundColor: Colors.black,
      body: seriesAsync.when(
        data: (allSeries) {
          final popularSeries = allSeries.where((m) => m.isPopular).toList();
          if (popularSeries.isEmpty && allSeries.isNotEmpty) {
            popularSeries.add(allSeries.first);
          }
          
          return categoriesAsync.when(
            data: (categories) {
              return CustomScrollView(
                slivers: [
                  _buildHeader(),
                  if (popularSeries.isNotEmpty)
                    SliverToBoxAdapter(
                      child: _buildCarousel(popularSeries),
                    ),
                  SliverPadding(
                    padding: const EdgeInsets.only(top: 20, bottom: 100),
                    sliver: SliverList(
                      delegate: SliverChildListDelegate([
                        if (allSeries.isNotEmpty)
                          _buildSeriesSection(
                            context, 
                            'RECIÉN AGREGADAS', 
                            allSeries.take(20).toList()
                          ),
                        ...categories.map((cat) {
                          final catSeries = allSeries.where((m) => m.categoryId == cat.id).toList();
                          if (catSeries.isEmpty) return const SizedBox.shrink();
                          return _buildSeriesSection(
                            context, 
                            cat.name.toUpperCase(), 
                            catSeries,
                            category: cat
                          );
                        }),
                      ]),
                    ),
                  ),
                ],
              );
            },
            loading: () => const Center(child: CircularProgressIndicator(color: Color(0xFF00A3FF))),
            error: (e, s) => Center(child: Text('Error: $e', style: const TextStyle(color: Colors.white))),
          );
        },
        loading: () => const Center(child: CircularProgressIndicator(color: Color(0xFF00A3FF))),
        error: (e, s) => Center(child: Text('Error: $e', style: const TextStyle(color: Colors.white))),
      ),
    );
  }

  Widget _buildHeader() {
    return SliverAppBar(
      backgroundColor: Colors.black.withOpacity(0.5),
      floating: true,
      elevation: 0,
      title: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              gradient: const LinearGradient(colors: [Color(0xFF4A90FF), Color(0xFFBC00FF)]),
              borderRadius: BorderRadius.circular(4),
            ),
            child: const Text('K7', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Colors.white)),
          ),
          const SizedBox(width: 8),
          const Text('SERIES', style: TextStyle(letterSpacing: 2, fontWeight: FontWeight.normal, fontSize: 16, color: Colors.white)),
        ],
      ),
      actions: [
        IconButton(icon: const Icon(Icons.cast, color: Colors.white70), onPressed: () {}),
        IconButton(icon: const Icon(Icons.notifications_none, color: Colors.white70), onPressed: () {}),
        IconButton(icon: const Icon(Icons.search, color: Colors.white70), onPressed: () {}),
      ],
    );
  }

  Widget _buildCarousel(List<Series> popularSeries) {
    return Column(
      children: [
        SizedBox(
          height: 350,
          child: PageView.builder(
            controller: _carouselController,
            onPageChanged: (index) => setState(() => _currentCarouselPage = index),
            itemCount: popularSeries.length,
            itemBuilder: (context, index) {
              final series = popularSeries[index];
              return _buildCarouselItem(series);
            },
          ),
        ),
        const SizedBox(height: 12),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: List.generate(
            popularSeries.length,
            (index) => AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              margin: const EdgeInsets.symmetric(horizontal: 4),
              width: _currentCarouselPage == index ? 24 : 8,
              height: 8,
              decoration: BoxDecoration(
                color: _currentCarouselPage == index ? const Color(0xFF00A3FF) : Colors.white24,
                borderRadius: BorderRadius.circular(4),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildCarouselItem(Series series) {
    return GestureDetector(
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => SeriesDetailsPage(series: series)),
        );
      },
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white.withOpacity(0.1)),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF00A3FF).withOpacity(0.2),
              blurRadius: 20,
              offset: const Offset(0, 10),
            )
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(15),
          child: Stack(
            fit: StackFit.expand,
            children: [
              Image.network(
                series.backdropUrl?.isNotEmpty == true ? series.backdropUrl! : (series.backdrop?.isNotEmpty == true ? series.backdrop! : series.imagePath),
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => const Center(child: Icon(Icons.movie, size: 80, color: Colors.white24)),
              ),
              Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [Colors.black.withOpacity(0.9), Colors.transparent],
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                  ),
                ),
              ),
              Positioned(
                bottom: 24,
                left: 24,
                right: 24,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: const Color(0xFFD400FF),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: const Text('SERIE', style: TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold)),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      series.name,
                      style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(
                          child: Container(
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(30),
                              gradient: const LinearGradient(colors: [Color(0xFF00A3FF), Color(0xFFBC00FF)]),
                              boxShadow: [
                                BoxShadow(color: const Color(0xFF00A3FF).withOpacity(0.5), blurRadius: 10, offset: const Offset(0, 4)),
                              ],
                            ),
                            child: ElevatedButton.icon(
                              onPressed: () {
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(builder: (_) => SeriesDetailsPage(series: series)),
                                );
                              },
                              icon: const Icon(Icons.play_arrow, color: Colors.white),
                              label: const Text('Comenzar a ver', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.transparent,
                                shadowColor: Colors.transparent,
                                padding: const EdgeInsets.symmetric(vertical: 12),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 16),
                        Container(
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: Colors.white.withOpacity(0.1),
                          ),
                          child: IconButton(
                            icon: const Icon(Icons.add, color: Colors.white),
                            onPressed: () {},
                          ),
                        )
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSeriesSection(BuildContext context, String title, List<Series> seriesList, {SeriesCategory? category}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 20, right: 10, bottom: 12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                title,
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.white, letterSpacing: 1.2),
              ),
              IconButton(icon: const Icon(Icons.arrow_forward_ios, color: Colors.white54, size: 14), onPressed: () {}),
            ],
          ),
        ),
        SizedBox(
          height: 250,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: seriesList.length,
            itemBuilder: (context, index) {
              return _buildSeriesCard(context, seriesList[index]);
            },
          ),
        ),
        const SizedBox(height: 16),
      ],
    );
  }

  Widget _buildSeriesCard(BuildContext context, Series series) {
    return GestureDetector(
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => SeriesDetailsPage(series: series)),
        );
      },
      child: Container(
        width: 130,
        margin: const EdgeInsets.only(right: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Stack(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Image.network(
                    series.imagePath,
                    width: 130,
                    height: 190,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => Container(
                       width: 130,
                       height: 190,
                       color: Colors.white12,
                       child: const Center(child: Icon(Icons.live_tv, size: 40, color: Colors.white24))
                    ),
                  ),
                ),
                Positioned(
                  top: 8,
                  left: 8,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                    decoration: BoxDecoration(
                      color: const Color(0xFFD400FF),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: const Text('SERIE', style: TextStyle(color: Colors.white, fontSize: 8, fontWeight: FontWeight.bold)),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            MarqueeText(
              text: series.name,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white),
              width: 130,
            ),
          ],
        ),
      ),
    );
  }
}
