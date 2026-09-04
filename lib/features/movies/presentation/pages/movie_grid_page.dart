import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'dart:async';
import 'dart:io';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:movie_app/features/movies/presentation/providers/movie_provider.dart';
import 'package:movie_app/features/movies/presentation/providers/category_provider.dart';
import 'package:movie_app/features/movies/domain/entities/movie.dart';
import 'package:movie_app/features/movies/domain/entities/category.dart';
import 'package:movie_app/features/movies/presentation/pages/movie_details_page.dart';
import 'package:movie_app/features/movies/presentation/pages/category_page.dart';
import 'package:movie_app/core/constants/app_constants.dart';
import 'package:movie_app/features/auth/presentation/providers/auth_provider.dart';
import 'package:movie_app/shared/widgets/marquee_text.dart';
import 'package:movie_app/features/movies/presentation/pages/downloads_page.dart';
import 'package:movie_app/features/series/presentation/pages/series_grid_page.dart';
import 'package:movie_app/features/tv/presentation/pages/tv_channels_page.dart';
import 'package:movie_app/features/auth/presentation/pages/profile_page.dart';
import 'package:movie_app/features/movies/presentation/providers/history_provider.dart';
import 'package:movie_app/features/movies/domain/entities/watch_history.dart';
import 'package:movie_app/features/series/domain/entities/series.dart';
import 'package:movie_app/features/series/domain/entities/episode.dart';
import 'package:movie_app/features/series/presentation/pages/series_details_page.dart';
import 'package:movie_app/features/movies/presentation/pages/history_view_all_page.dart';
import 'package:movie_app/features/series/presentation/providers/series_provider.dart';
import 'package:movie_app/features/player/presentation/pages/video_player_page.dart';
import 'package:movie_app/features/cast/presentation/widgets/cast_button.dart';
import 'package:movie_app/providers.dart';
import 'package:movie_app/shared/widgets/energy_flow_border.dart';
import 'package:movie_app/shared/widgets/tv_focus_wrapper.dart';
import 'package:movie_app/shared/utils/responsive_layout.dart';
import 'package:movie_app/shared/widgets/vip_promo_widgets.dart';
import 'package:movie_app/core/services/vip_promo_service.dart';
import 'package:movie_app/features/addons/presentation/pages/addons_manager_page.dart';
import 'package:movie_app/features/addons/presentation/pages/smart_search_page.dart';
import 'package:movie_app/features/addons/presentation/pages/stream_list_page.dart';
import 'package:movie_app/features/addons/data/datasources/torrent_streaming_service.dart';
import 'package:movie_app/features/addons/domain/entities/torrent_stream.dart';
import 'package:movie_app/features/addons/presentation/providers/addons_provider.dart';
import 'package:movie_app/shared/widgets/torrent_loading_dialog.dart';

class MovieGridPage extends ConsumerStatefulWidget {
  const MovieGridPage({super.key});

  @override
  ConsumerState<MovieGridPage> createState() => _MovieGridPageState();
}

class _MovieGridPageState extends ConsumerState<MovieGridPage> {
  final PageController _carouselController = PageController();
  final PageController _pageController = PageController();
  int _currentCarouselPage = 0;
  int _currentTabIndex = 0;
  String? _selectedCategoryFilter;
  bool _isSearching = false;
  String _searchQuery = "";
  final TextEditingController _searchController = TextEditingController();
  Timer? _searchDebounce;
  static bool _batteryDialogShown = false;
  static bool _vipPromoShown = false;
  // Torrents cuyo startStreaming ya está en curso (por mediaId) para evitar
  // que un segundo tap re-resuelva el MISMO torrent, aborte el primero
  // mostrando un diálogo zumbante y lance "Unhandled Exception: Torrent
  // desaparecido" en el _waitForMetadata de la primera espera.
  final Set<String> _pendingTorrentInit = {};

  @override
  void initState() {
    super.initState();
    // No necesitamos retrasar aquí, el build se encargará cuando los datos lleguen
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchController.dispose();
    _carouselController.dispose();
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      resizeToAvoidBottomInset: false,
      backgroundColor: Colors.black,
      body: PageView(
        controller: _pageController,
        onPageChanged: (index) {
          setState(() => _currentTabIndex = index);
        },
        physics: const ClampingScrollPhysics(),
        children: [
          RepaintBoundary(child: _buildMoviesView()),
          const RepaintBoundary(child: SeriesGridPage()),
          const RepaintBoundary(child: TvChannelsPage()),
          const RepaintBoundary(child: DownloadsPage()),
          const RepaintBoundary(child: ProfilePage()),
        ],
      ),
      bottomNavigationBar: _buildBottomNav(),
    );
  }

  Widget _buildMoviesView() {
    final moviesAsync = ref.watch(moviesProvider);
    final categoriesAsync = ref.watch(categoriesProvider);

    return moviesAsync.when(
      data: (allMovies) {
        // Ejecutar el aviso de batería una sola vez cuando hay datos
        if (!_batteryDialogShown) {
          _batteryDialogShown = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _showBatteryOptimizationDialog(context);
          });
        }
        if (!_vipPromoShown) {
          _vipPromoShown = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _showInitialVipPromoIfNeeded(context);
          });
        }

        // Filtering logic
        var filteredMovies = allMovies;
        if (_selectedCategoryFilter != null) {
          filteredMovies = allMovies
              .where((m) => m.categoryId == _selectedCategoryFilter)
              .toList();
        }
        if (_searchQuery.isNotEmpty) {
          filteredMovies = filteredMovies
              .where(
                (m) =>
                    m.name.toLowerCase().contains(_searchQuery.toLowerCase()),
              )
              .toList();
        }

        final popularMovies = filteredMovies.where((m) => m.isPopular).toList();

        return categoriesAsync.when(
          data: (categories) {
            return Stack(
              children: [
                RefreshIndicator(
                  onRefresh: () async {
                    await ref.read(moviesProvider.notifier).loadMovies();
                    await ref
                        .read(categoriesProvider.notifier)
                        .loadCategories();
                  },
                  color: const Color(0xFF00A3FF),
                  backgroundColor: const Color(0xFF1A1A1A),
                  child: CustomScrollView(
                    slivers: [
                      _buildHeader(categories),
                      if (_isSearching)
                        SliverToBoxAdapter(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 8,
                            ),
                            child: TextField(
                              controller: _searchController,
                              autofocus: true,
                              autocorrect: false,
                              enableSuggestions: false,
                              textInputAction: TextInputAction.search,
                              style: const TextStyle(color: Colors.white),
                              decoration: InputDecoration(
                                hintText: 'Buscar películas...',
                                hintStyle: const TextStyle(
                                  color: Colors.white38,
                                ),
                                prefixIcon: const Icon(
                                  Icons.search,
                                  color: Color(0xFF00A3FF),
                                ),
                                suffixIcon: IconButton(
                                  icon: const Icon(
                                    Icons.close,
                                    color: Colors.white70,
                                  ),
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
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                  borderSide: BorderSide.none,
                                ),
                              ),
                              onChanged: (val) {
                                // Búsqueda LOCAL en la lista ya cargada. La
                                // setState va con debounce para no re-filtrar ni
                                // reconstruir todo el grid en cada tecla (eso
                                // causa el "se traba"). Se aplica una sola vez
                                // al dejar de escribir.
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
                      if (popularMovies.isNotEmpty &&
                          !_isSearching &&
                          _selectedCategoryFilter == null)
                        SliverToBoxAdapter(
                          child: _buildCarousel(popularMovies, context),
                        ),
                      if (_isSearching || _selectedCategoryFilter != null)
                        // Grid perezoso (SliverGrid): solo construye los
                        // pósters visibles. El anterior GridView con
                        // shrinkWrap dentro del SliverList obligaba a construir
                        // y medir TODOS los resultados (cientos de Image.network)
                        // → con el teclado activo y cientos de resultados todo
                        // se realentizaba. SliverGrid construye de forma perezosa.
                        SliverPadding(
                          padding: const EdgeInsets.fromLTRB(12, 8, 12, 100),
                          sliver: SliverGrid(
                            gridDelegate:
                                SliverGridDelegateWithFixedCrossAxisCount(
                                  crossAxisCount:
                                      ResponsiveLayout.getGridCrossAxisCount(
                                        context,
                                      ),
                                  crossAxisSpacing: 12,
                                  mainAxisSpacing: 20,
                                  mainAxisExtent:
                                      ResponsiveLayout.getPosterHeight(
                                        context,
                                      ) +
                                      60,
                                ),
                            delegate: SliverChildBuilderDelegate(
                              (context, index) =>
                                  _buildMovieCard(
                                    context,
                                    filteredMovies[index],
                                  ),
                              childCount: filteredMovies.length,
                            ),
                          ),
                        )
                      else
                        SliverPadding(
                          padding: const EdgeInsets.only(top: 0, bottom: 100),
                          sliver: SliverList(
                            delegate: SliverChildListDelegate([
                              if (filteredMovies.isNotEmpty) ...[
                                ref
                                    .watch(historyProvider)
                                    .when(
                                      data: (history) {
                                        if (history.isEmpty)
                                          return const SizedBox.shrink();

                                        final Map<String, WatchHistory>
                                        uniqueHistory = {};
                                        for (var item in history) {
                                          if (!uniqueHistory.containsKey(
                                            item.mediaId,
                                          )) {
                                            uniqueHistory[item.mediaId] = item;
                                          }
                                        }

                                        return _buildHistorySection(
                                          context,
                                          uniqueHistory.values
                                              .take(20)
                                              .toList(),
                                        );
                                      },
                                      loading: () => const SizedBox.shrink(),
                                      error: (_, __) =>
                                          const SizedBox.shrink(),
                                    ),
                                _buildMovieSection(
                                  context,
                                  'RECIÉN AGREGADAS',
                                  filteredMovies
                                      .where((m) => true)
                                      .toList()
                                    ..sort(
                                      (a, b) =>
                                          b.createdAt.compareTo(a.createdAt),
                                    ),
                                ),
                              ],
                              ...categories.map((cat) {
                                final catMovies = filteredMovies
                                    .where((m) => m.categoryId == cat.id)
                                    .toList();
                                if (catMovies.isEmpty)
                                  return const SizedBox.shrink();
                                return _buildMovieSection(
                                  context,
                                  cat.name.toUpperCase(),
                                  catMovies,
                                  category: cat,
                                );
                              }),
                            ]),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            );
          },
          loading: () => const Center(
            child: CircularProgressIndicator(color: Color(0xFF00A3FF)),
          ),
          error: (e, s) => Center(
            child: Text(
              'Error: $e',
              style: const TextStyle(color: Colors.white),
            ),
          ),
        );
      },
      loading: () => const Center(
        child: CircularProgressIndicator(color: Color(0xFF00A3FF)),
      ),
      error: (e, s) => Center(
        child: Text('Error: $e', style: const TextStyle(color: Colors.white)),
      ),
    );
  }

  Widget _buildHeader(List<Category> categories) {
    return SliverAppBar(
      backgroundColor: Colors.black.withOpacity(0.5),
      floating: true,
      elevation: 0,
      flexibleSpace: const SafeArea(
        child: SizedBox.shrink(),
      ),
      title: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Consumer(
            builder: (context, ref, _) {
              final role = ref.watch(authStateProvider)?.role ?? 'user';
              return VipStarButton(role: role);
            },
          ),
          const SizedBox(width: 8),
          const Flexible(
            child: Text(
              'MOVIE',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                letterSpacing: 2,
                fontWeight: FontWeight.normal,
                fontSize: 16,
                color: Colors.white,
              ),
            ),
          ),
        ],
      ),
      actions: [
        DropdownButtonHideUnderline(
          child: DropdownButton<String?>(
            value: _selectedCategoryFilter,
            dropdownColor: const Color(0xFF121212),
            icon: const Icon(Icons.filter_list, color: Color(0xFF00A3FF)),
            selectedItemBuilder: (BuildContext context) {
              return [
                const SizedBox(
                  width: 52,
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: Text(
                      "Todas",
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: Colors.white),
                    ),
                  ),
                ),
                ...categories.map(
                  (c) => SizedBox(
                    width: 52,
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: Text(
                        c.name,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white),
                      ),
                    ),
                  ),
                ),
              ];
            },
            items: [
              const DropdownMenuItem(
                value: null,
                child: Text("Todas", style: TextStyle(color: Colors.white)),
              ),
              ...categories.map(
                (c) => DropdownMenuItem(
                  value: c.id,
                  child: Text(
                    c.name,
                    style: const TextStyle(color: Colors.white),
                  ),
                ),
              ),
            ],
            onChanged: (val) => setState(() => _selectedCategoryFilter = val),
          ),
        ),
        IconButton(
          icon: Icon(
            _isSearching ? Icons.search_off : Icons.search,
            color: Colors.white70,
          ),
          onPressed: () => setState(() => _isSearching = !_isSearching),
        ),
        IconButton(
          icon: const Icon(Icons.extension, color: Color(0xFF00A3FF)),
          tooltip: 'Addons',
          onPressed: () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => const AddonsManagerPage(),
              ),
            );
          },
        ),
        IconButton(
          icon: const Icon(Icons.travel_explore, color: Color(0xFF00A3FF)),
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
      ],
    );
  }

  Future<void> _showInitialVipPromoIfNeeded(BuildContext context) async {
    final role = ref.read(authStateProvider)?.role.toLowerCase() ?? 'user';
    if (role == 'uservip') return;

    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool('hide_vip_promo_modal') == true) return;
    final config = await VipPromoService.loadConfig();
    if (!context.mounted) return;

    var neverAgain = false;
    await showDialog(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => VipPromoDialog(
          config: config,
          showNeverAgain: true,
          neverAgainValue: neverAgain,
          onNeverAgainChanged: (v) => setDialogState(() => neverAgain = v),
          onLater: () {
            if (neverAgain) {
              prefs.setBool('hide_vip_promo_modal', true);
            }
            Navigator.pop(dialogContext);
          },
        ),
      ),
    );
    if (neverAgain) {
      await prefs.setBool('hide_vip_promo_modal', true);
    }
  }

  Widget _buildCarousel(List<Movie> popularMovies, BuildContext context) {
    return Column(
      children: [
        SizedBox(
          height: ResponsiveLayout.getCarouselHeight(context),
          child: PageView.builder(
            controller: _carouselController,
            onPageChanged: (index) =>
                setState(() => _currentCarouselPage = index),
            itemCount: popularMovies.length,
            itemBuilder: (context, index) {
              final movie = popularMovies[index];
              return _buildCarouselItem(movie);
            },
          ),
        ),
        const SizedBox(height: 12),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: List.generate(
            popularMovies.length,
            (index) => AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              margin: const EdgeInsets.symmetric(horizontal: 4),
              width: _currentCarouselPage == index ? 10 : 8,
              height: _currentCarouselPage == index ? 10 : 8,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _currentCarouselPage == index
                    ? const Color(0xFF00A3FF)
                    : Colors.white24,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildCarouselItem(Movie movie) {
    return TvFocusWrapper(
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => MovieDetailsPage(movie: movie)),
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
                  (movie.backdropUrl != null && movie.backdropUrl!.isNotEmpty)
                      ? movie.backdropUrl!
                      : movie.imagePath,
                  fit: BoxFit.cover,
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
                          'TRENDING NOW',
                          style: TextStyle(
                            color: Color(0xFF00E5FF),
                            fontWeight: FontWeight.bold,
                            letterSpacing: 1.2,
                            fontSize: 11,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          movie.name.toUpperCase(),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 26,
                            fontWeight: FontWeight.w900,
                            height: 1.1,
                          ),
                        ),
                        const SizedBox(height: 10),
                        if (movie.description != null)
                          Text(
                            movie.description!,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: Colors.white.withOpacity(0.7),
                              fontSize: 13,
                            ),
                          ),
                        const SizedBox(height: 20),
                        Row(
                          children: [
                            Expanded(
                              child: Container(
                                height: 48,
                                decoration: BoxDecoration(
                                  gradient: const LinearGradient(
                                    colors: [
                                      Color(0xFF00A3FF),
                                      Color(0xFFD400FF),
                                    ],
                                  ),
                                  borderRadius: BorderRadius.circular(12),
                                  boxShadow: [
                                    BoxShadow(
                                      color: const Color(
                                        0xFF00A3FF,
                                      ).withOpacity(0.35),
                                      blurRadius: 15,
                                      offset: const Offset(0, 8),
                                    ),
                                  ],
                                ),
                                child: ElevatedButton.icon(
                                  onPressed: () {
                                    Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                        builder: (_) =>
                                            MovieDetailsPage(movie: movie),
                                      ),
                                    );
                                  },
                                  icon: const Icon(Icons.play_arrow, size: 20),
                                  label: const Text(
                                    'Play Now',
                                    style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                      letterSpacing: 1.1,
                                    ),
                                  ),
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: Colors.transparent,
                                    shadowColor: Colors.transparent,
                                    foregroundColor: Colors.white,
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Container(
                              decoration: BoxDecoration(
                                color: Colors.white.withOpacity(0.1),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: IconButton(
                                icon: const Icon(
                                  Icons.add,
                                  color: Colors.white,
                                ),
                                onPressed: () {},
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

  Widget _buildMovieSection(
    BuildContext context,
    String title,
    List<Movie> movies, {
    Category? category,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(
            left: 16,
            right: 16,
            top: 4,
            bottom: 8,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Container(
                    width: 3,
                    height: 18,
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [Color(0xFF00A3FF), Color(0xFFD400FF)],
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                      ),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 1.5,
                      color: Colors.white,
                    ),
                  ),
                ],
              ),
              if (category != null)
                TextButton(
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) =>
                            CategoryPage(category: category, movies: movies),
                      ),
                    );
                  },
                  child: const Text(
                    'VIEW ALL',
                    style: TextStyle(
                      color: Colors.white38,
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
            ],
          ),
        ),
        SizedBox(
          height: ResponsiveLayout.getPosterHeight(context) + 60,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: movies.length,
            itemBuilder: (context, index) {
              final movie = movies[index];
              return _buildMovieCard(context, movie);
            },
          ),
        ),
        const SizedBox(height: 4),
      ],
    );
  }

  Widget _buildMovieCard(BuildContext context, Movie movie) {
    final double cardWidth = ResponsiveLayout.getPosterWidth(context);
    return Container(
      width: cardWidth,
      margin: const EdgeInsets.only(right: 8),
      child: TvFocusWrapper(
        onTap: () {
          Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => MovieDetailsPage(movie: movie)),
          );
        },
        borderRadius: 16,
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
                      width: ResponsiveLayout.getPosterWidth(context),
                      height: ResponsiveLayout.getPosterHeight(context),
                      child: Image.network(
                        (ResponsiveLayout.isLandscape(context) &&
                                movie.backdropUrl != null &&
                                movie.backdropUrl!.isNotEmpty)
                            ? movie.backdropUrl!
                            : movie.imagePath,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => const Icon(
                          Icons.movie,
                          color: Colors.white24,
                          size: 50,
                        ),
                      ),
                    ),
                  ),
                ),
                Positioned(
                  top: 8,
                  left: 8,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFF00A3FF).withOpacity(0.8),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: const Text(
                      'MOVIE',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 8,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            MarqueeText(
              text: movie.name,
              style: TextStyle(
                fontSize: ResponsiveLayout.isLandscape(context) ? 14 : 18,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
              width: cardWidth,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHistorySection(
    BuildContext context,
    List<WatchHistory> history,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(
            left: 16,
            right: 16,
            top: 4,
            bottom: 8,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Container(
                    width: 3,
                    height: 18,
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [Color(0xFF00A3FF), Color(0xFFD400FF)],
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                      ),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(width: 10),
                  const Text(
                    'CONTINUAR VIENDO',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 1.5,
                      color: Colors.white,
                    ),
                  ),
                ],
              ),
              TextButton(
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const HistoryViewAllPage(),
                    ),
                  );
                },
                child: const Text(
                  'VIEW ALL',
                  style: TextStyle(
                    color: Colors.white38,
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
        ),
        SizedBox(
          height: 260,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: history.length,
            itemBuilder: (context, index) {
              return _buildHistoryCard(context, history[index]);
            },
          ),
        ),
        const SizedBox(height: 4),
      ],
    );
  }

  Widget _buildHistoryCard(BuildContext context, WatchHistory item) {
    final progress = item.lastPosition / item.totalDuration;

    return Container(
      width: 140,
      margin: const EdgeInsets.only(right: 8),
      child: TvFocusWrapper(
        onTap: () => _showHistoryOptionsModal(context, item),
        borderRadius: 16,
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
                    child: Stack(
                      children: [
                        SizedBox(
                          width: 140,
                          height: 200,
                          child: Image.network(
                            item.imagePath,
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => const Icon(
                              Icons.movie,
                              color: Colors.white24,
                              size: 50,
                            ),
                          ),
                        ),
                        // Progress bar at the bottom of the card image
                        Positioned(
                          bottom: 0,
                          left: 0,
                          right: 0,
                          child: Column(
                            children: [
                              Container(
                                height: 4,
                                width: double.infinity,
                                color: Colors.white24,
                                alignment: Alignment.centerLeft,
                                child: FractionallySizedBox(
                                  widthFactor: progress.clamp(0.0, 1.0),
                                  child: Container(
                                    height: 4,
                                    decoration: const BoxDecoration(
                                      gradient: LinearGradient(
                                        colors: [
                                          Color(0xFF00A3FF),
                                          Color(0xFFD400FF),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        // Play icon overlay
                        Positioned.fill(
                          child: Center(
                            child: Container(
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                color: Colors.black.withOpacity(0.4),
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(
                                Icons.play_arrow_rounded,
                                color: Colors.white,
                                size: 30,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              item.title,
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            if (item.subtitle != null)
              Text(
                item.subtitle!,
                style: const TextStyle(fontSize: 11, color: Colors.white54),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildBottomNav() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.9),
        border: const Border(
          top: BorderSide(color: Colors.white10, width: 0.5),
        ),
      ),
      child: BottomNavigationBar(
        currentIndex: _currentTabIndex,
        onTap: (index) {
          _pageController.animateToPage(
            index,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeInOut,
          );
        },
        backgroundColor: Colors.transparent,
        elevation: 0,
        type: BottomNavigationBarType.fixed,
        selectedItemColor: Colors.white,
        unselectedItemColor: Colors.white38,
        selectedFontSize: 10,
        unselectedFontSize: 10,
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.movie_creation_outlined),
            label: 'PELÍCULAS',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.live_tv_outlined),
            label: 'SERIES',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.tv_outlined),
            label: 'TV VIVO',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.download_rounded),
            label: 'DESCARGAS',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.person_outline),
            label: 'PERFIL',
          ),
        ],
      ),
    );
  }

  void _showHistoryOptionsModal(BuildContext context, WatchHistory item) {
    final canResume = item.lastPosition > 10000;
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF141414),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (BuildContext ctx) {
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(ctx).size.height * 0.8,
            ),
              child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    margin: const EdgeInsets.only(top: 10, bottom: 20),
                    height: 4,
                    width: 40,
                    decoration: BoxDecoration(
                      color: Colors.white24,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  _buildHistoryOptionCard(
                    icon: Icons.play_circle_fill,
                    iconColor: const Color(0xFF00A3FF),
                    title: canResume ? 'Reanudar en la app' : 'Ver en la app',
                    subtitle: canResume
                        ? 'Continúa desde donde lo dejaste'
                        : null,
                    onTap: () {
                      Navigator.pop(ctx);
                      _launchMedia(context, item, resume: canResume);
                    },
                  ),
                  _buildHistoryOptionCard(
                    icon: Icons.cast,
                    iconColor: const Color(0xFF00A3FF),
                    title: 'Transmitir por Cast local',
                    subtitle: canResume
                        ? 'Retoma donde te quedaste en tu TV'
                        : 'Enviar a TV con Cast interno',
                    onTap: () {
                      Navigator.pop(ctx);
                      _launchHistoryCast(
                        context,
                        item,
                        mode: 'internal',
                        resume: canResume,
                      );
                    },
                  ),
                  _buildHistoryOptionCard(
                    icon: Icons.launch_rounded,
                    iconColor: const Color(0xFF00FF87),
                    title: 'Transmitir con Web Video Caster',
                    subtitle: canResume
                        ? 'Abre Web Video Caster y continua'
                        : 'Abrir en Web Video Caster',
                    onTap: () {
                      Navigator.pop(ctx);
                      _launchHistoryCast(
                        context,
                        item,
                        mode: 'wvc',
                        resume: canResume,
                      );
                    },
                  ),
                  _buildHistoryOptionCard(
                    icon: Icons.replay,
                    iconColor: Colors.white70,
                    title: 'Ver desde el principio',
                    onTap: () {
                      Navigator.pop(ctx);
                      _launchMedia(context, item, resume: false);
                    },
                  ),
                  _buildHistoryOptionCard(
                    icon: Icons.details,
                    iconColor: const Color(0xFFFFD54F),
                    title: 'Ver Detalle',
                    subtitle: _isTorrentHistoryItem(item)
                        ? 'Abrir pantalla de enlaces del torrent'
                        : 'Abrir pantalla de detalles',
                    onTap: () {
                      Navigator.pop(ctx);
                      _goToDetails(context, item);
                    },
                  ),
                  _buildHistoryOptionCard(
                    icon: Icons.info_outline,
                    iconColor: Colors.white70,
                    title: 'Selecionar Enlace',
                    onTap: () {
                      Navigator.pop(ctx);
                      _goToDetails(context, item);
                    },
                  ),
                  const SizedBox(height: 10),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildHistoryOptionCard({
    required IconData icon,
    required Color iconColor,
    required String title,
    String? subtitle,
    required VoidCallback onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: EnergyFlowBorder(
        borderRadius: 12,
        borderWidth: 1.2,
        duration: const Duration(seconds: 5),
        backgroundColor: const Color(0xFF1A1A1A),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              children: [
                Icon(icon, color: iconColor, size: 22),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                          fontSize: 13,
                          color: Colors.white,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      if (subtitle != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          subtitle!,
                          style: const TextStyle(
                            fontSize: 11,
                            color: Colors.white54,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showBatteryOptimizationDialog(BuildContext context) {
    if (!Platform.isAndroid) return;

    Future.delayed(const Duration(seconds: 2), () {
      if (!context.mounted) return;
      Permission.ignoreBatteryOptimizations.status.then((status) {
        if (status.isGranted || !context.mounted) return;
        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (ctx) => AlertDialog(
            backgroundColor: const Color(0xFF121214),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(24),
              side: BorderSide(
                color: Colors.white.withOpacity(0.1),
                width: 0.5,
              ),
            ),
            title: Column(
              children: [
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.amber.withOpacity(0.1),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.battery_saver_rounded,
                    color: Colors.amber,
                    size: 32,
                  ),
                ),
                const SizedBox(height: 20),
                const Text(
                  'Optimización de Batería',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.5,
                  ),
                ),
              ],
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Para garantizar que las descargas y la transmisión a tu TV no se interrumpan, K7-MOVIE necesita ejecutarse sin restricciones de energía.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.7),
                    fontSize: 14,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.05),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.info_outline,
                        color: Color(0xFF00A3FF),
                        size: 18,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'Selecciona "Sin restricciones" en el siguiente menú.',
                          style: TextStyle(
                            color: Colors.white.withOpacity(0.5),
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            actionsAlignment: MainAxisAlignment.spaceEvenly,
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text(
                  'MÁS TARDE',
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.4),
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              ElevatedButton(
                onPressed: () {
                  Navigator.pop(ctx);
                  Permission.ignoreBatteryOptimizations.request();
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF00A3FF),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 12,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  elevation: 8,
                  shadowColor: const Color(0xFF00A3FF).withOpacity(0.5),
                ),
                child: const Text(
                  'CONFIGURAR',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
        );
      });
    });
  }

  void _goToDetails(BuildContext context, WatchHistory item) {
    if (_isTorrentHistoryItem(item)) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => StreamListPage(
            movieName: item.title,
            poster: item.imagePath,
            tmdbId: item.mediaId,
            isSeries: item.mediaType == 'series',
          ),
        ),
      );
      return;
    }

    if (item.mediaType == 'movie') {
      final movie = (ref.read(moviesProvider).value ?? []).firstWhere(
        (m) => m.id == item.mediaId,
        orElse: () => Movie(
          id: item.mediaId,
          name: item.title,
          imagePath: item.imagePath,
          categoryId: '',
          description: '',
          rating: 0,
          year: '',
          createdAt: DateTime.now(),
          isPopular: false,
        ),
      );
      Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => MovieDetailsPage(movie: movie)),
      );
    } else {
      final series = (ref.read(seriesListProvider).value ?? []).firstWhere(
        (s) => s.id == item.mediaId,
        orElse: () => Series(
          id: item.mediaId,
          name: item.title,
          imagePath: item.imagePath,
          categoryId: '',
          description: '',
          rating: 0,
          year: '',
          createdAt: DateTime.now(),
          isPopular: false,
        ),
      );
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => SeriesDetailsPage(
            series: series,
            centerOnEpisodeId: item.episodeId,
          ),
        ),
      );
    }
  }

  /// Método factorizado para iniciar el contenido.
  Future<void> _launchMedia(
    BuildContext context,
    WatchHistory item, {
    required bool resume,
  }) async {
    if (_isTorrentHistoryItem(item)) {
      if (item.mediaType == 'movie') {
        await _playTorrentMovieFromHistory(context, item, resume: resume);
      } else {
        // Serie por torrent: sin datos de episodio en el historial, llevamos
        // al usuario a la pantalla de enlaces para que elija capítulo/link.
        if (!context.mounted) return;
        _goToDetails(context, item);
      }
      return;
    }

    final startPos = resume
        ? Duration(milliseconds: item.lastPosition)
        : Duration.zero;

    if (item.mediaType == 'movie') {
      final allOptions = await ref
          .read(movieRepositoryProvider)
          .getVideoOptions(item.mediaId);
      if (allOptions.isEmpty) {
        if (!context.mounted) return;
        _goToDetails(context, item);
        return;
      }

      // Fetch the movie to get creditsStartTime
      final movie = (ref.read(moviesProvider).value ?? []).firstWhere(
        (m) => m.id == item.mediaId,
        orElse: () => Movie(
          id: item.mediaId,
          name: item.title,
          imagePath: item.imagePath,
          categoryId: '',
          description: '',
          rating: 0,
          year: '',
          createdAt: DateTime.now(),
          isPopular: false,
        ),
      );

      // Preferir el enlace que el usuario eligió la última vez
      final option = item.videoOptionId != null
          ? allOptions.firstWhere(
              (o) => o.id == item.videoOptionId,
              orElse: () => allOptions.first,
            )
          : allOptions.first;

      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => MovieDetailsPage(
            movie: movie,
            autoPlayVideoOptionId: option.id,
            autoPlayStartPosition: startPos,
          ),
        ),
      );
    } else {
      // Series: ir a detalles con parámetros de auto-play
      if (!context.mounted) return;

      // Intentamos obtener los detalles completos de la serie desde el repositorio si no está en la lista cacheada.
      Series? series;
      final cachedList = ref.read(seriesListProvider).value ?? [];
      try {
        series = cachedList.firstWhere((s) => s.id == item.mediaId);
      } catch (_) {
        series = await ref
            .read(seriesRepositoryProvider)
            .getSeriesById(item.mediaId);
      }

      series ??= Series(
        id: item.mediaId,
        name: item.title,
        imagePath: item.imagePath,
        categoryId: '',
        description: '',
        rating: 0,
        year: '',
        createdAt: DateTime.now(),
        isPopular: false,
      );

      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => SeriesDetailsPage(
            series: series!,
            autoPlayEpisodeId: item.episodeId,
            autoPlayVideoOptionId: item.videoOptionId,
            autoPlayStartPosition: startPos,
          ),
        ),
      );
    }
  }

  /// Detecta si un item de "Continuar Viendo" proviene de un torrent (los
  /// torrents se registran en el historial con `videoOptionId` = imdb id).
  bool _isTorrentHistoryItem(WatchHistory item) =>
      (item.videoOptionId?.startsWith('tt') ?? false) &&
      item.mediaId.isNotEmpty;

  /// Devuelve el stream desde el torrent EXACTO que se reproduce/aprueba en el
  /// historial (infoHash + fileIdx guardados al jugar), saltándose la
  /// re-resolución por addons. `_resolveBestMovieStream` puede devolver un
  /// infohash distinto entre sesiones (p.ej. uno sin seeders que jamás obtiene
  /// metadata), por eso reanudar debe usar SIEMPRE el torrent persistido.
  TorrentStream? _historyTorrentStream(WatchHistory item) {
    final infoHash = item.torrentInfoHash;
    if (infoHash == null || infoHash.isEmpty) return null;
    return TorrentStream(
      name: item.title,
      title: item.title,
      infoHash: infoHash,
      fileIdx: item.torrentFileIdx,
      quality: 'Auto',
    );
  }

  /// Re-resuelve el mejor stream de torrent (mayor seeders) para el imdbId.
  Future<TorrentStream?> _resolveBestMovieStream(String imdbId) async {
    final controller = ref.read(addonsProvider.notifier);
    await controller.load();
    final addons = ref.read(addonsProvider).valueOrNull ?? [];
    TorrentStream? best;
    for (final addon in addons) {
      try {
        final streams = await ref
            .read(addonRepositoryProvider)
            .getStreams(addon: addon, imdbId: imdbId, type: 'movie');
        for (final s in streams) {
          if (s.infoHash == null || s.infoHash!.isEmpty) continue;
          if (best == null || (s.seeders ?? 0) > (best.seeders ?? 0)) best = s;
        }
      } catch (_) {}
    }
    return best;
  }

  /// Descarga el torrent de la película con el diálogo de % visible y
  /// posteriormente arranca el reproductor (reanudar o desde el principio).
  Future<void> _playTorrentMovieFromHistory(
    BuildContext context,
    WatchHistory item, {
    required bool resume,
  }) async {
    final imdbId = item.videoOptionId;
    if (imdbId == null) {
      _goToDetails(context, item);
      return;
    }
    // Guard anti doble-arranque: si ya hay un startStreaming en curso para este
    // mediaId (p.ej. el usuario tocó 2 veces "Reanudar" mientras el 1º seguía
    // resolviendo metadata), ignoramos el 2º tap. Re-arrancar el mismo torrent
    // aborta el 1º (dispose) y provoca "Unhandled Exception: Torrent
    // desaparecido" en su _waitForMetadata.
    final launchKey = item.mediaId;
    if (_pendingTorrentInit.contains(launchKey)) {
      print('TORRENT_DBG: ignoro tap repetido de torrent para mediaId=$launchKey');
      return;
    }
    _pendingTorrentInit.add(launchKey);

    final stream = _historyTorrentStream(item) ??
        await _resolveBestMovieStream(imdbId);
    if (!context.mounted) return;
    if (stream == null || stream.infoHash == null) {
      _pendingTorrentInit.remove(launchKey);
      _goToDetails(context, item);
      return;
    }

    final progressNotifier = ValueNotifier<TorrentDownloadProgress?>(null);
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => TorrentLoadingDialog(progress: progressNotifier),
    );

    TorrentStreamingHandle? handle;
    try {
      final h = await TorrentStreamingService.instance.startStreaming(
        infoHash: stream.infoHash!,
        fileIndex: stream.fileIdx,
        knownSizeBytes: stream.sizeBytes,
        progressToReport: progressNotifier,
      );
      handle = h;
      h.progress.addListener(
        () => progressNotifier.value = h.progress.value,
      );
    } catch (e) {
      _pendingTorrentInit.remove(launchKey);
      if (!context.mounted) return;
      Navigator.of(context, rootNavigator: true).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('No se pudo reproducir el torrent: $e')),
      );
      return;
    }
    _pendingTorrentInit.remove(launchKey);
    if (!context.mounted) return;
    Navigator.of(context, rootNavigator: true).pop();

    final startPos = resume
        ? Duration(milliseconds: item.lastPosition)
        : Duration.zero;
    final option = VideoOption(
      id: imdbId,
      movieId: item.mediaId,
      serverImagePath: item.imagePath,
      resolution: stream.quality ?? 'Auto',
      videoUrl: handle.session.localPath,
      language: stream.language,
      extractionAlgorithm: 4,
    );
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => VideoPlayerPage(
          movieName: item.title,
          videoOptions: [option],
          mediaId: item.mediaId,
          mediaType: 'movie',
          imagePath: item.imagePath,
          extractionAlgorithm: 4,
          startPosition: startPos,
          torrentDownloadProgress: handle,
          externalSubtitles: [
            for (final s in stream.subtitles)
              SubtitleInfo(language: s.language, url: s.url),
          ],
        ),
      ),
    ).then((_) {
      // Libera el torrent y detiene la descarga en 2º plano al cerrar el player.
      if (handle != null) {
        TorrentStreamingService.instance.stop(handle!.session);
      }
    });
  }

  /// Descarga el torrent de la película con % visible y después transmite por
  /// el modo indicado (cast local o Web Video Caster), usando el archivo local.
  Future<void> _castTorrentMovieFromHistory(
    BuildContext context,
    WatchHistory item, {
    required String mode,
    required bool resume,
  }) async {
    final imdbId = item.videoOptionId;
    if (imdbId == null) {
      _goToDetails(context, item);
      return;
    }
    final launchKey = item.mediaId;
    if (_pendingTorrentInit.contains(launchKey)) {
      print('TORRENT_DBG: ignoro tap repetido de cast para mediaId=$launchKey');
      return;
    }
    _pendingTorrentInit.add(launchKey);

    final stream = _historyTorrentStream(item) ??
        await _resolveBestMovieStream(imdbId);
    if (!context.mounted) return;
    if (stream == null || stream.infoHash == null) {
      _pendingTorrentInit.remove(launchKey);
      _goToDetails(context, item);
      return;
    }

    final progressNotifier = ValueNotifier<TorrentDownloadProgress?>(null);
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => TorrentLoadingDialog(progress: progressNotifier),
    );

    TorrentStreamingHandle? handle;
    try {
      final h = await TorrentStreamingService.instance.startStreaming(
        infoHash: stream.infoHash!,
        fileIndex: stream.fileIdx,
        knownSizeBytes: stream.sizeBytes,
        progressToReport: progressNotifier,
      );
      handle = h;
      h.progress.addListener(
        () => progressNotifier.value = h.progress.value,
      );
    } catch (e) {
      _pendingTorrentInit.remove(launchKey);
      if (!context.mounted) return;
      Navigator.of(context, rootNavigator: true).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('No se pudo transmitir el torrent: $e')),
      );
      return;
    }
    _pendingTorrentInit.remove(launchKey);
    if (!context.mounted) return;
    Navigator.of(context, rootNavigator: true).pop();

    final startPos = resume
        ? Duration(milliseconds: item.lastPosition)
        : Duration.zero;
final totalDuration = item.totalDuration > 0
        ? Duration(milliseconds: item.totalDuration)
        : null;

    final localPath = handle.session.localPath;
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF141414),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => CastButton(
        videoUrl: localPath,
        localFilePath: localPath,
        title: item.title,
        imageUrl: item.imagePath,
        currentPosition: startPos,
        duration: totalDuration,
        mediaId: item.mediaId,
        mediaType: item.mediaType,
        subtitleLabel: item.subtitle,
        videoOptionId: item.videoOptionId,
        showImmediately: true,
        preferredLaunchMode: mode,
      ),
    );
  }

  Future<void> _launchHistoryCast(
    BuildContext context,
    WatchHistory item, {
    required String mode,
    required bool resume,
  }) async {
    if (_isTorrentHistoryItem(item)) {
      if (item.mediaType == 'movie') {
        await _castTorrentMovieFromHistory(context, item, mode: mode, resume: resume);
      } else {
        if (!context.mounted) return;
        _goToDetails(context, item);
      }
      return;
    }

    final castData = await _resolveHistoryCastData(item, resume: resume);
    if (!context.mounted || castData == null) {
      if (context.mounted) {
        _goToDetails(context, item);
      }
      return;
    }

    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF141414),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => CastButton(
        videoUrl: castData.videoUrl,
        title: castData.title,
        imageUrl: castData.imageUrl,
        headers: castData.headers,
        algorithm: castData.algorithm,
        currentPosition: castData.startPosition,
        duration: castData.duration,
        mediaId: castData.mediaId,
        episodeId: castData.episodeId,
        mediaType: castData.mediaType,
        subtitleLabel: castData.subtitleLabel,
        videoOptionId: castData.videoOptionId,
        showImmediately: true,
        preferredLaunchMode: mode,
      ),
    );
  }

  Future<_HistoryCastData?> _resolveHistoryCastData(
    WatchHistory item, {
    required bool resume,
  }) async {
    final startPos = resume
        ? Duration(milliseconds: item.lastPosition)
        : Duration.zero;
    final totalDuration = item.totalDuration > 0
        ? Duration(milliseconds: item.totalDuration)
        : null;

    if (item.mediaType == 'movie') {
      final allOptions = await ref
          .read(movieRepositoryProvider)
          .getVideoOptions(item.mediaId);
      if (allOptions.isEmpty) return null;

      final option = item.videoOptionId != null
          ? allOptions.firstWhere(
              (o) => o.id == item.videoOptionId,
              orElse: () => allOptions.first,
            )
          : allOptions.first;

      return _HistoryCastData(
        videoUrl: option.videoUrl,
        headers: {
          'Referer': option.videoUrl,
          'User-Agent':
              'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/123.0.0.0 Safari/537.36',
        },
        algorithm: option.extractionAlgorithm,
        title: item.title,
        imageUrl: item.imagePath,
        mediaId: item.mediaId,
        mediaType: item.mediaType,
        videoOptionId: option.id,
        startPosition: startPos,
        duration: totalDuration,
      );
    }

    final cachedList = ref.read(seriesListProvider).value ?? [];
    Series? series;
    try {
      series = cachedList.firstWhere((s) => s.id == item.mediaId);
    } catch (_) {
      series = await ref
          .read(seriesRepositoryProvider)
          .getSeriesById(item.mediaId);
    }
    if (series == null || item.episodeId == null) return null;

    final seasons = await ref
        .read(seriesRepositoryProvider)
        .getSeasonsForSeries(series.id);

    Episode? targetEpisode;
    for (final season in seasons) {
      final episodes = await ref
          .read(seriesRepositoryProvider)
          .getEpisodesForSeason(season.id);
      try {
        targetEpisode = episodes.firstWhere((e) => e.id == item.episodeId);
        break;
      } catch (_) {}
    }

    if (targetEpisode == null) return null;

    final eUrl = item.videoOptionId != null
        ? targetEpisode.urls.firstWhere(
            (u) => u.optionId == item.videoOptionId,
            orElse: () => targetEpisode!.urls.isNotEmpty
                ? targetEpisode.urls.first
                : EpisodeUrl(
                    url: targetEpisode.url,
                    optionId: item.videoOptionId,
                    extractionAlgorithm: targetEpisode.extractionAlgorithm,
                  ),
          )
        : (targetEpisode.urls.isNotEmpty
              ? targetEpisode.urls.first
              : EpisodeUrl(
                  url: targetEpisode.url,
                  extractionAlgorithm: targetEpisode.extractionAlgorithm,
                ));

    return _HistoryCastData(
      videoUrl: eUrl.url,
      headers: {
        'Referer': eUrl.url,
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/123.0.0.0 Safari/537.36',
      },
      algorithm: eUrl.extractionAlgorithm,
      title: item.title,
      imageUrl: item.imagePath,
      mediaId: item.mediaId,
      episodeId: item.episodeId,
      mediaType: item.mediaType,
      subtitleLabel: item.subtitle,
      videoOptionId: eUrl.optionId ?? item.videoOptionId,
      startPosition: startPos,
      duration: totalDuration,
    );
  }
}

class _HistoryCastData {
  final String videoUrl;
  final Map<String, String>? headers;
  final int algorithm;
  final String title;
  final String? imageUrl;
  final String mediaId;
  final String? episodeId;
  final String mediaType;
  final String? subtitleLabel;
  final String? videoOptionId;
  final Duration startPosition;
  final Duration? duration;

  const _HistoryCastData({
    required this.videoUrl,
    required this.headers,
    required this.algorithm,
    required this.title,
    required this.imageUrl,
    required this.mediaId,
    this.episodeId,
    required this.mediaType,
    this.subtitleLabel,
    this.videoOptionId,
    required this.startPosition,
    required this.duration,
  });
}
