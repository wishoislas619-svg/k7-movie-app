import 'package:movie_app/core/services/supabase_service.dart';
import '../../domain/entities/watch_history.dart';
import '../../domain/repositories/history_repository.dart';

class HistoryRepositorySupabaseImpl implements HistoryRepository {
  final _client = SupabaseService.client;

  WatchHistory _fromRow(Map<String, dynamic> row) {
    return WatchHistory(
      id: row['id'] as String,
      mediaId: row['media_id'] as String,
      episodeId: row['episode_id'] as String?,
      mediaType: row['media_type'] as String,
      lastPosition: row['last_position'] as int,
      totalDuration: row['total_duration'] as int,
      lastWatchedAt: DateTime.parse(row['updated_at'] as String),
      title: row['title'] as String? ?? '',
      imagePath: row['image_path'] as String? ?? '',
      subtitle: row['subtitle'] as String?,
      videoOptionId: row['video_option_id'] as String?,
    );
  }

  @override
  Future<List<WatchHistory>> getHistory() async {
    final userId = _client.auth.currentUser?.id;
    if (userId == null) {
      print('--- [HISTORIAL] Error: No se puede obtener historial porque no hay sesión ---');
      return [];
    }

    try {
      print('--- [HISTORIAL] Cargando historial para el usuario: $userId ---');
      final data = await _client
          .from('user_watch_history')
          .select()
          .eq('user_id', userId)
          .order('updated_at', ascending: false);

      final list = (data as List).map((row) => _fromRow(row)).toList();
      print('--- [HISTORIAL] ${list.length} registros cargados con éxito ---');
      return list;
    } catch (e) {
      print('--- [HISTORIAL] ERROR al cargar desde Supabase: $e ---');
      return [];
    }
  }

  @override
  Future<WatchHistory?> getHistoryById(String id) async {
    final userId = _client.auth.currentUser?.id;
    if (userId == null) return null;

    try {
      // Primero buscar por episode_id (capítulo específico)
      final byEpisode = await _client
          .from('user_watch_history')
          .select()
          .eq('user_id', userId)
          .eq('episode_id', id)
          .maybeSingle();

      if (byEpisode != null) return _fromRow(byEpisode);

      // Si no encontró, buscar por media_id (película o serie completa)
      final byMedia = await _client
          .from('user_watch_history')
          .select()
          .eq('user_id', userId)
          .eq('media_id', id)
          .order('updated_at', ascending: false)
          .limit(1)
          .maybeSingle();

      if (byMedia != null) return _fromRow(byMedia);
    } catch (e) {
      print('--- [HISTORIAL] ERROR en getHistoryById: $e ---');
    }
    return null;
  }

  @override
  Future<void> saveHistory(WatchHistory history) async {
    final userId = _client.auth.currentUser?.id;
    if (userId == null) {
      print('--- [HISTORIAL] Error: No hay sesión de usuario activa ---');
      return;
    }

    final row = {
      'user_id': userId,
      'media_id': history.mediaId,
      'episode_id': history.episodeId,
      'media_type': history.mediaType,
      'last_position': history.lastPosition,
      'total_duration': history.totalDuration,
      'updated_at': DateTime.now().toIso8601String(),
      'title': history.title,
      'image_path': history.imagePath,
      'subtitle': history.subtitle,
      'video_option_id': history.videoOptionId,
    };

    try {
      print('--- [HISTORIAL] Intentando guardar progreso para ${history.title} pos: ${history.lastPosition} ---');
      await _client.from('user_watch_history').upsert(
        row,
        onConflict: 'user_id, media_id',
      );
      print('--- [HISTORIAL] Guardado con éxito en Supabase ---');
    } catch (e) {
      print('--- [HISTORIAL] ERROR al guardar en Supabase: $e ---');
    }
  }

  @override
  Future<void> removeHistory(String id) async {
    final userId = _client.auth.currentUser?.id;
    if (userId == null) return;

    await _client
        .from('user_watch_history')
        .delete()
        .eq('user_id', userId)
        .eq('media_id', id);
  }

  @override
  Future<void> clearHistory() async {
    final userId = _client.auth.currentUser?.id;
    if (userId == null) return;

    await _client
        .from('user_watch_history')
        .delete()
        .eq('user_id', userId);
  }
}
