import '../entities/watch_history.dart';

abstract class HistoryRepository {
  Future<List<WatchHistory>> getHistory();
  Future<WatchHistory?> getHistoryById(String id);
  Future<void> saveHistory(WatchHistory history);
  Future<void> removeHistory(String id);
  Future<void> clearHistory();
}
