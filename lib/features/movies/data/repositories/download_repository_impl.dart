
import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'dart:math';
import 'package:ffmpeg_kit_flutter_new_min_gpl/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_min_gpl/ffprobe_kit.dart';
import 'package:ffmpeg_kit_flutter_new_min_gpl/return_code.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:sqflite/sqflite.dart';
import 'package:http/http.dart' as http;
import 'package:movie_app/core/utils/sqlite_service.dart';
import 'package:movie_app/features/movies/domain/entities/download_task.dart' as my;
import 'package:movie_app/providers.dart';
import 'package:movie_app/core/services/notification_service.dart';
import 'package:movie_app/core/services/foreground_service.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:movie_app/core/services/storage_service.dart';
import 'package:movie_app/core/constants/app_constants.dart';
import 'package:movie_app/features/cast/services/media_proxy_service.dart';

class DownloadRepository {
  final SqliteService _sqliteService;
  final Map<String, _DownloadProgressInfo> _progressInfos = {};
  final Map<String, bool> _hlsCancelFlags = {};

  // Ya no usamos una constante, consultamos StorageService dinámicamente.

  DownloadRepository(this._sqliteService) {
    _initDownloader();
  }

  void _initDownloader() async {
    // Configure global notifications
    FileDownloader().configureNotification(
      running: const TaskNotification('Descargando {displayName}', 'Progreso: {progress} - {networkSpeed}'),
      complete: const TaskNotification('Descarga completada', '{displayName} se guardó con éxito'),
      error: const TaskNotification('Error en la descarga', 'No se pudo descargar {displayName}'),
      paused: const TaskNotification('Descarga pausada', '{displayName}'),
      progressBar: true,
      tapOpensFile: true,
    );
    
    // Request notification permission for Android 13+
    if (Platform.isAndroid) {
      await FileDownloader().permissions.request(PermissionType.notifications);
    }
  }

  Future<List<my.DownloadTask>> getDownloads() async {
    final db = await _sqliteService.database;
    final List<Map<String, dynamic>> maps =
        await db.query('downloads', orderBy: 'createdAt DESC');
    return maps.map((map) => my.DownloadTask.fromMap(map)).toList();
  }

  Future<void> saveDownloadTask(my.DownloadTask task) async {
    final db = await _sqliteService.database;
    try {
      await db.insert('downloads', task.toMap(),
          conflictAlgorithm: ConflictAlgorithm.replace);
    } catch (e) {
      if (e.toString().contains('no column named isSeries')) {
         try { await db.execute('ALTER TABLE downloads ADD COLUMN isSeries INTEGER DEFAULT 0'); } catch (_) {}
         try { await db.execute('ALTER TABLE downloads ADD COLUMN seasonNumber INTEGER'); } catch (_) {}
         try { await db.execute('ALTER TABLE downloads ADD COLUMN episodeNumber INTEGER'); } catch (_) {}
         try { await db.execute('ALTER TABLE downloads ADD COLUMN originalFilename TEXT'); } catch (_) {}
         await db.insert('downloads', task.toMap(), conflictAlgorithm: ConflictAlgorithm.replace);
      } else {
        rethrow;
      }
    }
  }

  Future<void> updateDownloadTask(my.DownloadTask task) async {
    final db = await _sqliteService.database;
    try {
      await db.update(
        'downloads',
        task.toMap(),
        where: 'id = ?',
        whereArgs: [task.id],
      );
    } catch (e) {
      if (e.toString().contains('no column named isSeries')) {
         try { await db.execute('ALTER TABLE downloads ADD COLUMN isSeries INTEGER DEFAULT 0'); } catch (_) {}
         try { await db.execute('ALTER TABLE downloads ADD COLUMN seasonNumber INTEGER'); } catch (_) {}
         try { await db.execute('ALTER TABLE downloads ADD COLUMN episodeNumber INTEGER'); } catch (_) {}
         try { await db.execute('ALTER TABLE downloads ADD COLUMN originalFilename TEXT'); } catch (_) {}
         await db.update('downloads', task.toMap(), where: 'id = ?', whereArgs: [task.id]);
      } else {
        rethrow;
      }
    }
  }

  Future<my.DownloadTask?> getDownloadById(String id) async {
    final db = await _sqliteService.database;
    final rows = await db.query('downloads', where: 'id = ?', whereArgs: [id]);
    if (rows.isEmpty) return null;
    return my.DownloadTask.fromMap(rows.first);
  }


  Future<void> deleteDownloadTask(String id) async {
    final db = await _sqliteService.database;
    final downloads = await db.query('downloads', where: 'id = ?', whereArgs: [id]);
    if (downloads.isNotEmpty) {
      final task = my.DownloadTask.fromMap(downloads.first);
      if (task.savePath != null) {
        final file = File(task.savePath!);
        if (await file.exists()) {
          await file.delete();
        }
      }
    }
    await db.delete('downloads', where: 'id = ?', whereArgs: [id]);
    
    await FileDownloader().cancelTasksWithIds([id]);
  }

  Future<String?> ensurePlayableFile(
    my.DownloadTask task, {
    Function(double progress, String speed)? onProgress,
  }) async {
    if (Platform.isAndroid) {
      if (await Permission.videos.isDenied) await Permission.videos.request();
      if (await Permission.storage.isDenied) await Permission.storage.request();
    }

    print('[PLAY] ensurePlayableFile start id=${task.id} savePath=${task.savePath}');
    if (task.savePath == null) {
      final resolved = await _findExistingFile(task);
      print('[PLAY] resolved path=$resolved');
      if (resolved == null) return null;
      task = task.copyWith(savePath: resolved);
    }
    final existing = File(task.savePath!);
    if (!await existing.exists()) return null;

    if (task.savePath!.toLowerCase().endsWith('.mp4')) {
      return task.savePath;
    }

    final converted = await _convertToMp4IfNeeded(task.savePath!, onProgress: onProgress);
    if (converted != null) {
      await updateDownloadTask(task.copyWith(savePath: converted));
      await _updateTaskMediaInfo(task, converted);
      return converted;
    }

    // Fallback: return original file to allow TS playback if supported
    await _updateTaskMediaInfo(task, task.savePath!);
    return task.savePath;
  }

  Future<void> deleteFailedDownloads() async {
    final db = await _sqliteService.database;
    final failed = await db.query('downloads', where: 'status = ?', whereArgs: ['error']);

    final directory = await getApplicationDocumentsDirectory();
    final downloadsDir = Directory('${directory.path}/downloads');
    if (await downloadsDir.exists()) {
      // Remove any leftover conversion temp files
      final tempFiles = await downloadsDir
          .list()
          .where((e) => e is File && e.path.toLowerCase().endsWith('.mp4.tmp'))
          .toList();
      for (final entity in tempFiles) {
        try {
          await (entity as File).delete();
        } catch (_) {}
      }
    }

    if (failed.isEmpty) return;

    for (final row in failed) {
      final task = my.DownloadTask.fromMap(row);
      // Remove file by saved path if present
      if (task.savePath != null) {
        final f = File(task.savePath!);
        if (await f.exists()) {
          await f.delete();
        }
      }

      // Remove any residual files matching the base filename
      final base = _buildSafeFileBase(task);
      final pubDir = '/storage/emulated/0/Download/K7-MOVIE';
      final candidates = [
        File('${downloadsDir.path}/$base.mp4'),
        File('${downloadsDir.path}/$base.ts'),
        File('${downloadsDir.path}/$base.m3u8'),
        File('${downloadsDir.path}/$base.tmp'),
        // Candidatos públicos
        File('$pubDir/$base.mp4'),
        File('$pubDir/$base.ts'),
        File('$pubDir/$base.m3u8'),
      ];
      for (final f in candidates) {
        if (await f.exists()) {
          await f.delete();
        }
      }

      await FileDownloader().cancelTasksWithIds([task.id]);
    }

    await db.delete('downloads', where: 'status = ?', whereArgs: ['error']);
  }

  Future<void> enqueueDownload(my.DownloadTask task,
      {required Function(double, String) onProgress,
      required Function(my.DownloadStatus) onStatusChange}) async {
    
    // Detect HLS: classic .m3u8 OR .txt manifests from known CDN domains
    final isHls = task.videoUrl.contains('.m3u8') ||
        (task.videoUrl.contains('.txt') && 
         (task.videoUrl.contains('goldenfieldproductionworks') ||
          task.videoUrl.contains('cf-master') ||
          task.videoUrl.contains('index-f') ||
          task.videoUrl.contains('/v4/db/')));
    print('[DL] enqueue id=${task.id} isHls=$isHls url=${task.videoUrl}');
    
    // 🛡️ BYPASS PROXY PARA DESCARGAS
    var finalUrl = task.videoUrl;
    var finalHeaders = task.headers != null ? Map<String, String>.from(task.headers!) : <String, String>{};

    // Si la URL viene del proxy local, extraemos la original y sus headers.
    final unproxied = MediaProxyService.tryUnproxy(finalUrl);
    if (unproxied != null) {
      finalUrl = unproxied['url'] as String;
      if (unproxied['headers'] != null) {
        // Combinamos los headers del proxy con los que ya teníamos (priorizando los del proxy)
        finalHeaders.addAll(unproxied['headers'] as Map<String, String>);
      }
      print('🛡️ [DL_BYPASS] URL des-proxeada para descarga directa: $finalUrl');
    }

    // Default headers if none provided
    if (finalHeaders.isEmpty) {
      finalHeaders['User-Agent'] = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36';
      finalHeaders['Referer'] = finalUrl.split('/').take(3).join('/');
    }
    
    // Cleanup headers for background downloader
    finalHeaders.remove('range');
    finalHeaders.remove('Range');

    var finalExt = finalUrl.split('?').first.split('.').last;
    // Normalize .txt manifests to be treated as m3u8 for downstream logic
    if (isHls && finalExt == 'txt') finalExt = 'm3u8';
    print('[DL] finalUrl=$finalUrl ext=$finalExt');

    // If HLS, skip the m3u8→mp4 direct-link conversion (txt manifests can't be converted that way)
    if (isHls && !finalUrl.contains('.txt')) {
      final mp4Url = await _tryConvertToMp4(finalUrl, headers: finalHeaders);
      if (mp4Url != null) {
        finalUrl = mp4Url;
        finalExt = 'mp4';
        print("Smart Conversion Success: Swapped HLS for MP4: $finalUrl");
      }
    }
    print('[DL] finalUrl=$finalUrl ext=$finalExt (after conversion attempt)');

    final fileName = '${task.movieName.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_')}_${task.resolution}.$finalExt';

    await updateDownloadTask(task.copyWith(status: my.DownloadStatus.downloading, videoUrl: finalUrl));

    // If still HLS after conversion attempt, download and merge segments.
    if (isHls || finalUrl.contains('.m3u8') || finalUrl.contains('.txt')) {
      print('[DL] HLS path selected');
      _downloadHlsAsTs(
        task: task.copyWith(videoUrl: finalUrl),
        fileName: fileName.replaceAll('.m3u8', '.ts').replaceAll('.txt', '.ts'),
        headers: finalHeaders,
        onProgress: onProgress,
        onStatusChange: onStatusChange,
      );
      return;
    }

    final downloadTask = DownloadTask(
      taskId: task.id,
      url: finalUrl,
      filename: fileName,
      headers: finalHeaders,
      directory: 'downloads',
      updates: Updates.statusAndProgress,
      allowPause: true,
      retries: 5,
      baseDirectory: BaseDirectory.applicationDocuments,
      displayName: task.movieName,
    );

    final enqueued = await FileDownloader().enqueue(downloadTask);
    if (!enqueued) {
      onStatusChange(my.DownloadStatus.error);
    }
  }

  Future<void> _downloadHlsAsTs({
    required my.DownloadTask task,
    required String fileName,
    required Map<String, String> headers,
    required Function(double, String) onProgress,
    required Function(my.DownloadStatus) onStatusChange,
  }) async {
    try {
      final client = http.Client();
      print('[HLS] Fetch playlist: ${task.videoUrl}');
      final playlistRes = await client.get(Uri.parse(task.videoUrl), headers: headers)
          .timeout(const Duration(seconds: 10));

      if (playlistRes.statusCode != 200 && playlistRes.statusCode != 206) {
        print('[HLS] playlist status=${playlistRes.statusCode}');
        onStatusChange(my.DownloadStatus.error);
        client.close();
        return;
      }

      final playlistText = playlistRes.body;
      final selectedPlaylistUrl = _selectVariantPlaylistUrl(task.videoUrl, playlistText);

      if (selectedPlaylistUrl != null) {
        print('[HLS] selected variant: $selectedPlaylistUrl');
        final variantRes = await client.get(Uri.parse(selectedPlaylistUrl), headers: headers)
            .timeout(const Duration(seconds: 10));
        if (variantRes.statusCode != 200 && variantRes.statusCode != 206) {
          print('[HLS] variant status=${variantRes.statusCode}');
          onStatusChange(my.DownloadStatus.error);
          client.close();
          return;
        }
        await _downloadSegmentsFromPlaylist(
          playlistUrl: selectedPlaylistUrl,
          playlistText: variantRes.body,
          fileName: fileName,
          headers: headers,
          task: task,
          onProgress: onProgress,
          onStatusChange: onStatusChange,
        );
        client.close();
        return;
      }

      await _downloadSegmentsFromPlaylist(
        playlistUrl: task.videoUrl,
        playlistText: playlistText,
        fileName: fileName,
        headers: headers,
        task: task,
        onProgress: onProgress,
        onStatusChange: onStatusChange,
      );
      client.close();
    } catch (e) {
      print("HLS download error: $e");
      onStatusChange(my.DownloadStatus.error);
    }
  }

  String? _selectVariantPlaylistUrl(String masterUrl, String playlistText) {
    if (!playlistText.contains('#EXT-X-STREAM-INF')) return null;

    final lines = playlistText.split('\n');
    int bestBw = -1;
    String? bestUrl;

    for (int i = 0; i < lines.length; i++) {
      final line = lines[i].trim();
      if (line.startsWith('#EXT-X-STREAM-INF')) {
        final bwMatch = RegExp(r'BANDWIDTH=(\d+)').firstMatch(line);
        final bw = bwMatch != null ? int.tryParse(bwMatch.group(1) ?? '') ?? 0 : 0;
        final next = (i + 1 < lines.length) ? lines[i + 1].trim() : '';
        if (next.isNotEmpty && !next.startsWith('#')) {
          if (bw >= bestBw) {
            bestBw = bw;
            bestUrl = _resolveUrl(masterUrl, next);
          }
        }
      }
    }
    return bestUrl;
  }

  Future<void> _downloadSegmentsFromPlaylist({
    required String playlistUrl,
    required String playlistText,
    required String fileName,
    required Map<String, String> headers,
    required my.DownloadTask task,
    required Function(double, String) onProgress,
    required Function(my.DownloadStatus) onStatusChange,
  }) async {
    if (playlistText.contains('#EXT-X-KEY')) {
      // Encrypted HLS not supported in this simple downloader
      print('HLS encrypted stream detected. Aborting download.');
      onStatusChange(my.DownloadStatus.error);
      return;
    }

    final segmentUrls = _extractSegmentUrls(playlistUrl, playlistText);
    if (segmentUrls.isEmpty) {
      print('[HLS] no segments found');
      onStatusChange(my.DownloadStatus.error);
      return;
    }
    print('[HLS] segments=${segmentUrls.length}');

    final directory = await getApplicationDocumentsDirectory();
    final downloadsDir = Directory('${directory.path}/downloads');
    if (!await downloadsDir.exists()) {
      await downloadsDir.create(recursive: true);
    }

    final outputPath = '${downloadsDir.path}/$fileName';
    final outputFile = File(outputPath);
    final progressFile = File('$outputPath.progress');
    int startIndex = 0;
    if (await progressFile.exists()) {
      try {
        startIndex = int.parse((await progressFile.readAsString()).trim());
      } catch (_) {
        startIndex = 0;
      }
    }
    if (!await outputFile.exists() || startIndex == 0) {
      if (await outputFile.exists()) {
        await outputFile.delete();
      }
    }

    final raf = await outputFile.open(mode: startIndex > 0 ? FileMode.append : FileMode.write);
    final client = http.Client();
    _hlsCancelFlags[task.id] = false;

    int completed = 0;
    int totalBytes = 0;
    final startTime = DateTime.now();

    try {
      await WakelockPlus.enable();
      await ForegroundService.start(title: 'Descargando', text: task.movieName);
      for (int i = startIndex; i < segmentUrls.length; i++) {
        if (_hlsCancelFlags[task.id] == true) {
          await raf.close();
          client.close();
          await WakelockPlus.disable();
          await ForegroundService.stop();
          _hlsCancelFlags.remove(task.id);
          onStatusChange(my.DownloadStatus.paused);
          return;
        }
        final url = segmentUrls[i];
        final res = await client.get(Uri.parse(url), headers: headers)
            .timeout(const Duration(seconds: 20));
        if (res.statusCode != 200 && res.statusCode != 206) {
          await raf.close();
          client.close();
          print('[HLS] segment status=${res.statusCode} url=$url');
          onStatusChange(my.DownloadStatus.error);
          await WakelockPlus.disable();
          await ForegroundService.stop();
          _hlsCancelFlags.remove(task.id);
          return;
        }
        await raf.writeFrom(res.bodyBytes);
        totalBytes += res.bodyBytes.length;
        completed = i + 1;
        if (i % 5 == 0) {
          await progressFile.writeAsString((i + 1).toString());
        }

        final elapsed = DateTime.now().difference(startTime).inMilliseconds / 1000.0;
        final speed = elapsed > 0 ? (totalBytes / 1024 / 1024 / elapsed) : 0.0;
        final progress = completed / segmentUrls.length;
        final speedStr = '${speed.toStringAsFixed(2)} MB/s';
        NotificationService.showDownloadNotification(
          id: task.id.hashCode & 0x7fffffff,
          title: task.movieName,
          progress: (progress * 100).clamp(0, 100).toInt(),
          speed: speedStr,
        );
        onProgress(progress, speedStr);
      }
    } catch (e) {
      await raf.close();
      client.close();
      onStatusChange(my.DownloadStatus.error);
      await WakelockPlus.disable();
      await ForegroundService.stop();
      _hlsCancelFlags.remove(task.id);
      return;
    }

    await raf.close();
    client.close();
    _hlsCancelFlags.remove(task.id);

    if (completed != segmentUrls.length) {
      print('[HLS] incomplete download: $completed/${segmentUrls.length}');
      onStatusChange(my.DownloadStatus.error);
      await WakelockPlus.disable();
      await ForegroundService.stop();
      return;
    }

    if (totalBytes < 5 * 1024 * 1024) {
      print('[HLS] file too small after concat: ${totalBytes} bytes');
      onStatusChange(my.DownloadStatus.error);
      await WakelockPlus.disable();
      await ForegroundService.stop();
      return;
    }
    if (await progressFile.exists()) {
      await progressFile.delete();
    }

    // Actualizamos el task con la ruta del TS antes de intentar validar o convertir para no perder la referencia si algo falla
    await updateDownloadTask(task.copyWith(savePath: outputPath, originalFilename: fileName));

    final mediaOk = await _validateTsFile(outputPath);
    if (!mediaOk) {
      // Si el archivo existe y tiene tamaño, intentamos seguir aunque ffprobe no de duración exacta (puede pasar con TS crudos)
      final size = await outputFile.length();
      if (size < 5 * 1024 * 1024) {
        print('[HLS] invalid ts after concat (too small), forcing re-download');
        if (await outputFile.exists()) await outputFile.delete();
        onStatusChange(my.DownloadStatus.error);
        await WakelockPlus.disable();
        await ForegroundService.stop();
        return;
      }
      print('[HLS] TS file validation warned, but continuing due to file size');
    }

    onProgress(0.0, 'Convirtiendo...');
    final convertedPath = await _convertToMp4IfNeeded(outputPath, onProgress: (p, s) {
      onProgress(p, s);
    });
    
    // Si la conversión falla, mantenemos el TS para que al menos sea reproducible localmente
    final finalPath = convertedPath ?? outputPath;

    String pPath = finalPath;
    if (!AppConstants.secureSave && Platform.isAndroid) {
        try {
            print("[PUBLIC DL] Copiando HLS/MP4 convertido a carpeta pública K7-MOVIE...");
            final pubDir = Directory('/storage/emulated/0/Download/K7-MOVIE');
            if (!await pubDir.exists()) {
               await pubDir.create();
            }
            
            // Forzar extensión .mp4 para el archivo público
            String publicName = finalPath.split('/').last;
            if (publicName.toLowerCase().endsWith('.ts')) {
              publicName = publicName.substring(0, publicName.length - 3) + '.mp4';
            } else if (publicName.toLowerCase().endsWith('.m3u8')) {
              publicName = publicName.substring(0, publicName.length - 5) + '.mp4';
            } else if (!publicName.toLowerCase().endsWith('.mp4')) {
              publicName = '$publicName.mp4';
            }

            final publicFile = await File(finalPath).copy('${pubDir.path}/$publicName');
            pPath = publicFile.path;
            await File(finalPath).delete(); // Borramos el oculto
        } catch(e) {
            print("[PUBLIC DL] Error copiando HLS a público: $e");
        }
    }

    await updateDownloadTask(task.copyWith(
      savePath: pPath,
      originalFilename: pPath.split('/').last,
    ));
    await _updateTaskMediaInfo(task, pPath);
    NotificationService.showDownloadNotification(
      id: task.id.hashCode & 0x7fffffff,
      title: task.movieName,
      progress: 100,
      speed: '',
    );
    onProgress(1.0, '');
    onStatusChange(my.DownloadStatus.completed);
    await WakelockPlus.disable();
    await ForegroundService.stop();
  }

  List<String> _extractSegmentUrls(String playlistUrl, String playlistText) {
    final lines = playlistText.split('\n');
    final urls = <String>[];
    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
      urls.add(_resolveUrl(playlistUrl, trimmed));
    }
    return urls;
  }

  String _resolveUrl(String base, String ref) {
    try {
      final baseUri = Uri.parse(base);
      final refUri = Uri.parse(ref);
      if (refUri.hasScheme) return ref;
      
      // Fix: If ref starts with / and base is relative or we need to ensure host
      if (ref.startsWith('/') && !ref.startsWith('//')) {
        return Uri(
          scheme: baseUri.scheme,
          host: baseUri.host,
          port: baseUri.port,
          path: ref,
          query: refUri.hasQuery ? refUri.query : null,
        ).toString();
      }
      
      return baseUri.resolveUri(refUri).toString();
    } catch (_) {
      return ref;
    }
  }

  String _buildSafeFileBase(my.DownloadTask task) {
    return '${task.movieName.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_')}_${task.resolution.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_')}';
  }

  Future<String?> _updateTaskMediaInfo(my.DownloadTask task, String path) async {
    try {
      final file = File(path);
      if (!await file.exists()) return null;

      final size = await file.length();
      final sizeStr = _formatBytes(size);
      final infoSession = await FFprobeKit.getMediaInformation(path);
      final info = infoSession.getMediaInformation();
      int? width;
      int? height;
      if (info != null) {
        final streams = info.getStreams();
        if (streams != null) {
          for (final s in streams) {
            if (s.getType() == 'video') {
              final w = int.tryParse(s.getWidth()?.toString() ?? '');
              final h = int.tryParse(s.getHeight()?.toString() ?? '');
              if (w != null && h != null) {
                width = w;
                height = h;
                break;
              }
            }
          }
        }
      }

      String label;
      if (width != null && height != null) {
        label = '${width}x${height} • $sizeStr';
      } else {
        label = sizeStr;
      }

      await updateDownloadTask(task.copyWith(resolution: label, savePath: path));
      return label;
    } catch (e) {
      print('[MEDIA] info error: $e');
      return null;
    }
  }

  Future<bool> _validateTsFile(String path) async {
    try {
      final file = File(path);
      if (!await file.exists()) return false;
      final size = await file.length();
      if (size < 5 * 1024 * 1024) return false;

      final infoSession = await FFprobeKit.getMediaInformation(path);
      final info = infoSession.getMediaInformation();
      if (info == null) return false;
      final durationStr = info.getDuration();
      final seconds = durationStr != null ? double.tryParse(durationStr) : null;
      if (seconds == null || seconds <= 0) return false;
      final streams = info.getStreams();
      if (streams == null || streams.isEmpty) return false;
      return true;
    } catch (_) {
      return false;
    }
  }

  String _formatBytes(int bytes) {
    const kb = 1024;
    const mb = 1024 * 1024;
    const gb = 1024 * 1024 * 1024;
    if (bytes >= gb) return '${(bytes / gb).toStringAsFixed(2)} GB';
    if (bytes >= mb) return '${(bytes / mb).toStringAsFixed(2)} MB';
    if (bytes >= kb) return '${(bytes / kb).toStringAsFixed(1)} KB';
    return '$bytes B';
  }

  Future<String?> _findExistingFile(my.DownloadTask task) async {
    try {
      final directory = await getApplicationDocumentsDirectory();
      final downloadsDir = Directory('${directory.path}/downloads');
      if (!await downloadsDir.exists()) return null;

      final safeMovie = task.movieName.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_');
      final safeRes = task.resolution.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_');
      final baseSafe = '${safeMovie}_$safeRes';
      final baseRawRes = '${safeMovie}_${task.resolution}';

      final candidates = [
        File('${downloadsDir.path}/$baseSafe.mp4'),
        File('${downloadsDir.path}/$baseSafe.ts'),
        File('${downloadsDir.path}/$baseSafe.m3u8'),
        File('${downloadsDir.path}/$baseRawRes.mp4'),
        File('${downloadsDir.path}/$baseRawRes.ts'),
        File('${downloadsDir.path}/$baseRawRes.m3u8'),
      ];
      for (final f in candidates) {
        if (await f.exists()) return f.path;
      }

      // Fallback: scan directory for a file that starts with the sanitized movie name
      final files = await downloadsDir.list().toList();
      for (final entity in files) {
        if (entity is File) {
          final name = entity.path.split('/').last;
          if (name.startsWith(safeMovie) && (name.endsWith('.mp4') || name.endsWith('.ts'))) {
            return entity.path;
          }
        }
      }

      if (Platform.isAndroid && !AppConstants.secureSave) {
         final pubDir = Directory('/storage/emulated/0/Download/K7-MOVIE');
         if (await pubDir.exists()) {
           final pubCandidates = [
             File('${pubDir.path}/$baseSafe.mp4'),
             File('${pubDir.path}/$baseSafe.ts'),
             File('${pubDir.path}/$baseSafe.m3u8'),
             File('${pubDir.path}/$baseRawRes.mp4'),
             File('${pubDir.path}/$baseRawRes.ts'),
             File('${pubDir.path}/$baseRawRes.m3u8'),
           ];
           for (final f in pubCandidates) {
             if (await f.exists()) return f.path;
           }
           final pubFiles = await pubDir.list().toList();
           for (final entity in pubFiles) {
             if (entity is File) {
               final name = entity.path.split('/').last;
               if (name.startsWith(safeMovie) && (name.endsWith('.mp4') || name.endsWith('.ts'))) {
                 return entity.path;
               }
             }
           }
         }
      }
    } catch (e) {
      print('[PLAY] Resolve file error: $e');
    }
    return null;
  }

  Future<String?> _convertToMp4IfNeeded(
    String inputPath, {
    Function(double progress, String speed)? onProgress,
  }) async {
    if (inputPath.toLowerCase().endsWith('.mp4')) return inputPath;
    if (!inputPath.toLowerCase().endsWith('.ts')) return null;

    final inputFile = File(inputPath);
    if (!await inputFile.exists()) return null;

    final outputPath = inputPath.substring(0, inputPath.length - 3) + '.mp4';
    final tempOutputPath = '$outputPath.tmp';

    print('[CONVERSION] Start: $inputPath -> $outputPath');

    try {
      final temp = File(tempOutputPath);
      if (await temp.exists()) {
        await temp.delete();
      }
      final out = File(outputPath);
      if (await out.exists()) {
        await out.delete();
      }
    } catch (_) {}

    onProgress?.call(0.0, 'Convirtiendo...');

    final remuxCmd =
        '-y -i \"$inputPath\" -c copy -bsf:a aac_adtstoasc -movflags +faststart -f mp4 \"$tempOutputPath\"';
    final session = await FFmpegKit.execute(remuxCmd);
    final sessionId = session.getSessionId();
    final rc = await Future.any([
      session.getReturnCode(),
      Future.delayed(const Duration(seconds: 45), () async {
        await FFmpegKit.cancel(sessionId);
        return null;
      }),
    ]);
    if (rc == null) {
      print('[CONVERSION] Timeout: $inputPath');
      try {
        final tempFile = File(tempOutputPath);
        if (await tempFile.exists()) {
          await tempFile.delete();
        }
      } catch (_) {}
      NotificationService.showDownloadNotification(
        id: inputPath.hashCode & 0x7fffffff,
        title: 'Conversión fallida',
        progress: 0,
        speed: '',
      );
      return null;
    }
    if (ReturnCode.isSuccess(rc)) {
      final tempFile = File(tempOutputPath);
      if (await tempFile.exists()) {
        await tempFile.rename(outputPath);
      }
      if (await inputFile.exists()) {
        await inputFile.delete();
      }
      onProgress?.call(1.0, '');
      NotificationService.showDownloadNotification(
        id: inputPath.hashCode & 0x7fffffff,
        title: 'Conversión completada',
        progress: 100,
        speed: '',
      );
      return outputPath;
    }

    final logs = await session.getLogs();
    if (logs.isNotEmpty) {
      print('[CONVERSION] Error: ${logs.last.getMessage()}');
    }
    try {
      final tempFile = File(tempOutputPath);
      if (await tempFile.exists()) {
        await tempFile.delete();
      }
    } catch (_) {}

    NotificationService.showDownloadNotification(
      id: inputPath.hashCode & 0x7fffffff,
      title: 'Conversión fallida',
      progress: 0,
      speed: '',
    );
    print('[CONVERSION] Failed: $inputPath');
    return null;
  }


  Future<String?> _tryConvertToMp4(String hlsUrl, {Map<String, String>? headers}) async {
    try {
      print("[RECOVERY] Intentando encontrar versión MP4 para: $hlsUrl");
      
      final String baseUrl = hlsUrl.split('?').first;
      final String query = hlsUrl.contains('?') ? '?${hlsUrl.split('?').last}' : '';

      // Pattern 1: PeliculaPlay / Akamai patterns (EXTREMELY COMMON)
      if (hlsUrl.contains('peliculaplay.com') || hlsUrl.contains('media-limit')) {
         final variations = [
           baseUrl.replaceAll(RegExp(r'-microframe-(ld|sd|hd)\.m3u8$'), '.mp4'),
           baseUrl.replaceAll(RegExp(r'\.m3u8$'), '.mp4'),
           baseUrl.replaceAll(RegExp(r'/playlist\.m3u8$'), '/video.mp4'),
           baseUrl.replaceFirst('/hls/', '/').replaceAll('.m3u8', '.mp4'),
         ];
         
         for (var p in variations) {
            final full = p + query;
            if (await _probeUrl(full, headers: headers)) return full;
         }
      }

      // Pattern 2: Generic pirate servers (cloclo, vidsrc, etc)
      final genericVariations = [
        baseUrl.replaceAll('index.m3u8', 'video.mp4'),
        baseUrl.replaceAll('.m3u8', '.mp4'),
        baseUrl.replaceAll('/hls/', '/').replaceAll('.m3u8', '.mp4'),
      ];

      for (var p in genericVariations) {
        if (p == baseUrl) continue;
        final full = p + query;
        if (await _probeUrl(full, headers: headers)) return full;
      }
    } catch (e) {
      print("[RECOVERY] Error en búsqueda de MP4: $e");
    }
    return null;
  }

  Future<bool> _probeUrl(String url, {Map<String, String>? headers}) async {
    try {
      final response = await http.head(Uri.parse(url), headers: headers ?? {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36',
      }).timeout(const Duration(seconds: 3));
      
      if (response.statusCode == 200) {
        final cl = response.headers['content-length'];
        if (cl != null) {
          final size = int.tryParse(cl) ?? 0;
          // Must be at least 10MB to be a movie file
          return size > 10 * 1024 * 1024;
        }
        return true; 
      }
    } catch (_) {}
    return false;
  }

  void pauseDownload(String id) async {
    final db = await _sqliteService.database;
    final rows = await db.query('downloads', where: 'id = ?', whereArgs: [id]);
    if (rows.isNotEmpty) {
      final task = my.DownloadTask.fromMap(rows.first);
      if (task.videoUrl.contains('.m3u8') || (task.savePath?.endsWith('.ts') ?? false)) {
        _hlsCancelFlags[id] = true;
        return;
      }
    }

    final tasks = await FileDownloader().allTasks();
    final task = tasks.where((t) => t.taskId == id).firstOrNull as DownloadTask?;
    if (task != null) {
      await FileDownloader().pause(task);
    }
  }

  Future<void> resumeDownloadTask(
    my.DownloadTask task, {
    required Function(double, String) onProgress,
    required Function(my.DownloadStatus) onStatusChange,
  }) async {
    final isHls = task.videoUrl.contains('.m3u8') || (task.savePath?.endsWith('.ts') ?? false);
    if (isHls) {
      final headers = task.headers ?? {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36',
        'Referer': task.videoUrl.split('/').take(3).join('/'),
      };
      final fileName = _resolveHlsFileName(task);
      await updateDownloadTask(task.copyWith(status: my.DownloadStatus.downloading));
      _downloadHlsAsTs(
        task: task,
        fileName: fileName,
        headers: headers,
        onProgress: onProgress,
        onStatusChange: onStatusChange,
      );
      return;
    }

    final tasks = await FileDownloader().allTasks();
    final dlTask = tasks.where((t) => t.taskId == task.id).firstOrNull as DownloadTask?;
    if (dlTask != null) {
      await FileDownloader().resume(dlTask);
      return;
    }

    await enqueueDownload(task, onProgress: onProgress, onStatusChange: onStatusChange);
  }

  String _resolveHlsFileName(my.DownloadTask task) {
    if (task.savePath != null && task.savePath!.isNotEmpty) {
      return task.savePath!.split('/').last;
    }
    final base = _buildSafeFileBase(task);
    return '$base.ts';
  }

  void trackDownloads(Function(String, double, String, my.DownloadStatus, {String? savePath}) onUpdate) {
    FileDownloader().registerCallbacks(
      taskStatusCallback: (update) {
        final id = update.task.taskId;
        my.DownloadStatus myStatus;
        
        switch (update.status) {
          case TaskStatus.enqueued:
          case TaskStatus.running:
          case TaskStatus.waitingToRetry:
            myStatus = my.DownloadStatus.downloading;
            break;
          case TaskStatus.complete:
            // Check if the file is too small (likely not a movie)
            _verifyDownload(update.task).then((isValid) async {
              if (isValid) {
                myStatus = my.DownloadStatus.completed;
                _progressInfos.remove(id);
                
                String? finalPath;
                if (!AppConstants.secureSave && Platform.isAndroid) {
                    try {
                        print("[PUBLIC DL] Movie completing. Moving to Shared Storage...");
                        final sharedPath = await FileDownloader().moveToSharedStorage(
                            update.task as DownloadTask, 
                            SharedStorage.downloads, 
                            directory: 'K7-MOVIE'
                        );
                        finalPath = sharedPath ?? await _getFilePath(update.task);
                    } catch(e) {
                        print("[PUBLIC DL] Error moving to shared storage: $e");
                        finalPath = await _getFilePath(update.task);
                    }
                } else {
                    finalPath = await _getFilePath(update.task);
                }

                onUpdate(id, 1.0, "", myStatus, savePath: finalPath);
              } else {
                onUpdate(id, -1, "", my.DownloadStatus.error);
              }
            });
            return;
          case TaskStatus.failed:
          case TaskStatus.notFound:
            myStatus = my.DownloadStatus.error;
            _progressInfos.remove(id);
            break;
          case TaskStatus.paused:
            myStatus = my.DownloadStatus.paused;
            _progressInfos.remove(id);
            break;
          case TaskStatus.canceled:
            myStatus = my.DownloadStatus.pending;
            _progressInfos.remove(id);
            break;
        }
        onUpdate(id, -1, "", myStatus);
      },
      taskProgressCallback: (update) {
        final id = update.task.taskId;
        final now = DateTime.now();
        final info = _progressInfos[id] ?? _DownloadProgressInfo(lastUpdate: now, lastProgress: 0);
        
        String speedStr = "";
        if (update.progress > info.lastProgress) {
          final timeDiff = now.difference(info.lastUpdate).inMilliseconds / 1000.0;
          if (timeDiff > 0.5) { // Update speed every 0.5s
            // background_downloader doesn't provide file size in progress update easily
            // but we can estimate or use {networkSpeed} in notifications.
            // For the UI, we'll use the networkSpeed if available or just show progress
            speedStr = update.networkSpeedAsString;
            _progressInfos[id] = _DownloadProgressInfo(lastUpdate: now, lastProgress: update.progress);
          }
        }
        
        final percent = (update.progress * 100).clamp(0, 100).toInt();
        NotificationService.showDownloadNotification(
          id: id.hashCode & 0x7fffffff,
          title: update.task.displayName ?? 'Descargando',
          progress: percent,
          speed: speedStr,
        );
        onUpdate(id, update.progress, speedStr, my.DownloadStatus.downloading);
      },
      taskNotificationTapCallback: (task, action) {
        // Optional: handle tap
      },
    );
  }

  Future<String?> _getFilePath(Task task) async {
    if (task is DownloadTask) {
       return await task.filePath();
    }
    return null;
  }

  Future<bool> _verifyDownload(Task task) async {
    try {
      if (task is DownloadTask) {
        final path = await task.filePath();
        final file = File(path);
        if (await file.exists()) {
          final size = await file.length();
          // If less than 1MB, it's definitely not a movie (likely an error page or m3u8 playlist)
          if (size < 1024 * 1024) {
            print("Download verification failed: File size too small (${size} bytes).");
            return false;
          }
          return true;
        }
      }
    } catch (e) {
      print("Verification error: $e");
    }
    return false;
  }
}

final downloadRepositoryProvider = Provider<DownloadRepository>((ref) {
  final sqliteService = ref.watch(sqliteServiceProvider);
  return DownloadRepository(sqliteService);
});

final downloadsListProvider = StateNotifierProvider<DownloadsListNotifier, List<my.DownloadTask>>((ref) {
  return DownloadsListNotifier(ref.watch(downloadRepositoryProvider));
});

class DownloadsListNotifier extends StateNotifier<List<my.DownloadTask>> {
  final DownloadRepository _repository;

  DownloadsListNotifier(this._repository) : super([]) {
    _loadDownloads();
    _repository.trackDownloads((id, progress, speed, status, {savePath}) {
      _updateLocalTask(id, progress, speed, status, savePath: savePath);
    });
  }

  Future<void> _loadDownloads() async {
    state = await _repository.getDownloads();
  }

  void _updateLocalTask(
    String id,
    double progress,
    String speed,
    my.DownloadStatus status, {
    String? savePath,
  }) async {
    final index = state.indexWhere((t) => t.id == id);
    if (index == -1) return;

    final t = state[index];
    final updated = t.copyWith(
      progress: progress >= 0 ? progress : t.progress,
      speed: speed.isNotEmpty ? speed : t.speed,
      status: status,
      savePath: savePath ?? t.savePath,
    );

    state = [
      for (final item in state)
        if (item.id == id) updated else item
    ];

    if (updated.status != t.status || (progress >= 0 && (progress * 100).toInt() % 10 == 0) || savePath != null) {
       _repository.updateDownloadTask(updated);
    }

    if (updated.status == my.DownloadStatus.completed || savePath != null) {
      _refreshTaskFromDb(id);
    }
  }

  Future<void> _refreshTaskFromDb(String id) async {
    final dbTask = await _repository.getDownloadById(id);
    if (dbTask == null) return;
    final index = state.indexWhere((t) => t.id == id);
    if (index == -1) return;
    final current = state[index];
    final merged = current.copyWith(
      resolution: dbTask.resolution,
      savePath: dbTask.savePath ?? current.savePath,
    );
    state = [
      for (final item in state)
        if (item.id == id) merged else item
    ];
  }

  Future<void> addDownload(my.DownloadTask task) async {
    await _repository.saveDownloadTask(task);
    await _loadDownloads();
    _repository.enqueueDownload(task, 
      onProgress: (p, s) => _updateLocalTask(task.id, p, s, my.DownloadStatus.downloading),
      onStatusChange: (s) => _updateLocalTask(task.id, -1, "", s)
    );
  }

  Future<void> resumeDownload(String id) async {
    my.DownloadTask? task;
    for (final t in state) {
      if (t.id == id) {
        task = t;
        break;
      }
    }
    if (task == null) return;
    _updateLocalTask(task!.id, task!.progress, task!.speed ?? '', my.DownloadStatus.downloading);
    await _repository.resumeDownloadTask(
      task!,
      onProgress: (p, s) => _updateLocalTask(task!.id, p, s, my.DownloadStatus.downloading),
      onStatusChange: (s) => _updateLocalTask(task!.id, -1, "", s),
    );
  }

  void pauseDownload(String id) {
    _repository.pauseDownload(id);
  }

  Future<void> deleteDownload(String id) async {
    await _repository.deleteDownloadTask(id);
    await _loadDownloads();
  }

  Future<void> clearFailedDownloads() async {
    await _repository.deleteFailedDownloads();
    await _loadDownloads();
  }

  Future<String?> ensurePlayableFile(String id) async {
    my.DownloadTask? task;
    for (final t in state) {
      if (t.id == id) {
        task = t;
        break;
      }
    }
    if (task == null) return null;

    _updateLocalTask(task!.id, 0.0, 'Convirtiendo...', my.DownloadStatus.downloading);

    final path = await _repository.ensurePlayableFile(
      task!,
      onProgress: (p, s) => _updateLocalTask(task!.id, p, s, my.DownloadStatus.downloading),
    );
    if (path != null) {
      _updateLocalTask(task!.id, 1.0, '', my.DownloadStatus.completed, savePath: path);
    } else {
      _updateLocalTask(task!.id, task!.progress, task!.speed ?? '', my.DownloadStatus.error);
    }
    return path;
  }
}

class _DownloadProgressInfo {
  final DateTime lastUpdate;
  final double lastProgress;
  _DownloadProgressInfo({required this.lastUpdate, required this.lastProgress});
}
