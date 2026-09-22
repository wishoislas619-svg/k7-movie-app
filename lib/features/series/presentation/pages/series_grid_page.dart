import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'dart:async';
import '../providers/series_provider.dart';
import '../providers/series_category_provider.dart';
import '../../domain/entities/series.dart';
import '../../domain/entities/series_category.dart';
import 'series_details_page.dart';
import '../../../../shared/widgets/energy_flow_border.dart';
import '../../../../shared/widgets/vip_promo_widgets.dart';
import 'package:movie_app/features/addons/presentation/pages/addons_manager_page.dart';
import 'package:movie_app/features/addons/presentation/pages/smart_search_page.dart';
import 'package:movie_app/features/addons/presentation/pages/stream_list_page.dart';
import 'package:movie_app/core/services/tmdb_service.dart';
import 'package:movie_app/core/services/storage_service.dart';
import 'package:movie_app/core/constants/app_constants.dart';
import 'series_category_page.dart';
import '../../../../shared/widgets/marquee_text.dart';
import '../../../../shared/widgets/tv_focus_wrapper.dart';
import '../../../../shared/utils/responsive_layout.dart';

class SeriesGridPage extends ConsumerStatefulWidget {
  const SeriesGridPage({super.key});

  @override
  ConsumerState<SeriesGridPage> createState() => _SeriesGridPageState();
}

class _SeriesGridPageState extends ConsumerState<SeriesGridPage> {
  final PageController _carouselController = PageController();
  int _currentCarouselPage = 0;
  String? _selectedCategoryFilter;
  bool _isSearching = false;
  String _searchQuery = "";
  final TextEditingController _searchController = TextEditingController();
  Timer? _searchDebounce;
  // Secciones inteligentes TMDB (van directo a enlaces, no a detalles).
  List<Map<String, dynamic>> _premieres = [];
  List<Map<String, dynamic>> _topRated = [];
  List<Map<String, dynamic>> _actionClassics = [];
  List<Map<String, dynamic>> _horrorClassics = [];

  @override
  void initState() {
    super.initState();
    _loadSmartSections();
  }

  Future<void> _loadSmartSections() async {
    final results = await Future.wait([
      TmdbService.getOnAirSeries(),
      TmdbService.getTopRatedSeries(),
      TmdbService.getClassicSeriesByGenre('10759'),
      TmdbService.getClassicSeriesByGenre('9648'),
    ]);
    if (mounted) {
      setState(() {
        _premieres = results[0];
        _topRated = results[1];
        _actionClassics = results[2];
        _horrorClassics = results[3];
      });
    }
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchController.dispose();
    _carouselController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final seriesAsync = ref.watch(seriesListProvider);
    final categoriesAsync = ref.watch(seriesCategoriesProvider);

    return Scaffold(
      resizeToAvoidBottomInset: false,
      backgroundColor: Colors.black,
      endDrawer: Consumer(
        builder: (context, ref, _) {
          final cats = ref.watch(seriesCategoriesProvider);
          return cats.when(
            data: (categories) => _buildOptionsDrawer(categories),
            loading: () => const Drawer(
              backgroundColor: Color(0xFF0A0A0A),
              child: Center(
                child: CircularProgressIndicator(color: Color(0xFFD400FF)),
              ),
            ),
            error: (e, _) => Drawer(
              backgroundColor: const Color(0xFF0A0A0A),
              child: Center(
                child: Text('Error: $e',
                    style: const TextStyle(color: Colors.white)),
              ),
            ),
          );
        },
      ),
      body: seriesAsync.when(
        data: (allSeries) {
          // Filtering logic
          var filteredSeries = allSeries;
          if (_selectedCategoryFilter != null) {
            filteredSeries = allSeries.where((s) => s.categoryId == _selectedCategoryFilter).toList();
          }
          if (_searchQuery.isNotEmpty) {
            filteredSeries = filteredSeries.where((s) => s.name.toLowerCase().contains(_searchQuery.toLowerCase())).toList();
          }

          final popularSeries = filteredSeries.where((m) => m.isPopular).toList();
          if (popularSeries.isEmpty && filteredSeries.isNotEmpty) {
            popularSeries.add(filteredSeries.first);
          }
          
          return categoriesAsync.when(
            data: (categories) {
               return RepaintBoundary(
                child: RefreshIndicator(
                onRefresh: () async {
                  await ref.read(seriesListProvider.notifier).loadSeries();
                  await ref.read(seriesCategoriesProvider.notifier).loadCategories();
                  await _loadSmartSections();
                },
                color: const Color(0xFF00A3FF),
                backgroundColor: const Color(0xFF1A1A1A),
                child: CustomScrollView(
                  slivers: [
                    _buildHeader(categories),
                    if (_isSearching)
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                          child: TextField(
                            controller: _searchController,
                            autofocus: true,
                            autocorrect: false,
                            enableSuggestions: false,
                            textInputAction: TextInputAction.search,
                            style: const TextStyle(color: Colors.white),
                            decoration: InputDecoration(
                              hintText: 'Buscar series...',
                              hintStyle: const TextStyle(color: Colors.white38),
                              prefixIcon: const Icon(Icons.search, color: Color(0xFFD400FF)),
                              suffixIcon: IconButton(
                                icon: const Icon(Icons.close, color: Colors.white70),
                                onPressed: () {
                                  setState(() {
                                    _isSearching = false;
                                    _searchQuery = "";
                                    _searchController.clear();
                                  });
                                },
                              ),
                              filled: true,
                              fillColor: Colors.white.withOpacity(0.05),
                              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                            ),
                            onChanged: (val) {
                                // Búsqueda LOCAL en la lista ya cargada, con
                                // debounce para no re-filtrar/reconstruir el
                                // grid en cada tecla (evita que se trabe).
                                _searchDebounce?.cancel();
                                _searchDebounce = Timer(
                                  const Duration(milliseconds: 250),
                                  () {
                                    if (!mounted) return;
                                    setState(() => _searchQuery = val.trim());
                                  },
                                );
                              },
                          ),
                        ),
                      ),
                      if (popularSeries.isNotEmpty && !_isSearching && _selectedCategoryFilter == null)
                        SliverToBoxAdapter(
                          child: _buildCarousel(popularSeries, context),
                        ),
                    if (_isSearching || _selectedCategoryFilter != null)
                        // Grid perezoso (SliverGrid): solo construye los
                        // resultados visibles. El GridView con shrinkWrap
                        // dentro del SliverList construía TODOS los pósters
                        // (Image.network) de una vez → se realentizaba con el
                        // teclado activo. SliverGrid construye de forma perezosa.
                        SliverPadding(
                          padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
                          sliver: SliverGrid(
                            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: ResponsiveLayout.getGridCrossAxisCount(context),
                              crossAxisSpacing: 12,
                              mainAxisSpacing: 20,
                              mainAxisExtent: ResponsiveLayout.getPosterHeight(context) + 60,
                            ),
                            delegate: SliverChildBuilderDelegate(
                              (context, index) => _buildSeriesCard(context, filteredSeries[index]),
                              childCount: filteredSeries.length,
                            ),
                          ),
                        )
                      else
                        SliverPadding(
                          padding: const EdgeInsets.only(top: 0, bottom: 10),
                          sliver: SliverList(
                            delegate: SliverChildListDelegate([
                              if (_selectedCategoryFilter == null &&
                                  !_isSearching) ...[
                                if (_premieres.isNotEmpty)
                                  _buildSmartSection(
                                    title: 'RECIÉN ESTRENADAS',
                                    items: _premieres,
                                  ),
                                if (_topRated.isNotEmpty)
                                  _buildSmartSection(
                                    title: 'MEJOR VALORADAS',
                                    items: _topRated,
                                  ),
                                if (_actionClassics.isNotEmpty)
                                  _buildSmartSection(
                                    title: 'CLÁSICAS DE ACCIÓN',
                                    items: _actionClassics,
                                  ),
                                if (_horrorClassics.isNotEmpty)
                                  _buildSmartSection(
                                    title: 'CLÁSICAS DE TERROR',
                                    items: _horrorClassics,
                                  ),
                              ],
                              // Modo lite: se ocultan las secciones manuales
                              // de la base (Recién agregadas + categorías).
                              if (!AppConfig.liteMode &&
                                  filteredSeries.isNotEmpty) ...[
                                _buildSeriesSection(
                                  context, 
                                  'RECIÉN AGREGADAS', 
                                  filteredSeries.where((s) => true).toList()..sort((a,b) => b.createdAt.compareTo(a.createdAt)),
                                  category: SeriesCategory(id: 'recent', name: 'Recién agregadas'),
                                ),
                              ],
                              if (!AppConfig.liteMode)
                                ...categories.map((cat) {
                                  final catSeries = filteredSeries.where((m) => m.categoryId == cat.id).toList();
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
                  ),
              ),
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

  Widget _buildHeader(List<SeriesCategory> categories) {
    return SliverAppBar(
      backgroundColor: Colors.black.withOpacity(0.5),
      floating: true,
      elevation: 0,
      title: const Row(
        children: [
          K7AppBarTitle(
            title: 'SERIES',
            gradientColors: [Color(0xFF4A90FF), Color(0xFFBC00FF)],
          ),
        ],
      ),
      actions: [
        // A la izquierda: buscador inteligente. El resto vive en el menú ⋮.
        IconButton(
          icon: const Icon(Icons.travel_explore, color: Color(0xFFD400FF)),
          tooltip: 'Búsqueda inteligente',
          onPressed: () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => const SmartSearchPage(),
              ),
            );
          },
        ),
        Builder(
          builder: (ctx) => IconButton(
            icon: const Icon(Icons.more_vert, color: Colors.white70),
            tooltip: 'Opciones',
            onPressed: () => Scaffold.of(ctx).openEndDrawer(),
          ),
        ),
      ],
    );
  }

  /// Drawer lateral derecho: filtro de categorías, addons y buscador.
  Widget _buildOptionsDrawer(List<SeriesCategory> categories) {
    return Drawer(
      backgroundColor: const Color(0xFF0A0A0A),
      // Drawer ancho (casi toda la pantalla) para que el desplegable
      // de categorías tenga el doble de espacio.
      width: MediaQuery.of(context).size.width * 0.88,
      child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(12),
          children: [
            const Text(
              'OPCIONES',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                letterSpacing: 2,
                fontSize: 15,
              ),
            ),
            const SizedBox(height: 4),
            const Text(
              'Filtros y accesos',
              style: TextStyle(color: Colors.white38, fontSize: 12),
            ),
            const SizedBox(height: 20),
            // Modo lite: sin selector de categorías manuales.
            if (!AppConfig.liteMode) ...[
              const Text(
                'Categoría',
                style: TextStyle(
                  color: Colors.white70,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              EnergyFlowBorder(
                borderRadius: 12,
                borderWidth: 1.2,
                backgroundColor: Colors.black,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String?>(
                    value: _selectedCategoryFilter,
                    isExpanded: true,
                    dropdownColor: Colors.black,
                    borderRadius: BorderRadius.circular(14),
                    icon: const Icon(
                      Icons.filter_list,
                      color: Color(0xFFD400FF),
                    ),
                    menuMaxHeight: 320,
                    itemHeight: 64,
                    selectedItemBuilder: (BuildContext context) {
                      return [
                        const Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            'Todas',
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: Colors.white),
                          ),
                        ),
                        ...categories.map(
                          (c) => Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              c.name,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(color: Colors.white),
                            ),
                          ),
                        ),
                      ];
                    },
                    items: [
                      const DropdownMenuItem(
                        value: null,
                        child: Text(
                          'Todas',
                          style: TextStyle(color: Colors.white),
                        ),
                      ),
                      ...categories.map(
                        (c) => DropdownMenuItem(
                          value: c.id,
                          child: Text(
                            c.name,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: Colors.white),
                          ),
                        ),
                      ),
                    ],
                    onChanged: (val) =>
                        setState(() => _selectedCategoryFilter = val),
                  ),
                ),
              ),
              const SizedBox(height: 8),
            ],
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading:
                  const Icon(Icons.extension, color: Color(0xFFD400FF)),
              title: const Text(
                'Configurar addons',
                style: TextStyle(color: Colors.white),
              ),
              onTap: () {
                Navigator.pop(context);
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const AddonsManagerPage(),
                  ),
                );
              },
            ),
            // Modo lite: sin búsqueda local (los pósters usan el inteligente).
            if (!AppConfig.liteMode)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.search, color: Colors.white70),
                title: const Text(
                  'Buscar series',
                  style: TextStyle(color: Colors.white),
                ),
                onTap: () {
                  Navigator.pop(context);
                  setState(() => _isSearching = true);
                },
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildCarousel(List<Series> popularSeries, BuildContext context) {
    return Column(
      children: [
        SizedBox(
          height: ResponsiveLayout.getCarouselHeight(context),
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
              width: _currentCarouselPage == index ? 10 : 8,
              height: _currentCarouselPage == index ? 10 : 8,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _currentCarouselPage == index ? const Color(0xFF00A3FF) : Colors.white24,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildCarouselItem(Series series) {
    return TvFocusWrapper(
      onTap: () {
        // Modo lite: el carrusel (tendencia) busca en el inteligente.
        if (AppConfig.liteMode) {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => SmartSearchPage(initialQuery: series.name),
            ),
          );
          return;
        }
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => SeriesDetailsPage(series: series)),
        );
      },
      borderRadius: 25,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 5),
        child: EnergyFlowBorder(
          borderRadius: 25,
          borderWidth: 1.5,
          backgroundColor: Colors.transparent,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(24),
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
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.transparent,
                      Colors.black.withOpacity(0.4),
                      Colors.black.withOpacity(0.9),
                    ],
                  ),
                ),
              ),
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: Container(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'EN TENDENCIA',
                        style: TextStyle(color: Color(0xFF00E5FF), fontWeight: FontWeight.bold, letterSpacing: 1.2, fontSize: 11),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        series.name.toUpperCase(),
                        style: const TextStyle(color: Colors.white, fontSize: 26, fontWeight: FontWeight.w900, height: 1.1),
                      ),
                      const SizedBox(height: 10),
                      if (series.description != null)
                        Text(
                          series.description!,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: Colors.white.withOpacity(0.7), fontSize: 13),
                        ),
                      const SizedBox(height: 20),
                      Row(
                        children: [
                          Expanded(
                            child: Container(
                              height: 48,
                              decoration: BoxDecoration(
                                gradient: const LinearGradient(
                                  colors: [Color(0xFF00A3FF), Color(0xFFD400FF)],
                                ),
                                borderRadius: BorderRadius.circular(12),
                                boxShadow: [
                                  BoxShadow(
                                    color: const Color(0xFF00A3FF).withOpacity(0.35),
                                    blurRadius: 15,
                                    offset: const Offset(0, 8),
                                  ),
                                ],
                              ),
                              child: ElevatedButton.icon(
                                onPressed: () {
                                  // Modo lite: buscar en el inteligente.
                                  if (AppConfig.liteMode) {
                                    Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                        builder: (_) => SmartSearchPage(
                                            initialQuery: series.name),
                                      ),
                                    );
                                    return;
                                  }
                                  Navigator.push(
                                    context,
                                    MaterialPageRoute(builder: (_) => SeriesDetailsPage(series: series)),
                                  );
                                },
                                icon: const Icon(Icons.play_arrow, size: 20, color: Colors.white),
                                label: const Text('Play Now', style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1.1, color: Colors.white)),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.transparent,
                                  shadowColor: Colors.transparent,
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
    );
  }

  /// Abre un título inteligente directo en la pantalla de enlaces
  /// torrent/addon (solo estas secciones se saltan los detalles).
  Future<void> _openSmartItem(Map<String, dynamic> s) async {
    StorageService.saveSearchEntry(s);
    if (!mounted) return;
    // Modo lite: buscar el título en el buscador inteligente.
    if (AppConfig.liteMode) {
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => SmartSearchPage(
            initialQuery: s['name'] as String? ?? '',
          ),
        ),
      );
      return;
    }
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => StreamListPage(
          movieName: s['name'] as String? ?? 'Serie',
          poster: s['image'] as String? ?? '',
          year: s['year'] as String?,
          tmdbId: '${s['tmdbId']}',
          isSeries: true,
        ),
      ),
    );
  }

  /// Sección inteligente TMDB (top 20). Póster con borde tornasol animado;
  /// al tocar va directo a enlaces.
  Widget _buildSmartSection({
    required String title,
    required List<Map<String, dynamic>> items,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(
            left: 20,
            right: 10,
            top: 4,
            bottom: 8,
          ),
          child: Row(
            children: [
              Container(
                width: 4,
                height: 16,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(2),
                  gradient: const LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Color(0xFF00A3FF), Color(0xFFD400FF)],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                title,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                  letterSpacing: 1.2,
                ),
              ),
            ],
          ),
        ),
        SizedBox(
          height: 210,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: items.length,
            itemBuilder: (context, index) {
              final s = items[index];
              final image = s['image'] as String? ?? '';
              final name = s['name'] as String? ?? '';
              // TvFocusWrapper: alcanzable con flechas del control remoto.
              return TvFocusWrapper(
                onTap: () => _openSmartItem(s),
                borderRadius: 12,
                child: Container(
                  width: 120,
                  margin: const EdgeInsets.only(right: 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      EnergyFlowBorder(
                        borderRadius: 12,
                        borderWidth: 1.2,
                        backgroundColor: const Color(0xFF1A1A1A),
                        child: SizedBox(
                          height: 150,
                          width: double.infinity,
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(10),
                            child: image.isEmpty
                                ? const Center(
                                    child: Icon(
                                      Icons.tv,
                                      color: Colors.white24,
                                      size: 32,
                                    ),
                                  )
                                : Image.network(
                                    image,
                                    fit: BoxFit.cover,
                                    errorBuilder: (_, __, ___) =>
                                        const Center(
                                      child: Icon(
                                        Icons.broken_image_outlined,
                                        color: Colors.white24,
                                        size: 32,
                                      ),
                                    ),
                                  ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          height: 1.2,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 4),
      ],
    );
  }

  Widget _buildSeriesSection(BuildContext context, String title, List<Series> seriesList, {SeriesCategory? category}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 20, right: 10, top: 4, bottom: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Container(
                    width: 4,
                    height: 16,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(2),
                      gradient: const LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Color(0xFF00A3FF), Color(0xFFD400FF)],
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    title,
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.white, letterSpacing: 1.2),
                  ),
                ],
              ),
              if (category != null)
                TextButton(
                  onPressed: () {
                    Navigator.push(
                      context, 
                      MaterialPageRoute(builder: (_) => SeriesCategoryPage(category: category, seriesList: seriesList))
                    );
                  },
                  child: const Text('VIEW ALL', style: TextStyle(color: Colors.white38, fontSize: 10, fontWeight: FontWeight.bold)),
                ),
            ],
          ),
        ),
        SizedBox(
          height: ResponsiveLayout.getPosterHeight(context) + 60,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: seriesList.length,
            itemBuilder: (context, index) {
              return _buildSeriesCard(context, seriesList[index]);
            },
          ),
        ),
        const SizedBox(height: 4),
      ],
    );
  }

  Widget _buildSeriesCard(BuildContext context, Series series) {
    final double cardWidth = ResponsiveLayout.getPosterWidth(context);
    final double cardHeight = ResponsiveLayout.getPosterHeight(context);
    
    return TvFocusWrapper(
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => SeriesDetailsPage(series: series)),
        );
      },
      borderRadius: 16,
      child: Container(
        width: cardWidth,
        margin: const EdgeInsets.only(right: 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Stack(
              children: [
                EnergyFlowBorder(
                  borderRadius: 16,
                  borderWidth: 1.2,
                  backgroundColor: Colors.white12,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(15),
                    child: Image.network(
                      (ResponsiveLayout.isLandscape(context) && series.backdropUrl?.isNotEmpty == true)
                          ? series.backdropUrl!
                          : series.imagePath,
                      width: cardWidth,
                      height: cardHeight,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => Container(
                         width: cardWidth,
                         height: cardHeight,
                         color: Colors.white12,
                         child: const Center(child: Icon(Icons.live_tv, size: 40, color: Colors.white24))
                      ),
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
              style: TextStyle(
                fontSize: ResponsiveLayout.isLandscape(context) ? 13 : 16, 
                fontWeight: FontWeight.bold, 
                color: Colors.white
              ),
              width: cardWidth,
            ),
          ],
        ),
      ),
    );
  }
}
