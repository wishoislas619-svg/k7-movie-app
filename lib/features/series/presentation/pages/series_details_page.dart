import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../domain/entities/series.dart';
import '../../domain/entities/season.dart';
import '../../domain/entities/episode.dart';
import '../../domain/entities/series_option.dart';
import '../providers/series_provider.dart';
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

  @override
  void initState() {
    super.initState();
    _loadSeasons();
    ref.read(seriesListProvider.notifier).incrementViews(widget.series.id);
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
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            expandedHeight: 500,
            pinned: true,
            backgroundColor: const Color(0xFF0A0A0A),
            leading: const SizedBox.shrink(),
            flexibleSpace: FlexibleSpaceBar(
              background: Stack(
                fit: StackFit.expand,
                children: [
                  if (curSeries.backdropUrl?.isNotEmpty == true || curSeries.backdrop?.isNotEmpty == true)
                    Image.network(
                      curSeries.backdropUrl?.isNotEmpty == true ? curSeries.backdropUrl! : curSeries.backdrop!,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => _buildPlaceholder(),
                    )
                  else
                    Image.network(
                      curSeries.imagePath,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => _buildPlaceholder(),
                    ),
                  Container(
                    height: 300,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.black.withOpacity(0.2),
                          Colors.transparent,
                          Colors.black.withOpacity(0.6),
                          Colors.black.withOpacity(0.9),
                        ],
                        stops: const [0.0, 0.4, 0.8, 1.0],
                      ),
                    ),
                  ),
                  Positioned(
                    bottom: 25,
                    left: 20,
                    right: 20,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          curSeries.name,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 34,
                            fontWeight: FontWeight.bold,
                            shadows: [
                              Shadow(
                                color: Colors.black45,
                                offset: Offset(0, 2),
                                blurRadius: 10,
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
                          _buildRoundButton(Icons.add, () {}),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20.0, vertical: 0.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      _buildMetaIcon(Icons.remove_red_eye, '${curSeries.views} Views'),
                      const SizedBox(width: 20),
                      _buildMetaIcon(Icons.star, '${(curSeries.rating * 2).toStringAsFixed(1)} Rating', color: Colors.amber),
                    ],
                  ),
                  const SizedBox(height: 25),

                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(1.2),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(17),
                      gradient: LinearGradient(
                        colors: [
                          Colors.blue.withOpacity(0.5),
                          Colors.purple.withOpacity(0.5),
                          Colors.blue.withOpacity(0.5),
                          Colors.purple.withOpacity(0.5),
                        ],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                    ),
                    child: Container(
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        color: const Color(0xFF121212),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            (!_isDescriptionExpanded && currentDescription.length > 70)
                                ? '${currentDescription.substring(0, 70)}...'
                                : currentDescription,
                            style: TextStyle(
                              color: Colors.white.withOpacity(0.7),
                              fontSize: 15,
                              height: 1.6,
                            ),
                            textAlign: TextAlign.left,
                          ),
                          if (currentDescription.length > 70)
                            GestureDetector(
                              onTap: () => setState(() => _isDescriptionExpanded = !_isDescriptionExpanded),
                              child: Padding(
                                padding: const EdgeInsets.only(top: 8.0),
                                child: Text(
                                  _isDescriptionExpanded ? 'Ver menos' : 'Ver más...',
                                  style: const TextStyle(
                                    color: Color(0xFF00A3FF),
                                    fontWeight: FontWeight.bold,
                                    fontSize: 14,
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
                     const Text('No hay temporadas disponibles para esta serie.', style: TextStyle(color: Colors.white54))
                  else ...[
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1E1E1E),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.white.withOpacity(0.1)),
                      ),
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<Season>(
                          dropdownColor: const Color(0xFF2C2C2C),
                          value: _selectedSeason,
                          isExpanded: true,
                          icon: const Icon(Icons.keyboard_arrow_down, color: Color(0xFF00A3FF)),
                          items: _seasons.map((s) => DropdownMenuItem(value: s, child: Text(s.name, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)))).toList(),
                          onChanged: (val) => setState(() => _selectedSeason = val),
                        ),
                      ),
                    ),
                    const SizedBox(height: 24),
                    const Text('EPISODIOS', style: TextStyle(color: Color(0xFF00A3FF), fontWeight: FontWeight.bold, letterSpacing: 2, fontSize: 12)),
                    const SizedBox(height: 16),
                    if (_selectedSeason != null)
                      ...(_episodesMap[_selectedSeason!.id] ?? []).map((ep) => _buildEpisodeItem(ep)),
                  ]
                ],
              ),
            ),
          )
        ],
      )
    );
  }

  Widget _buildEpisodeItem(Episode episode) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.04),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withOpacity(0.05)),
      ),
      child: ListTile(
         contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
         onTap: () => _showServerSelectionModal(episode),
         leading: Container(
           width: 32,
           height: 32,
           decoration: BoxDecoration(color: const Color(0xFF00A3FF).withOpacity(0.1), shape: BoxShape.circle),
           child: Center(child: Text('${episode.episodeNumber}', style: const TextStyle(color: Color(0xFF00A3FF), fontWeight: FontWeight.bold, fontSize: 12))),
         ),
         title: Text(episode.name, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14), maxLines: 1),
         trailing: const Icon(Icons.chevron_right, color: Colors.white24),
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
