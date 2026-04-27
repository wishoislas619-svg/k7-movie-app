import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../../../../providers.dart';
import '../../domain/entities/series.dart';
import '../../domain/entities/season.dart';
import '../../domain/entities/episode.dart';
import '../../domain/entities/series_option.dart';
import '../../../../shared/widgets/series_scraper_dialog.dart';
import '../../../../core/services/tmdb_service.dart';

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

  /// Convierte segundos a HH:MM:SS (ej: 3661 → "01:01:01")
  String _secondsToTime(int? seconds) {
    if (seconds == null) return '';
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    final s = seconds % 60;
    return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  /// Convierte HH:MM:SS a segundos. Acepta también número puro.
  int? _parseTime(String value) {
    if (value.trim().isEmpty) return null;
    if (value.contains(':')) {
      final parts = value.trim().split(':');
      if (parts.length == 3) {
        final h = int.tryParse(parts[0]) ?? 0;
        final m = int.tryParse(parts[1]) ?? 0;
        final s = int.tryParse(parts[2]) ?? 0;
        return h * 3600 + m * 60 + s;
      }
      if (parts.length == 2) {
        final m = int.tryParse(parts[0]) ?? 0;
        final s = int.tryParse(parts[1]) ?? 0;
        return m * 60 + s;
      }
    }
    return int.tryParse(value);
  }

  void _showAddSeasonDialog([Season? season]) {
    final nameCtrl = TextEditingController(text: season?.name ?? 'Temporada ${_seasons.length + 1}');
    final numCtrl = TextEditingController(text: season?.seasonNumber.toString() ?? '${_seasons.length + 1}');

    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        title: Text(season == null ? 'Nueva Temporada' : 'Editar Temporada', style: const TextStyle(color: Colors.white)),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: 'Nombre', labelStyle: TextStyle(color: Colors.white70)), style: const TextStyle(color: Colors.white)),
              TextField(controller: numCtrl, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Número', labelStyle: TextStyle(color: Colors.white70)), style: const TextStyle(color: Colors.white)),
            ],
          ),
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
    final introStartCtrl = TextEditingController(text: _secondsToTime(episode?.introStartTime));
    final introEndCtrl = TextEditingController(text: _secondsToTime(episode?.introEndTime));
    final creditsCtrl = TextEditingController(text: _secondsToTime(episode?.creditsStartTime));

    
    // Copy existing urls or start empty
    List<EpisodeUrl> tempUrls = episode != null ? List.from(episode.urls) : [];
    bool isFinale = episode?.isSeriesFinale ?? false;

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
                  const Text('Tiempos (formato HH:MM:SS)', style: TextStyle(color: Color(0xFFD400FF), fontWeight: FontWeight.bold, fontSize: 13)),
                  const SizedBox(height: 8),
                  TextField(controller: introStartCtrl, keyboardType: TextInputType.text, decoration: const InputDecoration(labelText: 'Inicio Intro (ej: 00:01:30)', labelStyle: TextStyle(color: Colors.white54, fontSize: 11), hintText: '00:00:00', hintStyle: TextStyle(color: Colors.white24)), style: const TextStyle(color: Colors.white, fontSize: 12)),
                  const SizedBox(height: 8),
                  TextField(controller: introEndCtrl, keyboardType: TextInputType.text, decoration: const InputDecoration(labelText: 'Fin Intro (ej: 00:02:10)', labelStyle: TextStyle(color: Colors.white54, fontSize: 11), hintText: '00:00:00', hintStyle: TextStyle(color: Colors.white24)), style: const TextStyle(color: Colors.white, fontSize: 12)),
                  const SizedBox(height: 8),
                  TextField(controller: creditsCtrl, keyboardType: TextInputType.text, decoration: const InputDecoration(labelText: 'Inicio Créditos (ej: 00:42:00)', labelStyle: TextStyle(color: Colors.white54, fontSize: 11), hintText: '00:00:00', hintStyle: TextStyle(color: Colors.white24)), style: const TextStyle(color: Colors.white, fontSize: 12)),
                  const SizedBox(height: 16),
                  Container(
                    decoration: BoxDecoration(color: Colors.white.withOpacity(0.05), borderRadius: BorderRadius.circular(8)),
                    child: CheckboxListTile(
                      title: const Text('Es el Capítulo Final de la Serie', style: TextStyle(color: Colors.amber, fontSize: 13, fontWeight: FontWeight.bold)),
                      subtitle: const Text('Activa esto para lanzar el menú de recomendaciones exclusivas al finalizar.', style: TextStyle(color: Colors.white54, fontSize: 11)),
                      value: isFinale,
                      activeColor: Colors.amber,
                      checkColor: Colors.black,
                      onChanged: (val) {
                        setState(() => isFinale = val ?? false);
                      },
                    ),
                  ),
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
                            onChanged: (val) => setState(() => tempUrls[i] = EpisodeUrl(url: eUrl.url, optionId: val, quality: eUrl.quality, extractionAlgorithm: eUrl.extractionAlgorithm)),
                          ),
                          DropdownButton<int>(
                            dropdownColor: const Color(0xFF2C2C2C),
                            value: [1, 2, 3, 4].contains(eUrl.extractionAlgorithm) ? eUrl.extractionAlgorithm : 1,
                            hint: const Text('Algoritmo', style: TextStyle(color: Colors.white24)),
                            isExpanded: true,
                            items: const [
                              DropdownMenuItem(value: 1, child: Text('Algoritmo 1: DOM', style: TextStyle(color: Colors.white, fontSize: 12))),
                              DropdownMenuItem(value: 2, child: Text('Algoritmo 2: Clicks', style: TextStyle(color: Colors.white, fontSize: 12))),
                              DropdownMenuItem(value: 3, child: Text('Algoritmo 3: Mágico', style: TextStyle(color: Colors.white, fontSize: 12))),
                              DropdownMenuItem(value: 4, child: Text('Algoritmo 4: Multi-Servidor', style: TextStyle(color: Colors.white, fontSize: 12))),
                            ],
                            onChanged: (val) => setState(() => tempUrls[i] = EpisodeUrl(url: eUrl.url, optionId: eUrl.optionId, quality: eUrl.quality, extractionAlgorithm: val ?? 1)),
                          ),
                          TextField(
                            controller: urlCtrl,
                            decoration: const InputDecoration(labelText: 'URL', labelStyle: TextStyle(color: Colors.white38, fontSize: 11)),
                            style: const TextStyle(color: Colors.white, fontSize: 12),
                            onChanged: (v) => tempUrls[i] = EpisodeUrl(url: v, optionId: tempUrls[i].optionId, quality: tempUrls[i].quality, extractionAlgorithm: tempUrls[i].extractionAlgorithm),
                          ),
                          TextField(
                            controller: qualCtrl,
                            decoration: const InputDecoration(labelText: 'Calidad (ej: 720p)', labelStyle: TextStyle(color: Colors.white38, fontSize: 11)),
                            style: const TextStyle(color: Colors.white, fontSize: 12),
                            onChanged: (v) => tempUrls[i] = EpisodeUrl(url: tempUrls[i].url, optionId: tempUrls[i].optionId, quality: v, extractionAlgorithm: tempUrls[i].extractionAlgorithm),
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
                    introStartTime: _parseTime(introStartCtrl.text),
                    introEndTime: _parseTime(introEndCtrl.text),
                    creditsStartTime: _parseTime(creditsCtrl.text),
                    isSeriesFinale: isFinale,
                    extractionAlgorithm: tempUrls.isNotEmpty ? tempUrls.first.extractionAlgorithm : 1,
                  );

                  if (isFinale) {
                    // Update all other episodes in cache to false to keep singularity
                    final repo = ref.read(seriesRepositoryProvider);
                    for (var sEps in _episodesCache.values) {
                      for (var ep in sEps) {
                        if (ep.isSeriesFinale && ep.id != newEp.id) {
                          await repo.updateEpisode(ep.copyWith(isSeriesFinale: false, introStartTime: ep.introStartTime, introEndTime: ep.introEndTime, creditsStartTime: ep.creditsStartTime)); // Need to provide these so they don't get overwritten wrongly if the copyWith does strange null passing, though our copyWith handles it.
                        }
                      }
                    }
                  }

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

     final url = widget.series.detailsUrl ?? '';

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
      try {
        final seasonNum = result['seasonNumber'] as int;
        final List extractions = result['episodes'] as List;

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

        int addedCount = 0;
        int updatedCount = 0;
        int sequentialCounter = 0;
        for (var scraped in extractions) {
          sequentialCounter++;
          int currentEpisodeIndex = sequentialCounter;
          
          if (scraped is ScrapedEpisode && scraped.index != null) {
              currentEpisodeIndex = scraped.index!;
          } else if (scraped is Map && scraped['index'] != null) {
              // En caso de que se haya pasado como un mapa crudo en otra parte
              currentEpisodeIndex = scraped['index'] as int;
          }

          Episode? existing;
          try {
            // Refined matching: URL first, then Title, then Episode Number
            existing = existingEps.firstWhere((e) => 
               e.url == scraped.url || 
               e.name.toLowerCase() == scraped.title.toLowerCase() ||
               e.episodeNumber == currentEpisodeIndex
            );
          } catch (_) {}

          if (existing != null) {
            final currentUrls = List<EpisodeUrl>.from(existing.urls);
            if (!currentUrls.any((u) => u.url == scraped.url)) {
              currentUrls.add(EpisodeUrl(
                url: scraped.url, 
                optionId: selectedOption.id, 
                quality: selectedOption.resolution,
                extractionAlgorithm: selectedOption.extractionAlgorithm,
              ));
              await repo.updateEpisode(existing.copyWith(urls: currentUrls));
              updatedCount++;
            }
          } else {
            // New episode logic using 'currentEpisodeIndex'
            final newEp = Episode(
              id: const Uuid().v4(),
              seasonId: targetSeason.id,
              episodeNumber: currentEpisodeIndex,
              name: scraped.title ?? 'Capítulo $currentEpisodeIndex',
              url: scraped.url,
              urls: [EpisodeUrl(url: scraped.url, optionId: selectedOption.id, quality: selectedOption.resolution, extractionAlgorithm: selectedOption.extractionAlgorithm)],
              extractionAlgorithm: selectedOption.extractionAlgorithm,
            );
            await repo.addEpisode(newEp);
            addedCount++;
          }
        }

        await _loadData();
        if (mounted) {
           ScaffoldMessenger.of(context).showSnackBar(
             SnackBar(content: Text('¡Proceso finalizado! Añadidos: $addedCount, Actualizados: $updatedCount'))
           );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error al guardar mapeo: $e'), backgroundColor: Colors.redAccent)
          );
        }
      }
    }
  }

  void _generateVideasyEpisodes() async {
    final tmdbId = widget.series.tmdbId;
    if (tmdbId == null || tmdbId.isEmpty) {
       ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('La serie no tiene un TMDB ID configurado.')));
       return;
    }

    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Consultando TMDB...'), duration: Duration(seconds: 1)));
    final tmdbData = await TmdbService.getSeriesMetadata(tmdbId);

    // Modal to ask for S and E
    final result = await showDialog<Map<String, dynamic>>(
       context: context,
       builder: (context) {
          int? selectedSeason;
          bool isAnime = false;
          final sController = TextEditingController(text: '1');
          final eController = TextEditingController(text: '12');

          List<dynamic> tmdbSeasons = [];
          if (tmdbData != null && tmdbData['seasons'] != null) {
             tmdbSeasons = tmdbData['seasons'] as List;
          }

          return StatefulBuilder(
            builder: (context, setDialogState) {
              return AlertDialog(
                 backgroundColor: const Color(0xFF1E1E1E),
                 shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                 title: const Text('Generar Capítulos (Videasy)', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
                 content: SingleChildScrollView(
                   child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                         const Text('Detectado desde TMDB para auto-completar:', style: TextStyle(color: Colors.white70, fontSize: 11)),
                         const SizedBox(height: 12),
                         if (tmdbSeasons.isNotEmpty) ...[
                            DropdownButtonFormField<int>(
                               dropdownColor: const Color(0xFF1E1E1E),
                               value: selectedSeason,
                               isExpanded: true,
                               style: const TextStyle(color: Colors.white, fontSize: 13),
                               decoration: InputDecoration(
                                  labelText: 'Selecciona Temporada',
                                  labelStyle: const TextStyle(color: Color(0xFF00A3FF), fontSize: 12),
                                  filled: true,
                                  fillColor: Colors.white.withOpacity(0.04),
                                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: Colors.white.withOpacity(0.1))),
                               ),
                               items: tmdbSeasons.map<DropdownMenuItem<int>>((s) {
                                  return DropdownMenuItem<int>(
                                     value: s['season_number'],
                                     child: Text('${s['name']} (${s['episode_count']} eps)', maxLines: 1, overflow: TextOverflow.ellipsis),
                                  );
                               }).toList(),
                               onChanged: (val) {
                                  final sInfo = tmdbSeasons.firstWhere((s) => s['season_number'] == val);
                                  setDialogState(() {
                                     selectedSeason = val;
                                     sController.text = val.toString();
                                     eController.text = sInfo['episode_count'].toString();
                                  });
                               },
                            ),
                            const SizedBox(height: 20),
                            const Divider(color: Colors.white10),
                            const SizedBox(height: 12),
                         ],
                         TextField(
                           controller: sController, 
                           keyboardType: TextInputType.number, 
                           style: const TextStyle(color: Colors.white),
                           decoration: const InputDecoration(labelText: 'Temporada Manual', labelStyle: TextStyle(color: Colors.white54, fontSize: 12)),
                         ),
                         const SizedBox(height: 12),
                         TextField(
                           controller: eController, 
                           keyboardType: TextInputType.number, 
                           style: const TextStyle(color: Colors.white),
                           decoration: const InputDecoration(labelText: 'Capítulos a generar', labelStyle: TextStyle(color: Colors.white54, fontSize: 12)),
                         ),
                         const SizedBox(height: 12),
                         CheckboxListTile(
                           title: const Text('Corresponde a un Anime', style: TextStyle(color: Colors.amber, fontSize: 13, fontWeight: FontWeight.bold)),
                           subtitle: const Text('Usa "anime" en vez de "tv" en la URL', style: TextStyle(color: Colors.white54, fontSize: 11)),
                           value: isAnime,
                           activeColor: Colors.amber,
                           checkColor: Colors.black,
                           dense: true,
                           contentPadding: EdgeInsets.zero,
                           controlAffinity: ListTileControlAffinity.leading,
                           onChanged: (val) {
                             setDialogState(() {
                               isAnime = val ?? false;
                             });
                           },
                         ),
                      ],
                   ),
                 ),
                 actions: [
                    TextButton(onPressed: () => Navigator.pop(context), child: const Text('CANCELAR', style: TextStyle(color: Colors.white38))),
                    ElevatedButton(
                       onPressed: () => Navigator.pop(context, {
                          'season': int.tryParse(sController.text) ?? 1,
                          'count': int.tryParse(eController.text) ?? 1,
                          'isAnime': isAnime,
                       }),
                       style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00A3FF)),
                       child: const Text('GENERAR AHORA', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                    )
                 ],
              );
            }
          );
       }
    );

    if (result == null) return;

    final seasonNum = result['season']! as int;
    final count = result['count']! as int;
    final isAnime = result['isAnime']! as bool;
    final urlSlug = isAnime ? 'tv' : 'tv';

    setState(() => _isLoading = true);

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

    // Ensure we have a Videasy Option for the Series
    SeriesOption? selectedOption;
    try {
       selectedOption = _options.firstWhere((o) => o.extractionAlgorithm == 3);
    } catch (_) {
       // if not found, create one automatically
       selectedOption = SeriesOption(
          id: const Uuid().v4(),
          seriesId: widget.series.id,
          serverImagePath: 'https://videasy.net/logo.png',
          resolution: '1080P',
          videoUrl: 'https://player.videasy.net/$urlSlug/$tmdbId', 
          language: 'Latino',
          extractionAlgorithm: 3,
       );
       await repo.addSeriesOption(selectedOption);
    }

    final existingEps = await repo.getEpisodesForSeason(targetSeason.id);

    for (int i = 1; i <= count; i++) {
        Episode? existing;
        try {
           existing = existingEps.firstWhere((e) => e.episodeNumber == i);
        } catch (_) {}

        final videoUrl = 'https://player.videasy.net/$urlSlug/$tmdbId/$seasonNum/$i';
        
        if (existing != null) {
           final currentUrls = List<EpisodeUrl>.from(existing.urls);
           if (!currentUrls.any((u) => u.optionId == selectedOption!.id)) {
              currentUrls.add(EpisodeUrl(url: videoUrl, optionId: selectedOption!.id, quality: selectedOption!.resolution, extractionAlgorithm: 3));
              await repo.updateEpisode(existing.copyWith(urls: currentUrls));
           }
        } else {
           final newEp = Episode(
              id: const Uuid().v4(),
              seasonId: targetSeason.id,
              episodeNumber: i,
              name: 'Capítulo $i',
              url: videoUrl,
              urls: [EpisodeUrl(url: videoUrl, optionId: selectedOption.id, quality: selectedOption.resolution, extractionAlgorithm: 3)],
              extractionAlgorithm: 3,
           );
           await repo.addEpisode(newEp);
        }
    }

    await _loadData();
    if (mounted) {
       ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Capítulos generados con éxito.'), backgroundColor: Colors.green));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) return const Scaffold(backgroundColor: Colors.black, body: Center(child: CircularProgressIndicator()));

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: const Color(0xFF0A0A0A),
        title: const Text('TEMPORADAS Y CAPÍTULOS', style: TextStyle(color: Color(0xFF00A3FF), fontSize: 14, fontWeight: FontWeight.bold)),
        actions: [
          IconButton(
            icon: const Icon(Icons.bolt, color: Colors.amber),
            onPressed: _generateVideasyEpisodes,
            tooltip: 'Generar enlaces Videasy',
          ),
          IconButton(
            icon: const Icon(Icons.auto_awesome, color: Color(0xFFD400FF)),
            onPressed: _startAutoScraping,
            tooltip: 'Auto-mapear capítulos (Scraper)',
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
                    IconButton(icon: const Icon(Icons.timer_outlined, size: 18, color: Color(0xFFD400FF)), tooltip: 'Aplicar Tiempos a Toda la Temporada', onPressed: () => _showBulkTimeUpdateDialog(season)),
                    IconButton(icon: const Icon(Icons.edit, size: 18, color: Colors.blueAccent), tooltip: 'Editar Temporada', onPressed: () => _showAddSeasonDialog(season)),
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

  void _showBulkTimeUpdateDialog(Season season) {
    final introStartCtrl = TextEditingController();
    final introEndCtrl = TextEditingController();
    final creditsCtrl = TextEditingController();

    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        title: const Text('Aplicar Tiempos Masivamente', style: TextStyle(color: Colors.white, fontSize: 16)),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Aplica los mismos tiempos a todos los episodios de esta temporada (útil si los intros/outros duran igual en todos).', style: TextStyle(color: Colors.white54, fontSize: 13)),
              const SizedBox(height: 8),
              const Text('Formato: HH:MM:SS (ej: 00:01:30)', style: TextStyle(color: Color(0xFFD400FF), fontSize: 12, fontWeight: FontWeight.bold)),
              const SizedBox(height: 16),
              TextField(
                controller: introStartCtrl,
                keyboardType: TextInputType.text,
                decoration: const InputDecoration(
                  labelText: 'Inicio Intro (ej: 00:01:30)',
                  labelStyle: TextStyle(color: Colors.white70),
                  hintText: '00:00:00',
                  hintStyle: TextStyle(color: Colors.white24),
                ),
                style: const TextStyle(color: Colors.white),
              ),
              TextField(
                controller: introEndCtrl,
                keyboardType: TextInputType.text,
                decoration: const InputDecoration(
                  labelText: 'Fin Intro (ej: 00:02:10)',
                  labelStyle: TextStyle(color: Colors.white70),
                  hintText: '00:00:00',
                  hintStyle: TextStyle(color: Colors.white24),
                ),
                style: const TextStyle(color: Colors.white),
              ),
              TextField(
                controller: creditsCtrl,
                keyboardType: TextInputType.text,
                decoration: const InputDecoration(
                  labelText: 'Inicio Créditos (ej: 00:42:00)',
                  labelStyle: TextStyle(color: Colors.white70),
                  hintText: '00:00:00',
                  hintStyle: TextStyle(color: Colors.white24),
                ),
                style: const TextStyle(color: Colors.white),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
          ElevatedButton(
            onPressed: () async {
              final iStart = _parseTime(introStartCtrl.text);
              final iEnd = _parseTime(introEndCtrl.text);
              final cStart = _parseTime(creditsCtrl.text);
              
              final eps = _episodesCache[season.id] ?? [];
              final repo = ref.read(seriesRepositoryProvider);
              
              for (var ep in eps) {
                final updatedEp = ep.copyWith(
                  introStartTime: iStart ?? ep.introStartTime,
                  introEndTime: iEnd ?? ep.introEndTime,
                  creditsStartTime: cStart ?? ep.creditsStartTime,
                );
                await repo.updateEpisode(updatedEp);
              }
              
              _loadData();
              if (mounted) Navigator.pop(context);
            },
            child: const Text('Aplicar a todos'),
          )
        ],
      ),
    );
  }
}
