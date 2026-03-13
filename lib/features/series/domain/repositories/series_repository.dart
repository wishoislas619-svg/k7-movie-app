import '../entities/series.dart';
import '../entities/season.dart';
import '../entities/episode.dart';
import '../entities/series_option.dart';

abstract class SeriesRepository {
  Future<List<Series>> getSeries();
  Future<Series?> getSeriesById(String id);
  Future<void> addSeries(Series series);
  Future<void> updateSeries(Series series);
  Future<void> deleteSeries(String id);
  Future<void> incrementViews(String id);

  Future<List<Season>> getSeasonsForSeries(String seriesId);
  Future<void> addSeason(Season season);
  Future<void> updateSeason(Season season);
  Future<void> deleteSeason(String id);
  Future<void> replaceSeasonsForSeries(String seriesId, List<Season> seasons);

  Future<List<Episode>> getEpisodesForSeason(String seasonId);
  Future<void> addEpisode(Episode episode);
  Future<void> updateEpisode(Episode episode);
  Future<void> deleteEpisode(String id);
  Future<void> replaceEpisodesForSeason(String seasonId, List<Episode> episodes);

  Future<List<SeriesOption>> getSeriesOptions(String seriesId);
  Future<void> addSeriesOption(SeriesOption option);
  Future<void> updateSeriesOption(SeriesOption option);
  Future<void> deleteSeriesOption(String id);
}
