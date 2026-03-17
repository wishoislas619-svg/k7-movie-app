import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../domain/entities/series.dart';
import '../../domain/entities/season.dart';
import '../../domain/entities/episode.dart';
import '../../domain/entities/series_option.dart';
import '../providers/series_provider.dart';
import '../providers/series_category_provider.dart';
import '../../domain/entities/series_category.dart';
import '../../../../providers.dart';
import '../../../../shared/widgets/video_extractor_dialog.dart';
import '../../../player/presentation/pages/video_player_page.dart';
import '../../../player/data/datasources/video_service.dart';
import '../../../movies/domain/entities/download_task.dart';
import '../../../movies/domain/entities/movie.dart' show VideoOption; // Added VideoOption
import '../../../movies/data/repositories/download_repository_impl.dart'; // Added downloadsListProvider
import 'package:uuid/uuid.dart';

class SeriesDetailsPage extends ConsumerStatefulWidget {
  final Series series;
  const SeriesDetailsPage({super.key, required this.series});

  @override
  ConsumerState<SeriesDetailsPage> createState() => _SeriesDetailsPageState();
}

class _SeriesDetailsPageState extends ConsumerState<SeriesDetailsPage> {
  List<Season> _seasons = [];
  Map<String, List<Episode>> _episodesMap = {};
  Season? _selectedSeason;
  List<SeriesOption>? _videoOptions;
  bool _isLoading = true;
  bool _isDescriptionExpanded = false;
  final ScrollController _scrollController = ScrollController();
  bool _isRefreshing = false;

  @override
  void initState() {
    super.initState();
    _loadSeasons();
    _scrollController.addListener(_onScroll);
  }

  void _onScroll() {
    if (_scrollController.position.pixels > _scrollController.position.maxScrollExtent + 50) {
      if (!_isRefreshing) _onRefresh();
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _onRefresh() async {
    if (_isRefreshing) return;
    setState(() => _isRefreshing = true);
    await _loadSeasons();
    setState(() => _isRefreshing = false);
  }

  Future<void> _loadSeasons() async {
    final repo = ref.read(seriesRepositoryProvider);
    final seasons = await repo.getSeasonsForSeries(widget.series.id);
    
    final Map<String, List<Episode>> epMap = {};
    for (var s in seasons) {
      epMap[s.id] = await repo.getEpisodesForSeason(s.id);
    }
    
    final opts = await repo.getSeriesOptions(widget.series.id);

    if (mounted) {
      setState(() {
        _seasons = seasons;
        _episodesMap = epMap;
        _videoOptions = opts;
        if (_seasons.isNotEmpty) _selectedSeason = _seasons.first;
        _isLoading = false;
      });
    }
  }

  void _playEpisode(Episode episode, EpisodeUrl eUrl) {
    if (_videoOptions == null || _videoOptions!.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No hay servidores configurados')));
      return;
    }

    SeriesOption? option;
    try {
      option = _videoOptions!.firstWhere((o) => o.id == eUrl.optionId);
    } catch (_) {
      option = _videoOptions!.first;
    }
    
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => VideoPlayerPage(
          movieName: '${widget.series.name} - S${_selectedSeason?.seasonNumber ?? 1} E${episode.episodeNumber}',
          onVideoStarted: () {
            ref.read(seriesListProvider.notifier).incrementViews(widget.series.id);
          },
          videoOptions: [
            VideoOption(
              id: episode.id,
              movieId: widget.series.id,
              serverImagePath: option?.serverImagePath ?? '',
              resolution: eUrl.quality ?? option?.resolution ?? 'Auto',
              videoUrl: eUrl.url,
            )
          ],
        ),
      ),
    );
  }

  void _handleDownload(Episode episode, EpisodeUrl eUrl) async {
    final VideoExtractionData? result = await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => VideoExtractorDialog(url: eUrl.url),
    );

    if (result == null) return;
    final selectedQuality = result.qualities.firstOrNull;

    if (selectedQuality != null && mounted) {
      final headers = <String, String>{};
      if (result.headers != null) headers.addAll(result.headers!);
      if (result.cookies != null) headers['Cookie'] = result.cookies!;
      if (result.userAgent != null) headers['User-Agent'] = result.userAgent!;
      headers['Referer'] = eUrl.url;
      headers['Origin'] = eUrl.url.split('/').take(3).join('/');

      final task = DownloadTask(
        id: const Uuid().v4(),
        movieId: widget.series.id, 
        movieName: '${widget.series.name} - S${_selectedSeason?.seasonNumber ?? 1} E${episode.episodeNumber}',
        imagePath: widget.series.imagePath,
        videoUrl: selectedQuality.url,
        resolution: selectedQuality.resolution,
        status: DownloadStatus.pending,
        createdAt: DateTime.now(),
        headers: headers,
        isSeries: true,
        seasonNumber: _selectedSeason?.seasonNumber ?? 1,
        episodeNumber: episode.episodeNumber,
      );
      
      ref.read(downloadsListProvider.notifier).addDownload(task);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Iniciando descarga..."), backgroundColor: Colors.green),
      );
    }
  }

  void _showServerSelectionModal(Episode episode) {
    if (episode.urls.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Este episodio no tiene enlaces configurados')));
      return;
    }

    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF121212),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (context) {
        return Container(
          padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(episode.name, style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 16),
              const Text('Elegir Servidor', style: TextStyle(color: Color(0xFF00A3FF), fontSize: 12, fontWeight: FontWeight.bold, letterSpacing: 1.5)),
              const SizedBox(height: 12),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: episode.urls.length,
                  itemBuilder: (context, index) {
                    final eUrl = episode.urls[index];
                    SeriesOption? opt;
                    try { opt = _videoOptions?.firstWhere((o) => o.id == eUrl.optionId); } catch(_) {}
                    
                    return Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      decoration: BoxDecoration(color: Colors.white.withOpacity(0.05), borderRadius: BorderRadius.circular(12)),
                      child: ListTile(
                        leading: opt != null && opt.serverImagePath.isNotEmpty
                          ? Image.network(opt.serverImagePath, width: 24, height: 24, errorBuilder: (_,__,___) => const Icon(Icons.dns, color: Colors.blue))
                          : const Icon(Icons.dns, color: Colors.blue),
                        title: Text(opt != null ? '${opt.resolution} (${opt.language ?? 'Latino'})' : 'Servidor ${index+1}', style: const TextStyle(color: Colors.white, fontSize: 14)),
                        subtitle: Text(eUrl.quality ?? 'Desconocido', style: const TextStyle(color: Colors.white38, fontSize: 12)),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: const Icon(Icons.download, color: Color(0xFFD400FF)),
                              onPressed: () {
                                Navigator.pop(context);
                                _handleDownload(episode, eUrl);
                              },
                            ),
                            IconButton(
                              icon: const Icon(Icons.play_arrow, color: Color(0xFF00A3FF)),
                              onPressed: () {
                                Navigator.pop(context);
                                _playEpisode(episode, eUrl);
                              },
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        );
      }
    );
  }

  Widget _buildMetaIcon(IconData icon, String text, {Color color = Colors.grey}) {
    return Row(
      children: [
        Icon(icon, color: color, size: 18),
        const SizedBox(width: 8),
        Text(
          text,
          style: const TextStyle(
            color: Colors.white70,
            fontSize: 14,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }

  Widget _buildRoundButton(IconData icon, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.5),
          shape: BoxShape.circle,
        ),
        child: Icon(icon, color: Colors.white, size: 22),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final curSeries = widget.series;
    final currentDescription = curSeries.description ?? 'Sin descripción disponible.';

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // Fixed background image with darker overlay
          Positioned.fill(
            child: Stack(
              children: [
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: SizedBox(
                    height: 300,
                    child: Opacity(
                      opacity: 0.99,
                      child: Image.network(
                        (curSeries.backdropUrl?.isNotEmpty == true ? curSeries.backdropUrl! : curSeries.backdrop!) ?? curSeries.imagePath,
                        fit: BoxFit.cover,
                        alignment: Alignment.topCenter,
                        errorBuilder: (_,__,___) => const SizedBox.expand(),
                      ),
                    ),
                  ),
                ),
                Positioned.fill(
                  child: Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.transparent,
                          Colors.black.withOpacity(0.4),
                          Colors.black,
                        ],
                        stops: const [0.0, 0.15, 0.3], // Gradient finishes within the 250px window
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          RefreshIndicator(
            onRefresh: _onRefresh,
            color: const Color(0xFF00A3FF),
            backgroundColor: const Color(0xFF1A1A1A),
            strokeWidth: 2,
            child: CustomScrollView(
              controller: _scrollController,
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                SliverAppBar(
                expandedHeight: 300,
                pinned: true,
                backgroundColor: Colors.transparent,
                leading: const SizedBox.shrink(),
                elevation: 0,
                flexibleSpace: FlexibleSpaceBar(
                  background: Stack(
                    fit: StackFit.expand,
                    children: [
                      // Subtle gradient purely for text readability, moved lower to not dim the image top
                      Container(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              Colors.transparent,
                              Colors.black.withOpacity(1),
                            ],
                            stops: const [0.6, 1.0],
                          ),
                        ),
                      ),
                      Positioned(
                        bottom: 40,
                        left: 20,
                        right: 20,
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            // Poster Image on the left
                            Hero(
                              tag: 'poster_${curSeries.id}',
                              child: Container(
                                width: 120,
                                height: 180,
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(12),
                                  boxShadow: [
                                    BoxShadow(color: const Color(0xFF00A3FF).withOpacity(0.3), blurRadius: 15, spreadRadius: 1),
                                  ],
                                  border: Border.all(color: const Color(0xFF00A3FF).withOpacity(0.5), width: 1.5),
                                ),
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(11),
                                  child: Image.network(
                                    curSeries.imagePath,
                                    fit: BoxFit.cover,
                                    errorBuilder: (_, __, ___) => Container(color: Colors.white12, child: const Icon(Icons.movie, color: Colors.white24)),
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 20),
                            // Title and Meta
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (curSeries.rating > 0)
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                      margin: const EdgeInsets.only(bottom: 8),
                                      decoration: BoxDecoration(
                                        color: Colors.amber.withOpacity(0.2),
                                        borderRadius: BorderRadius.circular(8),
                                        border: Border.all(color: Colors.amber.withOpacity(0.5)),
                                      ),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          const Icon(Icons.star_rounded, color: Colors.amber, size: 16),
                                          const SizedBox(width: 4),
                                          Text(
                                            curSeries.rating.toStringAsFixed(1),
                                            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12),
                                          ),
                                        ],
                                      ),
                                    ),
                                  Text(
                                    curSeries.name,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 28,
                                      fontWeight: FontWeight.bold,
                                      letterSpacing: -0.5,
                                      height: 1.1,
                                      shadows: [
                                        Shadow(color: Colors.black, blurRadius: 20, offset: Offset(0, 4)),
                                        Shadow(color: Color(0xFF00A3FF), blurRadius: 10),
                                      ],
                                    ),
                                    maxLines: 3,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  const SizedBox(height: 8),
                                  if (curSeries.year != null)
                                    Text(
                                      curSeries.year!,
                                      style: TextStyle(color: Colors.white.withOpacity(0.6), fontSize: 14, fontWeight: FontWeight.w500),
                                    ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                      SafeArea(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              _buildRoundButton(Icons.arrow_back, () => Navigator.pop(context)),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              SliverToBoxAdapter(
                child: Container(
                  color: Colors.transparent,
                  padding: const EdgeInsets.symmetric(horizontal: 20.0, vertical: 0.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          _buildMetaIcon(Icons.remove_red_eye, '${curSeries.views} Views'),
                          const SizedBox(width: 20),
                          _buildMetaIcon(Icons.star, '${curSeries.rating.toStringAsFixed(1)} Rating', color: Colors.amber),
                          if (curSeries.categoryId != null) ...[
                            const SizedBox(width: 20),
                            ref.watch(seriesCategoriesProvider).when(
                              data: (categories) {
                                final category = categories.firstWhere((c) => c.id == curSeries.categoryId, orElse: () => SeriesCategory(id: '', name: 'Serie'));
                                return _buildMetaIcon(Icons.live_tv_outlined, category.name);
                              },
                              loading: () => const SizedBox.shrink(),
                              error: (_, __) => const SizedBox.shrink(),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 25),

                      // Description with Neon Border
                      Container(
                         padding: const EdgeInsets.all(1.2),
                         decoration: BoxDecoration(
                           borderRadius: BorderRadius.circular(16),
                           boxShadow: [
                             BoxShadow(color: const Color(0xFF00A3FF).withOpacity(0.1), blurRadius: 10, spreadRadius: -2),
                           ],
                           gradient: LinearGradient(
                             colors: [const Color(0xFF00A3FF).withOpacity(0.4), const Color(0xFFD400FF).withOpacity(0.4)],
                           ),
                         ),
                         child: Container(
                           width: double.infinity,
                           padding: const EdgeInsets.all(20),
                           decoration: BoxDecoration(
                             color: const Color(0xFF0A0A0A),
                             borderRadius: BorderRadius.circular(15),
                           ),
                           child: Column(
                             crossAxisAlignment: CrossAxisAlignment.start,
                             children: [
                               Text(
                                 (!_isDescriptionExpanded && currentDescription.length > 100)
                                     ? '${currentDescription.substring(0, 100)}...'
                                     : currentDescription,
                                 style: TextStyle(
                                   color: Colors.white.withOpacity(0.9),
                                   fontSize: 15,
                                   height: 1.6,
                                 ),
                               ),
                               if (currentDescription.length > 100)
                                 GestureDetector(
                                   onTap: () => setState(() => _isDescriptionExpanded = !_isDescriptionExpanded),
                                   child: Padding(
                                     padding: const EdgeInsets.only(top: 8.0),
                                     child: Text(
                                       _isDescriptionExpanded ? 'Ver menos' : 'Ver más...',
                                       style: const TextStyle(
                                         color: Color(0xFF00A3FF),
                                         fontWeight: FontWeight.bold,
                                       ),
                                     ),
                                   ),
                                 ),
                             ],
                           ),
                         ),
                      ),
                      const SizedBox(height: 35),
                      const Text('TEMPORADAS', style: TextStyle(color: Color(0xFF00A3FF), fontWeight: FontWeight.bold, fontSize: 18, letterSpacing: 1.2)),
                      const SizedBox(height: 16),
                      if (_isLoading)
                         const Center(child: CircularProgressIndicator())
                      else if (_seasons.isEmpty)
                         const Text('No hay temporadas disponibles.', style: TextStyle(color: Colors.white54))
                      else ...[
                        // Season Selector with Neon Border
                        Container(
                          padding: const EdgeInsets.all(1.2),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(12),
                            gradient: LinearGradient(
                              colors: [const Color(0xFF00A3FF).withOpacity(0.4), const Color(0xFFD400FF).withOpacity(0.4)],
                            ),
                          ),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                            decoration: BoxDecoration(
                              color: const Color(0xFF0A0A0A),
                              borderRadius: BorderRadius.circular(11),
                            ),
                            child: DropdownButtonHideUnderline(
                              child: DropdownButton<Season>(
                                dropdownColor: const Color(0xFF1A1A1A),
                                value: _selectedSeason,
                                isExpanded: true,
                                icon: const Icon(Icons.keyboard_arrow_down, color: Color(0xFF00A3FF)),
                                items: _seasons.map((s) => DropdownMenuItem(value: s, child: Text(s.name, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)))).toList(),
                                onChanged: (val) => setState(() => _selectedSeason = val),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 24),
                        const Text('EPISODIOS', style: TextStyle(color: Color(0xFF00A3FF), fontWeight: FontWeight.bold, letterSpacing: 2, fontSize: 12)),
                        const SizedBox(height: 16),
                        if (_selectedSeason != null)
                          ...(_episodesMap[_selectedSeason!.id] ?? []).map((ep) => _buildEpisodeItem(ep)),
                      ],
                      const SizedBox(height: 50),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

  Widget _buildEpisodeItem(Episode episode) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(1.2), // Neon border width
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF00A3FF).withOpacity(0.12),
            blurRadius: 10,
            spreadRadius: -2,
          ),
        ],
        gradient: LinearGradient(
          colors: [
            const Color(0xFF00A3FF).withOpacity(0.5),
            const Color(0xFFD400FF).withOpacity(0.5),
            const Color(0xFF00A3FF).withOpacity(0.5),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFF0A0A0A), // Solid dark background for item
          borderRadius: BorderRadius.circular(15),
        ),
        child: Material(
          color: Colors.transparent,
          child: ListTile(
             contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
             onTap: () => _showServerSelectionModal(episode),
             shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
             leading: Container(
               width: 40,
               height: 40,
               decoration: BoxDecoration(
                 color: const Color(0xFF00A3FF).withOpacity(0.1),
                 shape: BoxShape.circle,
                 border: Border.all(color: const Color(0xFF00A3FF).withOpacity(0.2)),
               ),
               child: Center(
                 child: Text(
                   '${episode.episodeNumber}', 
                   style: const TextStyle(color: Color(0xFF00A3FF), fontWeight: FontWeight.bold, fontSize: 14),
                 ),
               ),
             ),
             title: Text(
               episode.name, 
               style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15, letterSpacing: 0.5), 
               maxLines: 1, 
               overflow: TextOverflow.ellipsis,
             ),
             subtitle: const Padding(
               padding: EdgeInsets.only(top: 4.0),
               child: Text(
                 'Toca para elegir servidor', 
                 style: TextStyle(color: Colors.white38, fontSize: 11),
               ),
             ),
             trailing: Container(
               padding: const EdgeInsets.all(8),
               decoration: BoxDecoration(
                 color: Colors.white.withOpacity(0.05),
                 shape: BoxShape.circle,
               ),
               child: const Icon(Icons.play_arrow_rounded, color: Color(0xFF00A3FF), size: 20),
             ),
          ),
        ),
      ),
    );
  }

  Widget _buildPlaceholder() {
    return Container(
      color: const Color(0xFF1E1E1E),
      child: const Center(child: Icon(Icons.movie, size: 80, color: Colors.white12)),
    );
  }
}
