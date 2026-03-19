import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'core/utils/sqlite_service.dart';

// Auth
import 'features/auth/data/repositories/auth_repository_supabase_impl.dart';
import 'features/auth/domain/repositories/auth_repository.dart';

// Movies
import 'features/movies/data/repositories/movie_repository_supabase_impl.dart';
import 'features/movies/domain/repositories/movie_repository.dart';
import 'features/movies/data/repositories/category_repository_supabase_impl.dart';
import 'features/movies/domain/repositories/category_repository.dart';
import 'features/movies/data/repositories/history_repository_impl.dart';
import 'features/movies/domain/repositories/history_repository.dart';

// Series
import 'features/series/data/repositories/series_repository_supabase_impl.dart';
import 'features/series/domain/repositories/series_repository.dart';
import 'features/series/data/repositories/series_category_repository_supabase_impl.dart';
import 'features/series/domain/repositories/series_category_repository.dart';

// SQLite
final sqliteServiceProvider = Provider<SqliteService>((ref) => SqliteService());

// SharedPreferences
final sharedPreferencesProvider = Provider<SharedPreferences>((ref) {
  throw UnimplementedError();
});

// ── History (SQLite) ──────────────────────────────────────────────────────────
final historyRepositoryProvider = Provider<HistoryRepository>((ref) {
  return HistoryRepositoryImpl(ref.read(sqliteServiceProvider));
});

// ── Auth (Supabase) ───────────────────────────────────────────────────────────
final authRepositoryProvider = Provider<AuthRepository>((ref) {
  return AuthRepositorySupabaseImpl();
});

// ── Movies (Supabase) ─────────────────────────────────────────────────────────
final movieRepositoryProvider = Provider<MovieRepository>((ref) {
  return MovieRepositorySupabaseImpl();
});

final categoryRepositoryProvider = Provider<CategoryRepository>((ref) {
  return CategoryRepositorySupabaseImpl();
});

// ── Series (Supabase) ─────────────────────────────────────────────────────────
final seriesRepositoryProvider = Provider<SeriesRepository>((ref) {
  return SeriesRepositorySupabaseImpl();
});

final seriesCategoryRepositoryProvider = Provider<SeriesCategoryRepository>((ref) {
  return SeriesCategoryRepositorySupabaseImpl();
});

// ── UI State ──────────────────────────────────────────────────────────────────
final splashDoneProvider = StateProvider<bool>((ref) => false);
