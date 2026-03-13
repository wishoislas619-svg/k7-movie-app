import 'package:sqflite/sqflite.dart';
import '../../../../core/utils/sqlite_service.dart';
import '../../domain/entities/series.dart';
import '../../domain/entities/season.dart';
import '../../domain/entities/episode.dart';
import '../../domain/entities/series_option.dart';
import '../../domain/repositories/series_repository.dart';

class SeriesRepositoryImpl implements SeriesRepository {
  final SqliteService _sqliteService;

  SeriesRepositoryImpl(this._sqliteService);

  @override
  Future<List<Series>> getSeries() async {
    final db = await _sqliteService.database;
    final maps = await db.query('series', orderBy: 'createdAt DESC');
    return maps.map((map) => Series.fromMap(map)).toList();
  }

  @override
  Future<Series?> getSeriesById(String id) async {
    final db = await _sqliteService.database;
    final maps = await db.query('series', where: 'id = ?', whereArgs: [id]);
    if (maps.isNotEmpty) {
      return Series.fromMap(maps.first);
    }
    return null;
  }

  @override
  Future<void> addSeries(Series series) async {
    final db = await _sqliteService.database;
    await db.insert(
      'series',
      series.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  @override
  Future<void> updateSeries(Series series) async {
    final db = await _sqliteService.database;
    await db.update(
      'series',
      series.toMap(),
      where: 'id = ?',
      whereArgs: [series.id],
    );
  }

  @override
  Future<void> deleteSeries(String id) async {
    final db = await _sqliteService.database;
    await db.delete(
      'series',
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  @override
  Future<void> incrementViews(String id) async {
    final db = await _sqliteService.database;
    await db.rawUpdate('UPDATE series SET views = views + 1 WHERE id = ?', [id]);
  }

  @override
  Future<List<Season>> getSeasonsForSeries(String seriesId) async {
    final db = await _sqliteService.database;
    final maps = await db.query('seasons', where: 'seriesId = ?', whereArgs: [seriesId], orderBy: 'seasonNumber ASC');
    return maps.map((map) => Season.fromMap(map)).toList();
  }

  @override
  Future<void> addSeason(Season season) async {
    final db = await _sqliteService.database;
    await db.insert('seasons', season.toMap(), conflictAlgorithm: ConflictAlgorithm.replace);
  }

  @override
  Future<void> updateSeason(Season season) async {
    final db = await _sqliteService.database;
    await db.update('seasons', season.toMap(), where: 'id = ?', whereArgs: [season.id]);
  }

  @override
  Future<void> deleteSeason(String id) async {
    final db = await _sqliteService.database;
    await db.delete('seasons', where: 'id = ?', whereArgs: [id]);
  }

  @override
  Future<void> replaceSeasonsForSeries(String seriesId, List<Season> seasons) async {
    final db = await _sqliteService.database;
    await db.transaction((txn) async {
      await txn.delete('seasons', where: 'seriesId = ?', whereArgs: [seriesId]);
      for (var season in seasons) {
        await txn.insert('seasons', season.toMap());
      }
    });
  }

  @override
  Future<List<Episode>> getEpisodesForSeason(String seasonId) async {
    final db = await _sqliteService.database;
    final maps = await db.query('episodes', where: 'seasonId = ?', whereArgs: [seasonId], orderBy: 'episodeNumber ASC');
    return maps.map((map) => Episode.fromMap(map)).toList();
  }

  @override
  Future<void> addEpisode(Episode episode) async {
    final db = await _sqliteService.database;
    await db.insert('episodes', episode.toMap(), conflictAlgorithm: ConflictAlgorithm.replace);
  }

  @override
  Future<void> updateEpisode(Episode episode) async {
    final db = await _sqliteService.database;
    await db.update('episodes', episode.toMap(), where: 'id = ?', whereArgs: [episode.id]);
  }

  @override
  Future<void> deleteEpisode(String id) async {
    final db = await _sqliteService.database;
    await db.delete('episodes', where: 'id = ?', whereArgs: [id]);
  }

  @override
  Future<void> replaceEpisodesForSeason(String seasonId, List<Episode> episodes) async {
    final db = await _sqliteService.database;
    await db.transaction((txn) async {
      await txn.delete('episodes', where: 'seasonId = ?', whereArgs: [seasonId]);
      for (var ep in episodes) {
        await txn.insert('episodes', ep.toMap());
      }
    });
  }

  @override
  Future<List<SeriesOption>> getSeriesOptions(String seriesId) async {
    final db = await _sqliteService.database;
    final maps = await db.query('series_options', where: 'seriesId = ?', whereArgs: [seriesId]);
    return maps.map((map) => SeriesOption.fromMap(map)).toList();
  }

  @override
  Future<void> addSeriesOption(SeriesOption option) async {
     final db = await _sqliteService.database;
     await db.insert('series_options', option.toMap(), conflictAlgorithm: ConflictAlgorithm.replace);
  }

  @override
  Future<void> updateSeriesOption(SeriesOption option) async {
     final db = await _sqliteService.database;
     await db.update('series_options', option.toMap(), where: 'id = ?', whereArgs: [option.id]);
  }

  @override
  Future<void> deleteSeriesOption(String id) async {
     final db = await _sqliteService.database;
     await db.delete('series_options', where: 'id = ?', whereArgs: [id]);
  }
}
