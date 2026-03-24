import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:movie_app/features/movies/domain/entities/watch_history.dart';
import 'package:movie_app/providers.dart';

final historyProvider = StateNotifierProvider<HistoryNotifier, AsyncValue<List<WatchHistory>>>((ref) {
  return HistoryNotifier(ref);
});

class HistoryNotifier extends StateNotifier<AsyncValue<List<WatchHistory>>> {
  final Ref ref;

  HistoryNotifier(this.ref) : super(const AsyncValue.loading()) {
    loadHistory();
  }

  Future<void> loadHistory() async {
    state = const AsyncValue.loading();
    try {
      final repository = ref.read(historyRepositoryProvider);
      final history = await repository.getHistory();
      state = AsyncValue.data(history);
    } catch (e, stack) {
      state = AsyncValue.error(e, stack);
    }
  }

  Future<void> saveProgress({
    required String mediaId,
    String? episodeId,
    required String mediaType,
    required int position,
    required int duration,
    required String title,
    String? subtitle,
    required String imagePath,
    String? videoOptionId,
  }) async {
    final id = episodeId ?? mediaId;
    final history = WatchHistory(
      id: id,
      mediaId: mediaId,
      episodeId: episodeId,
      mediaType: mediaType,
      lastPosition: position,
      totalDuration: duration,
      lastWatchedAt: DateTime.now(),
      title: title,
      subtitle: subtitle,
      imagePath: imagePath,
      videoOptionId: videoOptionId,
    );

    await ref.read(historyRepositoryProvider).saveHistory(history);
    
    // Recargar la lista completa desde la DB para asegurar sincronización total
    await loadHistory();
  }

  Future<void> removeHistory(String id) async {
    await ref.read(historyRepositoryProvider).removeHistory(id);
    state.whenData((currentHistory) {
      state = AsyncValue.data(currentHistory.where((h) => h.id != id).toList());
    });
  }

  Future<WatchHistory?> getProgress(String id) async {
    return ref.read(historyRepositoryProvider).getHistoryById(id);
  }
}
