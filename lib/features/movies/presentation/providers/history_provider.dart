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
    );

    await ref.read(historyRepositoryProvider).saveHistory(history);
    
    // Refresh local state efficiently
    state.whenData((currentHistory) {
      final updatedList = List<WatchHistory>.from(currentHistory);
      final index = updatedList.indexWhere((h) => h.id == id);
      if (index != -1) {
        updatedList[index] = history;
      } else {
        updatedList.insert(0, history);
      }
      // Re-sort to keep most recent first
      updatedList.sort((a, b) => b.lastWatchedAt.compareTo(a.lastWatchedAt));
      state = AsyncValue.data(updatedList);
    });
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
