import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../core/utils/sqlite_service.dart';
import '../features/auth/data/repositories/auth_repository_impl.dart';
import '../features/auth/domain/repositories/auth_repository.dart';
import '../features/movies/data/repositories/movie_repository_impl.dart';
import '../features/movies/domain/repositories/movie_repository.dart';
import '../features/movies/data/repositories/category_repository_impl.dart';
import '../features/movies/domain/repositories/category_repository.dart';
import '../features/series/data/repositories/series_repository_impl.dart';
import '../features/series/domain/repositories/series_repository.dart';
import '../features/series/data/repositories/series_category_repository_impl.dart';
import '../features/series/domain/repositories/series_category_repository.dart';

final sqliteServiceProvider = Provider<SqliteService>((ref) {
  return SqliteService();
});

final sharedPreferencesProvider = Provider<SharedPreferences>((ref) {
  throw UnimplementedError(); // Initialized in main
});

final authRepositoryProvider = Provider<AuthRepository>((ref) {
  final sqliteService = ref.watch(sqliteServiceProvider);
  final prefs = ref.watch(sharedPreferencesProvider);
  return AuthRepositorySqliteImpl(sqliteService, prefs);
});

final movieRepositoryProvider = Provider<MovieRepository>((ref) {
  final sqliteService = ref.watch(sqliteServiceProvider);
  // Easy to change to MySQL implementation here in the future:
  // return MovieRepositoryMysqlImpl(ref.watch(mysqlServiceProvider));
  return MovieRepositorySqliteImpl(sqliteService);
});

final categoryRepositoryProvider = Provider<CategoryRepository>((ref) {
  final sqliteService = ref.watch(sqliteServiceProvider);
  return CategoryRepositorySqliteImpl(sqliteService);
});

final seriesRepositoryProvider = Provider<SeriesRepository>((ref) {
  final sqliteService = ref.watch(sqliteServiceProvider);
  return SeriesRepositoryImpl(sqliteService);
});

final seriesCategoryRepositoryProvider = Provider<SeriesCategoryRepository>((ref) {
  final sqliteService = ref.watch(sqliteServiceProvider);
  return SeriesCategoryRepositoryImpl(sqliteService);
});

final splashDoneProvider = StateProvider<bool>((ref) => false);
