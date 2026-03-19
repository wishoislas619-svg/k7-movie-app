import 'dart:convert';
import 'package:movie_app/core/services/supabase_service.dart';
import '../../domain/entities/series.dart';
import '../../domain/entities/season.dart';
import '../../domain/entities/episode.dart';
import '../../domain/entities/series_option.dart';
import '../../domain/repositories/series_repository.dart';

class SeriesRepositorySupabaseImpl implements SeriesRepository {
  final _client = SupabaseService.client;

  // ── Mappers ────────────────────────────────────────────────────────────────

  Series _seriesFromRow(Map<String, dynamic> r) => Series(
        id: r['id'] as String,
        name: r['name'] as String,
        imagePath: r['image_path'] as String? ?? '',
        categoryId: r['category_id'] as String?,
        description: r['description'] as String?,
        detailsUrl: r['details_url'] as String?,
        backdropUrl: r['backdrop_url'] as String?,
        views: r['views'] as int? ?? 0,
        rating: (r['rating'] as num?)?.toDouble() ?? 0.0,
        year: r['year'] as String?,
        isPopular: r['is_popular'] as bool? ?? false,
        createdAt: DateTime.parse(r['created_at'] as String),
      );

  Map<String, dynamic> _seriesToRow(Series s) => {
        'name': s.name,
        'image_path': s.imagePath,
        'category_id': s.categoryId,
        'description': s.description,
        'details_url': s.detailsUrl,
        'backdrop_url': s.backdropUrl,
        'views': s.views,
        'rating': s.rating,
        'year': s.year,
        'is_popular': s.isPopular,
      };

  Season _seasonFromRow(Map<String, dynamic> r) => Season(
        id: r['id'] as String,
        seriesId: r['series_id'] as String,
        seasonNumber: r['order_num'] as int? ?? 1,
        name: r['name'] as String,
      );

  Map<String, dynamic> _seasonToRow(Season s) => {
        'series_id': s.seriesId,
        'order_num': s.seasonNumber,
        'name': s.name,
      };

  Episode _episodeFromRow(Map<String, dynamic> r) {
    List<EpisodeUrl> urls = [];
    final raw = r['urls'];
    if (raw != null) {
      try {
        final decoded = raw is String ? json.decode(raw) : raw;
        if (decoded is List) {
          urls = decoded.map((e) => EpisodeUrl.fromMap(e as Map<String, dynamic>)).toList();
        }
      } catch (_) {}
    }
    return Episode(
      id: r['id'] as String,
      seasonId: r['season_id'] as String,
      episodeNumber: r['episode_number'] as int? ?? 1,
      name: r['name'] as String,
      url: r['video_url'] as String? ?? '',
      urls: urls,
    );
  }

  Map<String, dynamic> _episodeToRow(Episode e) => {
        'season_id': e.seasonId,
        'episode_number': e.episodeNumber,
        'name': e.name,
        'video_url': e.url,
        'urls': json.encode(e.urls.map((u) => u.toMap()).toList()),
      };

  SeriesOption _optionFromRow(Map<String, dynamic> r) => SeriesOption(
        id: r['id'] as String,
        seriesId: r['series_id'] as String,
        serverImagePath: r['server_image_path'] as String? ?? '',
        resolution: r['resolution'] as String? ?? '',
        videoUrl: r['video_url'] as String? ?? '',
        language: r['language'] as String?,
      );

  // ── Series ─────────────────────────────────────────────────────────────────

  @override
  Future<List<Series>> getSeries() async {
    final data = await _client
        .from('series')
        .select()
        .order('created_at', ascending: false);
    return (data as List).map((r) => _seriesFromRow(r)).toList();
  }

  @override
  Future<Series?> getSeriesById(String id) async {
    final row = await _client.from('series').select().eq('id', id).maybeSingle();
    if (row == null) return null;
    return _seriesFromRow(row);
  }

  @override
  Future<void> addSeries(Series series) async {
    final row = _seriesToRow(series);
    if (series.id.isNotEmpty && series.id.length == 36) row['id'] = series.id;
    await _client.from('series').insert(row);
  }

  @override
  Future<void> updateSeries(Series series) async {
    await _client.from('series').update(_seriesToRow(series)).eq('id', series.id);
  }

  @override
  Future<void> deleteSeries(String id) async {
    await _client.from('series').delete().eq('id', id);
  }

  @override
  Future<void> incrementViews(String id) async {
    try {
      await _client.rpc('increment_series_views', params: {'p_id': id});
    } catch (_) {
      final row = await _client.from('series').select('views').eq('id', id).single();
      final current = (row['views'] as int?) ?? 0;
      await _client.from('series').update({'views': current + 1}).eq('id', id);
    }
  }

  // ── Seasons ────────────────────────────────────────────────────────────────

  @override
  Future<List<Season>> getSeasonsForSeries(String seriesId) async {
    final data = await _client
        .from('seasons')
        .select()
        .eq('series_id', seriesId)
        .order('order_num', ascending: true);
    return (data as List).map((r) => _seasonFromRow(r)).toList();
  }

  @override
  Future<void> addSeason(Season season) async {
    final row = _seasonToRow(season);
    if (season.id.isNotEmpty && season.id.length == 36) row['id'] = season.id;
    await _client.from('seasons').insert(row);
  }

  @override
  Future<void> updateSeason(Season season) async {
    await _client.from('seasons').update(_seasonToRow(season)).eq('id', season.id);
  }

  @override
  Future<void> deleteSeason(String id) async {
    await _client.from('seasons').delete().eq('id', id);
  }

  @override
  Future<void> replaceSeasonsForSeries(String seriesId, List<Season> seasons) async {
    await _client.from('seasons').delete().eq('series_id', seriesId);
    if (seasons.isNotEmpty) {
      final rows = seasons.map((s) {
        final r = _seasonToRow(s);
        if (s.id.isNotEmpty && s.id.length == 36) r['id'] = s.id;
        return r;
      }).toList();
      await _client.from('seasons').insert(rows);
    }
  }

  // ── Episodes ───────────────────────────────────────────────────────────────

  @override
  Future<List<Episode>> getEpisodesForSeason(String seasonId) async {
    final data = await _client
        .from('episodes')
        .select()
        .eq('season_id', seasonId)
        .order('episode_number', ascending: true);
    return (data as List).map((r) => _episodeFromRow(r)).toList();
  }

  @override
  Future<void> addEpisode(Episode episode) async {
    final row = _episodeToRow(episode);
    if (episode.id.isNotEmpty && episode.id.length == 36) row['id'] = episode.id;
    await _client.from('episodes').insert(row);
  }

  @override
  Future<void> updateEpisode(Episode episode) async {
    await _client.from('episodes').update(_episodeToRow(episode)).eq('id', episode.id);
  }

  @override
  Future<void> deleteEpisode(String id) async {
    await _client.from('episodes').delete().eq('id', id);
  }

  @override
  Future<void> replaceEpisodesForSeason(String seasonId, List<Episode> episodes) async {
    await _client.from('episodes').delete().eq('season_id', seasonId);
    if (episodes.isNotEmpty) {
      final rows = episodes.map((e) {
        final r = _episodeToRow(e);
        if (e.id.isNotEmpty && e.id.length == 36) r['id'] = e.id;
        return r;
      }).toList();
      await _client.from('episodes').insert(rows);
    }
  }

  // ── Series Options ─────────────────────────────────────────────────────────

  @override
  Future<List<SeriesOption>> getSeriesOptions(String seriesId) async {
    final data = await _client
        .from('series_options')
        .select()
        .eq('series_id', seriesId);
    return (data as List).map((r) => _optionFromRow(r)).toList();
  }

  @override
  Future<void> addSeriesOption(SeriesOption option) async {
    await _client.from('series_options').insert({
      'series_id': option.seriesId,
      'server_image_path': option.serverImagePath,
      'resolution': option.resolution,
      'video_url': option.videoUrl,
      'language': option.language,
    });
  }

  @override
  Future<void> updateSeriesOption(SeriesOption option) async {
    await _client.from('series_options').update({
      'series_id': option.seriesId,
      'server_image_path': option.serverImagePath,
      'resolution': option.resolution,
      'video_url': option.videoUrl,
      'language': option.language,
    }).eq('id', option.id);
  }

  @override
  Future<void> deleteSeriesOption(String id) async {
    await _client.from('series_options').delete().eq('id', id);
  }
}
