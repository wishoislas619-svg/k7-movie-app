import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../../../../providers.dart';
import '../../domain/entities/series.dart';
import '../../domain/entities/season.dart';
import '../../domain/entities/episode.dart';
import '../../domain/entities/series_option.dart';
import '../../../../shared/widgets/series_scraper_dialog.dart';

class AdminSeasonsEpisodesPage extends ConsumerStatefulWidget {
  final Series series;
  const AdminSeasonsEpisodesPage({super.key, required this.series});

  @override
  ConsumerState<AdminSeasonsEpisodesPage> createState() => _AdminSeasonsEpisodesPageState();
}

class _AdminSeasonsEpisodesPageState extends ConsumerState<AdminSeasonsEpisodesPage> {
  List<Season> _seasons = [];
  Map<String, List<Episode>> _episodesCache = {};
  List<SeriesOption> _options = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    setState(() => _isLoading = true);
    final repo = ref.read(seriesRepositoryProvider);
    final seasons = await repo.getSeasonsForSeries(widget.series.id);
    final epsCache = <String, List<Episode>>{};
    for (var s in seasons) {
      final eps = await repo.getEpisodesForSeason(s.id);
      epsCache[s.id] = eps;
    }
    final options = await repo.getSeriesOptions(widget.series.id);
    if(mounted) {
      setState(() {
        _seasons = seasons;
        _episodesCache = epsCache;
        _options = options;
        _isLoading = false;
      });
    }
  }

  void _showAddSeasonDialog([Season? season]) {
    final nameCtrl = TextEditingController(text: season?.name ?? 'Temporada ${_seasons.length + 1}');
    final numCtrl = TextEditingController(text: season?.seasonNumber.toString() ?? '${_seasons.length + 1}');

    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        title: Text(season == null ? 'Nueva Temporada' : 'Editar Temporada', style: const TextStyle(color: Colors.white)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: 'Nombre', labelStyle: TextStyle(color: Colors.white70)), style: const TextStyle(color: Colors.white)),
            TextField(controller: numCtrl, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Número', labelStyle: TextStyle(color: Colors.white70)), style: const TextStyle(color: Colors.white)),
          ],
        ),
        actions: [
          if (season != null)
            TextButton(
              onPressed: () async {
                await ref.read(seriesRepositoryProvider).deleteSeason(season.id);
                _loadData();
                if(mounted) Navigator.pop(context);
              },
              child: const Text('Eliminar', style: TextStyle(color: Colors.red)),
            ),
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
          ElevatedButton(
            onPressed: () async {
              final newSeason = Season(
                id: season?.id ?? const Uuid().v4(),
                seriesId: widget.series.id,
                name: nameCtrl.text,
                seasonNumber: int.tryParse(numCtrl.text) ?? _seasons.length + 1,
              );
              if (season == null) await ref.read(seriesRepositoryProvider).addSeason(newSeason);
              else await ref.read(seriesRepositoryProvider).updateSeason(newSeason);
              _loadData();
              if(mounted) Navigator.pop(context);
            },
            child: const Text('Guardar'),
          )
        ],
      ),
    );
  }

  void _showAddEpisodeDialog(Season season, [Episode? episode]) {
    final currentEps = _episodesCache[season.id] ?? [];
    final nameCtrl = TextEditingController(text: episode?.name ?? 'Capítulo ${currentEps.length + 1}');
    final numCtrl = TextEditingController(text: episode?.episodeNumber.toString() ?? '${currentEps.length + 1}');
    
    // Copy existing urls or start empty
    List<EpisodeUrl> tempUrls = episode != null ? List.from(episode.urls) : [];

    showDialog(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (context, setState) {
          return AlertDialog(
            backgroundColor: const Color(0xFF1E1E1E),
            title: Text(episode == null ? 'Nuevo Capítulo' : 'Editar Capítulo', style: const TextStyle(color: Colors.white)),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: 'Nombre', labelStyle: TextStyle(color: Colors.white70)), style: const TextStyle(color: Colors.white)),
                  TextField(controller: numCtrl, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Número', labelStyle: TextStyle(color: Colors.white70)), style: const TextStyle(color: Colors.white)),
                  const SizedBox(height: 16),
                  const Text('Servidores / Enlaces', style: TextStyle(color: Color(0xFF00A3FF), fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  ...tempUrls.asMap().entries.map((entry) {
                    int i = entry.key;
                    EpisodeUrl eUrl = entry.value;
                    final urlCtrl = TextEditingController(text: eUrl.url);
                    final qualCtrl = TextEditingController(text: eUrl.quality);
                    
                    return Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(color: Colors.white10, borderRadius: BorderRadius.circular(8)),
                      child: Column(
                        children: [
                          Row(
                            children: [
                              Expanded(child: Text('Enlace ${i+1}', style: const TextStyle(color: Colors.white54, fontSize: 10))),
                              IconButton(
                                icon: const Icon(Icons.delete, color: Colors.red, size: 16),
                                onPressed: () => setState(() => tempUrls.removeAt(i)),
                              )
                            ],
                          ),
                          DropdownButton<String>(
                            dropdownColor: const Color(0xFF2C2C2C),
                            value: eUrl.optionId,
                            hint: const Text('Elegir Servidor', style: TextStyle(color: Colors.white24)),
                            isExpanded: true,
                            items: _options.map((o) => DropdownMenuItem<String>(value: o.id, child: Text('${o.resolution} (${o.language ?? 'Latino'})', style: const TextStyle(color: Colors.white, fontSize: 12)))).toList(),
                            onChanged: (val) => setState(() => tempUrls[i] = EpisodeUrl(url: eUrl.url, optionId: val, quality: eUrl.quality)),
                          ),
                          TextField(
                            controller: urlCtrl,
                            decoration: const InputDecoration(labelText: 'URL', labelStyle: TextStyle(color: Colors.white38, fontSize: 11)),
                            style: const TextStyle(color: Colors.white, fontSize: 12),
                            onChanged: (v) => tempUrls[i] = EpisodeUrl(url: v, optionId: tempUrls[i].optionId, quality: tempUrls[i].quality),
                          ),
                          TextField(
                            controller: qualCtrl,
                            decoration: const InputDecoration(labelText: 'Calidad (ej: 720p)', labelStyle: TextStyle(color: Colors.white38, fontSize: 11)),
                            style: const TextStyle(color: Colors.white, fontSize: 12),
                            onChanged: (v) => tempUrls[i] = EpisodeUrl(url: tempUrls[i].url, optionId: tempUrls[i].optionId, quality: v),
                          ),
                        ],
                      ),
                    );
                  }).toList(),
                  TextButton.icon(
                    onPressed: () => setState(() => tempUrls.add(EpisodeUrl(url: '', optionId: _options.isNotEmpty ? _options.first.id : null))),
                    icon: const Icon(Icons.add_circle_outline, size: 18),
                    label: const Text('Añadir Enlace'),
                  )
                ],
              ),
            ),
            actions: [
               if (episode != null)
                TextButton(
                  onPressed: () async {
                    await ref.read(seriesRepositoryProvider).deleteEpisode(episode.id);
                    _loadData();
                    if(mounted) Navigator.pop(context);
                  },
                  child: const Text('Eliminar', style: TextStyle(color: Colors.red)),
                ),
              TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
              ElevatedButton(
                onPressed: () async {
                  final newEp = Episode(
                    id: episode?.id ?? const Uuid().v4(),
                    seasonId: season.id,
                    name: nameCtrl.text,
                    episodeNumber: int.tryParse(numCtrl.text) ?? currentEps.length + 1,
                    url: tempUrls.isNotEmpty ? tempUrls.first.url : '',
                    urls: tempUrls,
                  );
                  if (episode == null) await ref.read(seriesRepositoryProvider).addEpisode(newEp);
                  else await ref.read(seriesRepositoryProvider).updateEpisode(newEp);
                  _loadData();
                  if(mounted) Navigator.pop(context);
                },
                child: const Text('Guardar'),
              )
            ],
          );
        }
      ),
    );
  }

  void _startAutoScraping() async {
    if (_options.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Agrega al menos una opción de servidor en "Editar Serie" antes de mapear.')));
      return;
    }

    final url = widget.series.detailsUrl;
    if (url == null || url.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('La serie no tiene una URL de detalles definida.')));
      return;
    }

    // Modal to choose Server Option
    final SeriesOption? selectedOption = await showDialog<SeriesOption>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        title: const Text('Elegir Servidor para Mapeo', style: TextStyle(color: Colors.white, fontSize: 16)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: _options.map<Widget>((o) => ListTile(
            title: Text('${o.resolution} (${o.language ?? 'Latino'})', style: const TextStyle(color: Colors.white)),
            onTap: () => Navigator.pop(context, o),
          )).toList(),
        ),
      ),
    );

    if (selectedOption == null) return;

    final scraperUrl = (selectedOption.videoUrl.isNotEmpty) ? selectedOption.videoUrl : url;

    final result = await showDialog(
      context: context,
      builder: (_) => SeriesScraperDialog(url: scraperUrl),
    );

    if (result != null && result is Map) {
      final seasonNum = result['seasonNumber'] as int;
      final extractions = result['episodes'] as List;

      // Find or create Season
      final repo = ref.read(seriesRepositoryProvider);
      Season? targetSeason;
      try {
        targetSeason = _seasons.firstWhere((s) => s.seasonNumber == seasonNum);
      } catch (_) {
        targetSeason = Season(
          id: const Uuid().v4(),
          seriesId: widget.series.id,
          name: 'Temporada $seasonNum',
          seasonNumber: seasonNum,
        );
        await repo.addSeason(targetSeason);
      }

      final existingEps = await repo.getEpisodesForSeason(targetSeason.id);

      for (var scraped in extractions) {
        // Try to find if episode already exists in this season (by number)
        // Extract number from title if possible, or use current loop index if not provided by scraper
        // For simplicity, Scraper gives a title, we might want to let user edit it later.
        // We'll match by name/title for now or just add if not found.
        
        Episode? existing;
        try {
           existing = existingEps.firstWhere((e) => e.name.toLowerCase() == scraped.title.toLowerCase());
        } catch(_) {}

        if (existing != null) {
          // Add as a second option if URL is different
          final currentUrls = List<EpisodeUrl>.from(existing.urls);
          if (!currentUrls.any((u) => u.url == scraped.url)) {
            currentUrls.add(EpisodeUrl(url: scraped.url, optionId: selectedOption.id, quality: selectedOption.resolution));
            await repo.updateEpisode(existing.copyWith(urls: currentUrls));
          }
        } else {
          // New episode
          final newEp = Episode(
            id: const Uuid().v4(),
            seasonId: targetSeason.id,
            episodeNumber: existingEps.length + 1,
            name: scraped.title,
            url: scraped.url,
            urls: [EpisodeUrl(url: scraped.url, optionId: selectedOption.id, quality: selectedOption.resolution)],
          );
          await repo.addEpisode(newEp);
        }
      }

      _loadData();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) return const Scaffold(backgroundColor: Colors.black, body: Center(child: CircularProgressIndicator()));

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: const Color(0xFF0A0A0A),
        title: const Text('TEMPORADAS Y CAPÍTULOS', style: TextStyle(color: Color(0xFF00A3FF), fontSize: 16, fontWeight: FontWeight.bold)),
        actions: [
          IconButton(
            icon: const Icon(Icons.auto_awesome, color: Color(0xFFD400FF)),
            onPressed: _startAutoScraping,
            tooltip: 'Auto-mapear capítulos',
          ),
          IconButton(
            icon: const Icon(Icons.add, color: Colors.white),
            onPressed: () => _showAddSeasonDialog(),
            tooltip: 'Añadir Temporada',
          )
        ],
      ),
      body: _seasons.isEmpty
        ? Center(child: Text('No hay temporadas. Presiona el ícono mágico para auto-detectar o el + para añadir manualmente.', style: TextStyle(color: Colors.white54), textAlign: TextAlign.center,))
        : ListView.builder(
            itemCount: _seasons.length,
            itemBuilder: (context, index) {
              final season = _seasons[index];
              final episodes = _episodesCache[season.id] ?? [];
              
              return ExpansionTile(
                title: Row(
                  children: [
                    Text(season.name, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                    const Spacer(),
                    IconButton(icon: const Icon(Icons.edit, size: 18, color: Colors.blueAccent), onPressed: () => _showAddSeasonDialog(season)),
                  ]
                ),
                collapsedIconColor: Colors.white,
                iconColor: Color(0xFF00A3FF),
                children: [
                  for (var ep in episodes)
                    ListTile(
                      contentPadding: const EdgeInsets.only(left: 32, right: 16),
                      title: Text(ep.name, style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w500)),
                      trailing: IconButton(icon: const Icon(Icons.edit, size: 18, color: Color(0xFF00A3FF)), onPressed: () => _showAddEpisodeDialog(season, ep)),
                    ),
                  ListTile(
                    contentPadding: const EdgeInsets.only(left: 32, right: 16),
                    leading: const Icon(Icons.add, color: Color(0xFFD400FF), size: 18),
                    title: const Text('Añadir Capítulo', style: TextStyle(color: Color(0xFFD400FF), fontSize: 13, fontWeight: FontWeight.bold)),
                    onTap: () => _showAddEpisodeDialog(season),
                  ),
                ],
              );
            },
          ),
    );
  }
}
