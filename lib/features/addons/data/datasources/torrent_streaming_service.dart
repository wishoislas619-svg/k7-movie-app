import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:libtorrent_flutter/libtorrent_flutter.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

/// Resultado de iniciar la reproducción de un torrent vía libtorrent.
class TorrentPlaybackSession {
  final int torrentId;
  final int streamId;
  final String localPath;
  final String name;

  const TorrentPlaybackSession({
    required this.torrentId,
    required this.streamId,
    required this.localPath,
    required this.name,
  });
}

/// Resultado de `startStreaming`: la sesión de reproducción (URL HTTP del
/// stream) más el progreso de descarga CONTINUO del torrent que sigue bajándose
/// en segundo plano hasta el 100% mientras se reproduce.
class TorrentStreamingHandle {
  final TorrentPlaybackSession session;
  /// Notificador de progreso que sigue actualizándose en segundo plano hasta
  /// que [done] se complete (descarga del torrent al 100%).
  final ValueNotifier<TorrentDownloadProgress> progress;
  /// Se completa cuando el torrent termina de descargarse (100%).
  final Future<void> done;
  /// InfoHash + fileIdx reales del torrent reproducido (se persisten en el
  /// historial para que "Continuar viendo" reanude el MISMO torrent).
  final String? infoHash;
  final int? fileIdx;

  const TorrentStreamingHandle({
    required this.session,
    required this.progress,
    required this.done,
    this.infoHash,
    this.fileIdx,
  });
}

/// Datos de progreso emitidos durante la descarga completa.
class TorrentDownloadProgress {
  final double percent;
  final double downloadedMB;
  final double totalMB;
  final double speedMBps;
  final int peers;
  final int seeds;
  final String state;
  final bool finished;

  const TorrentDownloadProgress({
    required this.percent,
    required this.downloadedMB,
    required this.totalMB,
    required this.speedMBps,
    required this.peers,
    required this.seeds,
    required this.state,
    required this.finished,
  });
}

/// Abstracción sobre `libtorrent_flutter` para reproducir torrents sin debrid
/// mediante **streaming HTTP on-demand** (modelo TorrServer/Stremio).
///
/// `start()` arranca el servidor HTTP interno nativo (`startStream`) sobre el
/// archivo objetivo y devuelve su URL (`http://127.0.0.1:PORT/stream/...`). El
/// servidor (port de lt2http) sirve los bytes exactos que pide el reproductor:
/// ante un rango, sube la prioridad de las piezas que faltan, espera a que
/// lleguen y responde 206. media_kit reproduce la URL directamente. Esto evita
/// el salto-al-final de los .mkv esparciosos (el índex vive al final del
/// archivo), permite seek y usa descarga en paralelo rarest-first.
class TorrentStreamingService {
  TorrentStreamingService._();
  static final TorrentStreamingService instance = TorrentStreamingService._();

  bool _initStarted = false;
  bool _initDone = false;
  Completer<void>? _initCompleter;
  String? _saveDir;

  // Torrents vivos registrados en el servicio (para el keepalive multi-torrent).
  final Set<int> _managedTorrentIds = {};
  final Map<String, int> _infohashToTorrentId = {};

  Future<String> _defaultSaveDir() async {
    final base = await getTemporaryDirectory();
    final dir = Directory(p.join(base.path, 'torrents'));
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir.path;
  }

  /// Subdirectorio POR INFOHASH dentro de `torrents/`, para que las descargas
  /// simultáneas (p.ej. historial + cast) no se borren los archivos entre sí.
  /// Eliminar el `saveDir` global rompía el torrent que seguía activo en el
  /// engine (errores `file_open ... No such file or directory` + torrent pausado).
  String _saveDirFor(String infoHash) {
    final dir = Directory(p.join(_saveDir!, infoHash.toLowerCase()));
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir.path;
  }

  Future<void> _ensureInit() async {
    if (_initDone) return;
    if (_initStarted) {
      await _initCompleter!.future;
      return;
    }
    _initStarted = true;
    _initCompleter = Completer<void>();
    try {
      _saveDir = await _defaultSaveDir();
      await LibtorrentFlutter.init(fetchTrackers: true);
      final engine = LibtorrentFlutter.instance;
      // Configuración agresiva estilo Stremio/stream-server para conectar bien
      // con el swarm y obtener metadatos de forma fiable.
      engine.configureSession(
        engine.getDefaultConfig().copyWith(
              cacheSize: 256 * 1024 * 1024,
              readerReadAhead: 95,
              preloadCache: 50,
              connectionsLimit: 200,
              torrentDisconnectTimeout: 60,
              forceEncrypt: false,
              disableTcp: false,
              disableUtp: false,
              disableUpload: false,
              disableDht: false,
              disableUpnp: false,
              enableIpv6: true,
              downloadRateLimit: 0,
              uploadRateLimit: 0,
              peersListenPort: 6881,
              responsiveMode: true,
            ),
      );
      _initDone = true;
      _initCompleter!.complete();
    } catch (e) {
      _initStarted = false;
      _initCompleter!.completeError(e);
      _initCompleter = null;
      rethrow;
    }
  }

  static const List<String> _publicTrackers = [
    'udp://tracker.opentrackr.org:1337/announce',
    'udp://open.tracker.cl:1337/announce',
    'udp://open.demonii.com:1337/announce',
    'udp://tracker.openbittorrent.com:6969/announce',
    'udp://exodus.desync.com:6969/announce',
    'udp://tracker.torrent.eu.org:451/announce',
    'udp://explodie.org:6969/announce',
    'udp://open.stealth.si:80/announce',
    'udp://tracker.zer0day.to:1337/announce',
    'http://tracker.opentrackr.org:1337/announce',
    'https://tracker.nanoha.org:443/announce',
  ];

  // Incrustamos trackers públicos directamente en el magnet para no depender
  // sólo de DHT / trackers auto-bajados, mejorando la obtención de metadatos.
  String _magnet(String infoHash) {
    final trackers =
        _publicTrackers.map((t) => '&tr=${Uri.encodeQueryComponent(t)}').join();
    return 'magnet:?xt=urn:btih:$infoHash$trackers';
  }

  /// Inicia la reproducción de un torrent con el modelo tipo Stremio:
  /// descarga SECUENCIAL en orden (piezas 0,1,2,...) a través del servidor
  /// HTTP interno nativo (`http://127.0.0.1:PORT/stream/...`), y devuelve la
  /// sesión cuando ya hay un buffer contiguo de [preloadBytes] descargado
  /// (por defecto 50MB) "por delante". Así media_kit/ExoPlayer arranca con
  /// datos suficientes y el seek dentro de lo descargado no salta.
  ///
  /// Al hacer seek adelantado a una zona aún no descargada, el servidor nativo
  /// re-ancla la descarga y sigue en orden desde esa posición.
  ///
  /// [bufferTimeout] es el tiempo máximo que esperamos a alcanzar el umbral de
  /// preload antes de devolver la URL (si no se alcanza, se devuelve igualmente
  /// con lo descargado para no bloquear la reproducción).
  Future<TorrentPlaybackSession> start({
    required String infoHash,
    int? fileIndex,
    int preloadBytes = 50 * 1024 * 1024,
    Duration metadataTimeout = const Duration(seconds: 120),
    Duration bufferTimeout = const Duration(seconds: 120),
  }) async {
    print('TORRENT_DBG: start() infohash=$infoHash fileIdx=$fileIndex preloadBytes=$preloadBytes');
    await _ensureInit();
    final engine = LibtorrentFlutter.instance;
    final saveDir = _saveDirFor(infoHash);
    print('TORRENT_DBG: saveDir=$saveDir');

    final magnet = _magnet(infoHash);
    // streamOnly = false → el torrent se descarga a disco (archivos reales).
    // Este es el punto clave: libtorrent escribe las piezas en un archivo real
    // en saveDir, NO dependemos del servidor HTTP interno.
    final torrentId = engine.addMagnet(magnet, saveDir, false);
    print('TORRENT_DBG: addMagnet returned torrentId=$torrentId');

    try {
      final files = await _waitForMetadata(engine, torrentId, timeout: metadataTimeout);
      print('TORRENT_DBG: _waitForMetadata returned ${files.length} files');
      _logFileList(files);
      if (files.isEmpty) {
        engine.disposeTorrent(torrentId);
        throw Exception('Torrent sin archivos reproducibles.');
      }
      final target = _pickFileIndex(files, fileIndex);
      final targetFile = target >= 0 && target < files.length ? files[target] : null;
      print('TORRENT_DBG: ▶ TARGET FILE seleccionado: fileIndex=$target '
          '${targetFile != null ? '| name=${targetFile.name} size=${targetFile.size}B' : '(out of range)'} '
          '(solicitado=$fileIndex)');

      // Ruta real en disco (sólo como fallback si startStream no devuelve URL).
      final relPath = (targetFile?.path ?? '')
          .replaceAll('\\', '/')
          .split('/')
          .where((s) => s.isNotEmpty && s != '.' && s != '..')
          .join('/');
      final localPath = p.join(saveDir, relPath);

      // Prioridades de archivo: SOLO el archivo objetivo se habilita (nonzero),
      // el resto se marca 0 (dont_download) para no desperdiciar ancho de banda
      // en muestras/avisos. La prioridad de archivo multiplica la prioridad por
      // pieza que fija startStream, así que los ficheros no objetivo quedan a 0.
      if (target >= 0 && target < files.length) {
        final priorities = List<int>.filled(files.length, 0);
        priorities[target] = 1;
        engine.setFilePriorities(torrentId, priorities);
        print('TORRENT_DBG: setFilePriorities target=$target (others=0/skip)');
      }

      // startStream: arranca el servidor HTTP interno nativo (port de
      // lt2http/TorrServer). El servidor sirve el archivo, y su read thread
      // descarga de forma SECUENCIAL en orden (piezas 0,1,2,...) con pipeline,
      // priorizando la pieza actual + las siguientes (ver serve_range). Así el
      // archivo virtual se "rellena" en orden y la reproducción vía
      // http://127.0.0.1:PORT/stream/... no salta al final (los cues del .mkv
      // ya no son un problema porque se sirve por HTTP con Content-Range).
      var streamId = 0;
      String url = '';
      if (target >= 0 && target < files.length) {
        final stream = engine.startStream(torrentId, fileIndex: target);
        streamId = stream.id;
        url = stream.url;
        print('TORRENT_DBG: startStream(secuencial) id=$streamId torrentId=$torrentId'
            ' targetFile=$target url=$url');
      } else {
        engine.resumeTorrent(torrentId);
        print('TORRENT_DBG: resumeTorrent fallback torrentId=$torrentId');
      }

      // Modelo Stremio: esperamos a tener pre-descargado un buffer contiguo
      // (~50MB "por delante") pidiendo rangos progresivos al servidor HTTP.
      // Esto alimenta serve_range (que descarga en orden) y garantiza que el
      // reproductor arranque con margen antes de que la descarga le alcance.
      // OJO: si el archivo objetivo es MÁS PEQUEÑO que preloadBytes (p.ej. este
      // torrent tiene 86 ficheros pequeños), pedir `bytes=0-50MB` pediría más
      // allá del EOF y nunca se "alcanzaría" el umbral. Limitamos el target al
      // tamaño real del archivo cuando lo conocemos (double con lt_get_files).
      if (url.isNotEmpty) {
        final realSize = (targetFile?.size ?? 0) > 0 ? targetFile!.size : preloadBytes;
        final effectivePreload = (preloadBytes > 0 && realSize > 0)
            ? (preloadBytes < realSize ? preloadBytes : realSize)
            : preloadBytes;
        print('TORRENT_DBG: preload target efectivo=${effectivePreload}B '
            '(preloadBytes=$preloadBytes fileSize=$realSize)');
        await _waitForStreamStart(engine, torrentId, streamId,
            url: url,
            preloadBytes: effectivePreload,
            fileSize: realSize,
            timeout: bufferTimeout);
      }
      _startKeepAlive(engine, torrentId);

      final playbackUrl = url.isNotEmpty ? url : 'file://$localPath';
      print('TORRENT_DBG: reproduciendo vía streaming HTTP secuencial url=$playbackUrl');
      final session = TorrentPlaybackSession(
        torrentId: torrentId,
        streamId: streamId,
        localPath: playbackUrl,
        name: playbackUrl,
      );
      return session;
    } catch (_) {
      print('TORRENT_DBG: start() threw, disposing torrentId=$torrentId');
      engine.disposeTorrent(torrentId);
      rethrow;
    }
  }

  /// ══════════════════════════════════════════════════════════════════════
  /// STREAMING CON DESCARGA COMPLETA ANTES DE REPRODUCIR
  ///
  /// Añade el torrent y lo descarga COMPLETO a disco (TODOS los archivos con
  /// prioridad 7, "todo el torrent a la vez") hasta el 100%, emitiendo progreso
  /// continuo (% + velocidad + peers/seeds) vía [progress] al diálogo, y SOLO
  /// entonces devuelve el handle para reproducir el `file://` íntegro.
  ///
  /// Motivo: media_kit/mpv NO abre un archivo parcial (aunque la cabeza ya tenga
  /// datos reales, initialize() colgaba 25s). Esperando al 100% el archivo en
  /// disco queda completo y el reproductor lo abre sin colgarse, y el seek queda
  /// habilitado de inmediato (ya no hace falta bloquearlo).
  /// ══════════════════════════════════════════════════════════════════════
  Future<TorrentStreamingHandle> startStreaming({
    required String infoHash,
    int? fileIndex,
    Duration metadataTimeout = const Duration(seconds: 120),
    Duration minDownloadWait = const Duration(minutes: 12),
    int startPercent = 10,
    int preloadBytes = 50 * 1024 * 1024,
    int? knownSizeBytes,
    ValueNotifier<TorrentDownloadProgress?>? progressToReport,
  }) async {
    print('TORRENT_DBG: startStreaming() infohash=$infoHash fileIdx=$fileIndex '
        'startPercent=$startPercent%');
    await _ensureInit();
    final engine = LibtorrentFlutter.instance;
    final saveDir = _saveDirFor(infoHash);

    // Limpia SOLO el subdirectorio de ESTE infohash (nunca el global): un
    // `startStreaming` no debe romper los archivos de otro torrent en curso.
    try {
      final dir = Directory(saveDir);
      if (dir.existsSync()) {
        dir.deleteSync(recursive: true);
        dir.createSync(recursive: true);
        print('TORRENT_DBG: startStreaming limpieza subdir infohash='
            '${infoHash.toLowerCase()} OK');
      }
    } catch (_) {}

    // Si el mismo infohash ya está gestionado (sesión previa que no se cerró),
    // lo liberamos primero para no dejar dos torrents del mismo magnet en el
    // engine (origen de descargas clavadas al 0% con isPaused=true).
    final existing = _infohashToTorrentId[infoHash.toLowerCase()];
    if (existing != null) {
      print('TORRENT_DBG: startStreaming detecta torrent previo '
          'del MISMO infohash (id=$existing), liberándolo');
      try { engine.disposeTorrent(existing); } catch (_) {}
      _managedTorrentIds.remove(existing);
      _infohashToTorrentId.remove(infoHash.toLowerCase());
      _stopKeepAliveFor(existing);
    }

    final magnet = _magnet(infoHash);
    final torrentId = engine.addMagnet(magnet, saveDir, false);
    _infohashToTorrentId[infoHash.toLowerCase()] = torrentId;
    print('TORRENT_DBG: startStreaming addMagnet(id=$torrentId) OK');

    final progress = ValueNotifier(TorrentDownloadProgress(
      percent: 0,
      downloadedMB: 0,
      totalMB: 0,
      speedMBps: 0,
      peers: 0,
      seeds: 0,
      state: 'starting',
      finished: false,
    ));
    final done = Completer<void>();
    late StreamSubscription<(int, String)> alertSub;

    try {
      final files = await _waitForMetadata(engine, torrentId, timeout: metadataTimeout);
      if (files.isEmpty) {
        throw Exception('Torrent sin archivos reproducibles.');
      }
      _logFileList(files);

      final target = _pickFileIndex(files, fileIndex);
      final targetFile = target >= 0 && target < files.length ? files[target] : null;
      print('TORRENT_DBG: ▶ TARGET FILE: fileIndex=$target '
          '${targetFile != null ? '| name=${targetFile.name} size=${targetFile.size}B' : '(out of range)'}');

      // ⚠️ IMPORTANTE: descargamos TODO el torrent a disco con prioridad 7 en
      // TODOS los archivos, igual que el commit 6c3512e. Así los alerts nativos
      // "piece: N finished" cubren el torrent COMPLETO y el % se mide contra el
      // torrent entero (downloadedPieces.length / (maxPieceSeen+1)), no contra
      // una sola pieza ni el tamaño de Torrentio. NO usamos `startStream` porque
      // re-prioritiza/secuencia solo el archivo objetivo: dispara
      // "torrent finished" de forma prematura (rompe el % y el bloqueo de seek)
      // y sirve piezas dispersas (origen del SIGSEGV). Reproducimos `file://`
      // (lo que ya hay en disco) cuando la descarga llega a startPercent% y el
      // archivo objetivo ya tiene bytes en disco, y seguimos bajando a 100% en
      // 2º plano (el player bloquea el seek y muestra el % hasta que `done`).
      final priorities = List<int>.filled(files.length, 7);
      engine.setFilePriorities(torrentId, priorities);
      engine.resumeTorrent(torrentId);
      print('TORRENT_DBG: setFilePriorities TODOS=7 + resume (descarga de todo el torrent, % contra el torrent completo)');

      final relPath = (targetFile?.path ?? '')
          .replaceAll('\\', '/')
          .split('/')
          .where((s) => s.isNotEmpty && s != '.' && s != '..')
          .join('/');
      final localPath = p.join(saveDir, relPath);
      final fileUrl = 'file://$localPath';
      // La reproducción lee el archivo LOCAL en disco, sin servidor HTTP.
      const int streamId = 0;

      _startKeepAlive(engine, torrentId);

      // ── Rastreo nativo de piezas (la señal 100% fiable) ──
      int maxPieceSeen = -1;
      int bestTotalWanted = 0;
      final Set<int> downloadedPieces = {};
      // Alerts nativos: piezas terminadas + final del torrent.
      bool alertFinished = false;
      final StreamSubscription<(int, String)> alertsTrack =
          LibtorrentFlutter.alertStream.listen((e) {
        if (e.$1 != torrentId) return;
        final piece = _parsePieceFinished(e.$2);
        if (piece != null) {
          downloadedPieces.add(piece);
          if (piece > maxPieceSeen) maxPieceSeen = piece;
        } else if (e.$2.contains('torrent finished downloading') ||
            e.$2.contains('state changed to: finished') ||
            e.$2.contains('state changed to: seeding')) {
          alertFinished = true;
          if (!done.isCompleted && e.$2.contains('torrent finished')) {
            done.complete();
          }
        }
      }, onError: (_) {});
      alertSub = alertsTrack;

      // Tamaño total conocido del torrent (base para MB mostrados).
      int totalMB = 0;
      if (bestTotalWanted > 0) {
        totalMB = bestTotalWanted ~/ 1048576;
      } else if (knownSizeBytes != null && knownSizeBytes > 0) {
        totalMB = knownSizeBytes ~/ 1048576;
      }

      final started = DateTime.now();
      double lastEmittedPct = -1;
      double pct = 0;
      int nativeTotalPieces = 0;
      double lastDoneMB = 0;
      DateTime? lastSampleTime;

      // ── Espera inicial: descarga de TODO el torrent hasta el 100% ──
      // El usuario decidió esperar a que la descarga COMPLETA termine (100%)
      // antes de devolver la sesión, porque media_kit/mpv NO abre un archivo
      // `file://` parcial (aunque la cabeza ya tenga datos reales, colgaba 25s).
      // Mientras se descarga emitimos % + velocidad + peers/seeds al diálogo.
      while (DateTime.now().difference(started) < minDownloadWait) {
        // Convergencia del denominador nativo.
        final ti = engine.torrents[torrentId];
        if (ti != null) {
          if (ti.totalWanted > bestTotalWanted) {
            bestTotalWanted = ti.totalWanted;
          }
          if (bestTotalWanted > 0 && totalMB == 0) totalMB = bestTotalWanted ~/ 1048576;
        }
        // Denominador = piezas contiguas vistas (máx pieza + 1) porque el bridge
        // Android no reporta numPieces/totalWanted de forma fiable.
        if (maxPieceSeen >= 0) nativeTotalPieces = maxPieceSeen + 1;
        final nativeDonePieces = downloadedPieces.length;
        if (nativeTotalPieces > 0) {
          pct = 100.0 * nativeDonePieces / nativeTotalPieces;
        } else if (bestTotalWanted > 0) {
          pct = 100.0 * (ti?.totalDone ?? 0) / bestTotalWanted;
        }

        final doneMB = totalMB > 0 ? pct / 100.0 * totalMB : nativeDonePieces.toDouble();

        // Velocidad real calculada en Dart (delta de MB descargados entre
        // muestras), porque downloadRate del bridge suele reportar 0.
        final nowSample = DateTime.now();
        double speedMBps = (ti?.downloadRate ?? 0) / 1048576.0;
        if (lastSampleTime != null) {
          final elapsedSec = nowSample.difference(lastSampleTime)
              .inMicroseconds / 1000000.0;
          if (elapsedSec > 0.1) {
            final deltaMB = (doneMB - lastDoneMB).clamp(-999.0, 999.0);
            speedMBps = deltaMB > 0.001 ? deltaMB / elapsedSec : speedMBps;
          }
        }
        lastDoneMB = doneMB;
        lastSampleTime = nowSample;

        if (pct - lastEmittedPct >= 0.5 || (alertFinished && pct >= 100)) {
          lastEmittedPct = pct;
          final report = TorrentDownloadProgress(
            percent: pct.clamp(0, 100),
            downloadedMB: doneMB,
            totalMB: totalMB.toDouble(),
            speedMBps: speedMBps,
            peers: ti?.numPeers ?? 0,
            seeds: ti?.numSeeds ?? 0,
            state: 'downloading',
            finished: false,
          );
          progress.value = report;
          progressToReport?.value = report;
        }

        print('TORRENT_DBG: [espera 100%] ${pct.toStringAsFixed(1)}% '
            '${doneMB.toStringAsFixed(1)}/${totalMB.toStringAsFixed(1)}MB '
            'rate=${speedMBps.toStringAsFixed(2)}MB/s '
            'peers=${ti?.numPeers ?? 0} seeds=${ti?.numSeeds ?? 0} '
            'pieces=${nativeDonePieces}/$nativeTotalPieces '
            'alertFinished=$alertFinished');

        // ⏭ COMPLETADO: cuando todo el torrent está en disco (100%) salimos y
        // devolvemos la sesión; el archivo está COMPLETO, así que media_kit/mpv
        // podrá abrir el `file://` sin colgarse.
        if (alertFinished || (nativeTotalPieces > 0 && nativeDonePieces >= nativeTotalPieces)) {
          final finished = TorrentDownloadProgress(
            percent: 100,
            downloadedMB: totalMB.toDouble(),
            totalMB: totalMB.toDouble(),
            speedMBps: 0,
            peers: ti?.numPeers ?? 0,
            seeds: ti?.numSeeds ?? 0,
            state: 'finished',
            finished: true,
          );
          progress.value = finished;
          progressToReport?.value = finished;
          if (!done.isCompleted) done.complete();
          print('TORRENT_DBG: ▶ descarga COMPLETA al 100% → devolviendo sesión '
              'file:// (${totalMB.toStringAsFixed(1)}MB en disco)');
          break;
        }

        await Future.delayed(const Duration(seconds: 1));
      }
      alertSub.cancel();

      // Si salimos del loop por timeout SIN llegar al 100%, tiramos del estado
      // capturado del 2º plano para conservar el progreso, pero devolvemos una
      // sesión cuyo archivo puede estar incompleto. Para que media_kit pueda
      // abrirlo, seguimos esperando en 2º plano hasta el 100% antes de que el
      // player lance el initialize() sobre `file://`.
      final playbackUrl = fileUrl;
      final session = TorrentPlaybackSession(
        torrentId: torrentId,
        streamId: streamId,
        localPath: playbackUrl,
        name: playbackUrl,
      );

      if (pct < 100) {
        print('TORRENT_DBG: ⏳ timeout antes del 100% (${pct.toStringAsFixed(1)}%) '
            '— la descarga sigue en 2º plano; esperamos al 100% antes de arrancar el player');
        final _ = _backgroundDownload(engine, torrentId, downloadedPieces,
            maxPieceSeen, bestTotalWanted, alertFinished, done, progress, totalMB);
        // El usuario quiere esperar a la descarga COMPLETA para que el archivo
        // `file://` se pueda abrir. Mantenemos el diálogo (con % + velocidad)
        // hasta que `done` se complete (100%), y solo entonces devolvemos la
        // sesión para iniciar la reproducción sobre un archivo íntegro.
        await done.future;
        progress.value = TorrentDownloadProgress(
          percent: 100,
          downloadedMB: totalMB.toDouble(),
          totalMB: totalMB.toDouble(),
          speedMBps: 0,
          peers: 0,
          seeds: 0,
          state: 'finished',
          finished: true,
        );
        progressToReport?.value = progress.value;
      }
      print('TORRENT_DBG: startStreaming devolviendo sesión url=$playbackUrl '
          'pct=100% (archivo completo en disco)');

      return TorrentStreamingHandle(
        session: session,
        progress: progress,
        done: done.future,
        infoHash: infoHash,
        fileIdx: target,
      );
    } catch (e) {
      print('TORRENT_DBG: startStreaming threw, disposing torrentId=$torrentId err=$e');
      _stopKeepAliveFor(torrentId);
      _managedTorrentIds.remove(torrentId);
      _infohashToTorrentId.remove(infoHash.toLowerCase());
      try { alertSub.cancel(); } catch (_) {}
      try { done.completeError(e); } catch (_) {}
      engine.disposeTorrent(torrentId);
      rethrow;
    }
  }

  /// Descarga en 2º plano del torrent hasta el 100% tras haber devuelto la
  /// sesión para reproducir desde disco. Recibe el estado nativo capturado en
  /// `startStreaming` para no perder piezas entre el corte del loop principal
  /// y este. Notifica progreso por `progress` y completa `done` al terminar.
  Future<void> _backgroundDownload(
    LibtorrentFlutter engine,
    int torrentId,
    Set<int> downloadedPieces,
    int maxPieceSeen,
    int bestTotalWanted,
    bool alertFinished,
    Completer<void> done,
    ValueNotifier<TorrentDownloadProgress> progress,
    int totalMB,
  ) async {
    int localMaxPiece = maxPieceSeen;
    int localBest = bestTotalWanted;
    final localPieces = Set<int>.from(downloadedPieces);
    bool finishedTracking = alertFinished;
    final StreamSubscription<(int, String)> bgAlerts =
        LibtorrentFlutter.alertStream.listen((e) {
      if (e.$1 != torrentId) return;
      final piece = _parsePieceFinished(e.$2);
      if (piece != null) {
        localPieces.add(piece);
        if (piece > localMaxPiece) localMaxPiece = piece;
      } else if (e.$2.contains('torrent finished downloading') ||
          e.$2.contains('state changed to: finished') ||
          e.$2.contains('state changed to: seeding')) {
        finishedTracking = true;
      }
    }, onError: (_) {});
    try {
      while (!finishedTracking) {
        final ti = engine.torrents[torrentId];
        if (ti != null) {
          if (ti.totalWanted > localBest) localBest = ti.totalWanted;
        }
        final totalN = localMaxPiece >= 0 ? localMaxPiece + 1 : 0;
        final p = totalN > 0
            ? (100.0 * localPieces.length / totalN).clamp(0.0, 100.0).toDouble()
            : 0.0;
        final mb = totalMB > 0 ? p / 100.0 * totalMB : localPieces.length.toDouble();
        progress.value = TorrentDownloadProgress(
          percent: p,
          downloadedMB: mb,
          totalMB: totalMB.toDouble(),
          speedMBps: (ti?.downloadRate ?? 0) / 1048576.0,
          peers: ti?.numPeers ?? 0,
          seeds: ti?.numSeeds ?? 0,
          state: 'downloading',
          finished: false,
        );
        if (finishedTracking || (totalN > 0 && localPieces.length >= totalN)) {
          progress.value = TorrentDownloadProgress(
            percent: 100,
            downloadedMB: totalMB.toDouble(),
            totalMB: totalMB.toDouble(),
            speedMBps: 0,
            peers: ti?.numPeers ?? 0,
            seeds: ti?.numSeeds ?? 0,
            state: 'finished',
            finished: true,
          );
          if (!done.isCompleted) done.complete();
          break;
        }
        await Future.delayed(const Duration(seconds: 1));
      }
    } finally {
      await bgAlerts.cancel();
      if (!done.isCompleted) done.complete();
    }
  }

  /// ══════════════════════════════════════════════════════════════════════
  /// MODO DESCARGA COMPLETA (MÁXIMA VELOCIDAD)
  ///
  /// El usuario decidió abandonar el proxy HTTP + buffer incremental (que
  /// nunca llegó a servir bytes de forma fiable). Este método descarga **el
  /// archivo completo del torrent a disco usando todo el ancho de banda
  /// disponible en paralelo** y devuelve la ruta `file://` para reproducirla
  /// con media_kit/ExoPlayer como si fuera un archivo local. Al estar el
  /// fichero completo en disco, el seek NUNCA salta ni se queda colgado.
  ///
  /// Por qué es lo más rápido posible (sin código nativo extra):
  ///  - `addMagnet(..., streamOnly: false)` NO activa stop_when_ready ni
  ///    sequential_download: libtorrent descarga con el picker **rarest-first**
  ///    y con **paralelización de bloques entre todos los peers disponibles**
  ///    (`whole_pieces_threshold=0`, configurado en la sesión).
  ///  - La sesión ya está configurada con `downloadRateLimit=0` (sin límite),
  ///    `connectionsLimit=200` a nivel sesión y `max_queued_disk_bytes=64MB`.
  ///    Al NO pasar por `startStream` (que capaba a 25 conexiones por torrent
  ///    y le ponía prioridades por pieza serializadas), el torrent hereda los
  ///    200 peers del sesión → máxima fanout.
  ///  - `setFilePriorities` marca SOLO el archivo objetivo con prioridad alta y
  ///    el resto a 0 (dont_download): todo el ancho de banda va al fichero que
  ///    vamos a reproducir, sin desperdiciarlo en muestras/avisos.
  ///
  /// Estamos a `progress/downloadRate/numPeers/isFinished` vía el polling del
  /// motor. Rendimos cuando el archivo objetivo está completo.
  /// ══════════════════════════════════════════════════════════════════════
  /// MODO DESCARGA COMPLETA (MÁXIMA VELOCIDAD - LIMPIO Y OPTIMIZADO)
  ///
  /// Descarga el archivo objetivo del torrent a disco usando todo el ancho
  /// de banda disponible. Sin pausas artificiales, sin fallback de File.length()
  /// (pre-allocated), con progreso real via stats del torrent y timeouts agresivos.
  Future<TorrentPlaybackSession> downloadAndPlay({
    required String infoHash,
    int? fileIndex,
    Duration metadataTimeout = const Duration(seconds: 30),
    Duration maxWait = const Duration(minutes: 10),
    int? knownSeeders,
    int? knownPeers,
    int? knownSizeBytes,
    void Function(TorrentDownloadProgress)? onProgress,
  }) async {
    print('TORRENT_DBG: downloadAndPlay() infohash=$infoHash fileIdx=$fileIndex');
    await _ensureInit();
    final engine = LibtorrentFlutter.instance;
    final saveDir = _saveDirFor(infoHash);

    // Limpia SOLO el subdirectorio de ESTE infohash (nunca el global).
    try {
      final dir = Directory(saveDir);
      if (dir.existsSync()) {
        dir.deleteSync(recursive: true);
        dir.createSync(recursive: true);
        print('TORRENT_DBG: downloadAndPlay limpieza subdir infohash OK');
      }
    } catch (_) {}

    // Libera un torrent previo del mismo infohash que siga vivo en el engine.
    final existing = _infohashToTorrentId[infoHash.toLowerCase()];
    if (existing != null) {
      print('TORRENT_DBG: downloadAndPlay libera torrent previo (id=$existing)');
      try { engine.disposeTorrent(existing); } catch (_) {}
      _managedTorrentIds.remove(existing);
      _infohashToTorrentId.remove(infoHash.toLowerCase());
      _stopKeepAliveFor(existing);
    }

    final magnet = _magnet(infoHash);
    final torrentId = engine.addMagnet(magnet, saveDir, false);
    _infohashToTorrentId[infoHash.toLowerCase()] = torrentId;
    print('TORRENT_DBG: downloadAndPlay addMagnet(id=$torrentId, streamOnly=false) OK');

    try {
      // ── 1. METADATA con reintentos rápidos (no 120s bloqueados) ──
      List<FileInfo> files = [];
      int metadataRetries = 3;
      while (metadataRetries > 0) {
        try {
          files = await _waitForMetadata(engine, torrentId, timeout: metadataTimeout);
          if (files.isNotEmpty) break;
        } catch (_) {}
        metadataRetries--;
        if (metadataRetries > 0) {
          print('TORRENT_DBG: metadata timeout, reintentando... ($metadataRetries)');
          await Future.delayed(const Duration(seconds: 2));
        }
      }
      if (files.isEmpty) {
        engine.disposeTorrent(torrentId);
        throw Exception('Torrent sin archivos reproducibles (metadata timeout).');
      }
      print('TORRENT_DBG: downloadAndPlay metadata: ${files.length} files');
      _logFileList(files);

      // ── 2. SELECCIONAR ARCHIVO OBJETIVO ──
      final target = _pickFileIndex(files, fileIndex);
      final targetFile = (target >= 0 && target < files.length) ? files[target] : null;
      if (targetFile == null) {
        engine.disposeTorrent(torrentId);
        throw Exception('No se pudo localizar el archivo de vídeo.');
      }
      print('TORRENT_DBG: downloadAndPlay ▶ TARGET=$target '
          '${targetFile.name} size=${targetFile.size}B '
          '(${(targetFile.size / (1024 * 1024)).toStringAsFixed(2)}MB)');

      // ── 3. PRIORIDADES: descargar TODO el torrent ──
      // El usuario quiere que el % se mida contra el torrent COMPLETO (todos
      // sus archivos, p.ej. 1.78GB) y que se descargue por completo, no solo la
      // pieza que se va a reproducir. Ponemos prioridad 7 a todos los archivos
      // para que libtorrent descargue todo el torrent y dispare "finished"
      // cuando el torrent entero esté en disco.
      final priorities = List<int>.filled(files.length, 7);
      engine.setFilePriorities(torrentId, priorities);
      engine.resumeTorrent(torrentId); // asegura que no esté pausado
      print('TORRENT_DBG: setFilePriorities TODOS=7 (descarga de todo el torrent) + resume');

      // ── 4. RUTA LOCAL Y TAMAÑO OBJETIVO ──
      final relPath = targetFile.path
          .replaceAll('\\', '/')
          .split('/')
          .where((s) => s.isNotEmpty && s != '.' && s != '..')
          .join('/');
      final localPath = p.join(saveDir, relPath);
      final fileUrl = 'file://$localPath';
      final targetSizeBytes = targetFile.size > 0 ? targetFile.size : null;

      // ── 5. TRACKING PROGRESO REAL VIA TORRENT STATS ──
      // Usamos totalWanted/totalDone del torrent (si funciona).
      // Completado = isFinished/seeding + archivo existe.
      // IMPORTANTE: totalDone SÍ funciona (vimos en logs: done=290680977/1788212038B)
      // aunque totalWanted sea 0. Usamos targetSizeBytes como total real.

      _startKeepAlive(engine, torrentId);

// ── 6. LOOP DE DESCARGA CON PROGRESO REAL ──
      final deadline = DateTime.now().add(maxWait);
      double lastDoneMB = 0;
      DateTime? lastSampleTime;
      int noProgressTicks = 0;
      DateTime lastProgressTime = DateTime.now();
      int consecutiveDownloadingTicks = 0;

      // El status del bridge (prebuilt) es basura (totalDone/totalWanted=0,
      // state pegado en checkingFiles, numPieces=-1). La señal fiables son los
      // alerts NATIVOS "piece: N finished downloading", que sí llegan. Los
      // contamos para saber cuántas piezas distintas del torrent han caído.
      final downloadedPieces = <int>{};
      // El prebuilt congela el status (isFinished nunca se vuelve true, el
      // estado queda pegado en checkingFiles). El NAtivo libtorrent SÍ dispara
      // alerts "state changed to: finished" / "torrent finished downloading"
      // cuando todas las piezas wanted del archivo objetivo están en disco.
      // Esa es la señal REAL de completado → la capturamos aparte del status.
      var alertFinished = false;
      DateTime? lastNewPieceTime;
      // Mayor índice de pieza visto en los alerts nativos. Como se descarga
      // TODO el torrent (todos los archivos a prioridad 7), el conjunto de
      // piezas abarca el torrent completo: numPiezasTotales = maxPieceSeen + 1.
      // Es LA señal NATIVA fiable para el total (el bridge devuelve
      // numPieces=-1, totalWanted=0 o el tamaño de un solo archivo).
      int maxPieceSeen = -1;
      // Cache del mayor totalWanted visto. El prebuilt a veces lo reporta 0
      // en el loop aunque en otro tick dio el total REAL del torrent completo
      // (p.ej. 1788384744B = todos los archivos). Guardamos el mayor para NUNCA
      // caer al tamaño de un solo archivo (Torrentio) si ya vimos el nativo.
      int bestTotalWanted = 0;
      StreamSubscription<(int, String)>? alertSub;
      try {
        alertSub = LibtorrentFlutter.alertStream.listen((e) {
          if (e.$1 != torrentId) return;
          final m = RegExp(r'piece:\s*(-?\d+)\s+finished').firstMatch(e.$2);
          if (m != null) {
            final p = int.parse(m.group(1)!);
            if (p >= 0 && !downloadedPieces.contains(p)) {
              downloadedPieces.add(p);
              if (p > maxPieceSeen) maxPieceSeen = p;
              lastNewPieceTime = DateTime.now();
            }
          }
          if (e.$2.contains('state changed to: finished') ||
              e.$2.contains('torrent finished downloading') ||
              e.$2.contains('state changed to: seeding')) {
            if (!alertFinished) {
              alertFinished = true;
              print('TORRENT_DBG: ⏭ alert NATIVO de completado: ${e.$2.trim()}');
            }
          }
        });
      } catch (_) {}

      // Momento de arranque del loop: base del "quietFor" antes de la primera
      // pieza, para abortar por stall con un mensaje claro.
      final loopStart = DateTime.now();

      try {
      while (DateTime.now().isBefore(deadline)) {
        final t = engine.torrents[torrentId];
        if (t == null) {
          print('TORRENT_DBG: torrent desapareció');
          break;
        }

        final totalDone = t.totalDone;
        final totalWanted = t.totalWanted;
        // El prebuilt devuelve numPeers/numSeeds = -1 por defecto (cabecera
        // deprecada); Torrentio ya conoce seeders reales (>0). Priorizamos el
        // valor del bridge solo si es >= 0 y parece vivo (numPeers>0).
        int peers = t.numPeers >= 0 ? t.numPeers : (knownPeers ?? 0);
        int seeds = t.numSeeds >= 0 ? t.numSeeds : (knownSeeders ?? 0);
        final stateStr = t.state.toString().split('.').last;
        final isFinished = t.isFinished || t.state == TorrentState.seeding || t.state == TorrentState.finished;

        // ════════════════════════════════════════════════════════════════════
        // PROGRESO REAL:
        //  - `t.progress` (float) es el campo DEPRECADO de libtorrent y el
        //    prebuilt lo deja en 0 durante `downloading` (solo se rellena en
        //    checking_files). NO es fiable.
        //  - `t.totalDone` / `t.totalWanted` SÍ son contadores reales, pero el
        //    prebuilt a veces los congela (vimos done=131072 fijo mientras el
        //    nativo descargaba piezas 396, 379, 482...).
        //  - `piecesDone`/`numPieces` se calculan NATIVAMENTE desde `st.pieces`
        //    (query_pieces, ver torrent_bridge.cpp fill_status) y SÍ avanzan en
        //    tiempo real → es la señal de progreso PRIMARIA.
        //  - `downloadRate` del bridge reporta 0 con activeDL=true → la
        //    velocidad se calcula en Dart a partir del delta de piezas/bytes.
        // ════════════════════════════════════════════════════════════════════
        double pct = -1.0;
        if (totalWanted > bestTotalWanted) bestTotalWanted = totalWanted;

        // ── Piezas NATIVAS del TORRENT COMPLETO ──
        // Como todos los archivos están a prioridad 7, los alerts "piece: N
        // finished" cubren el torrent entero. [maxPieceSeen+1] = nº total de
        // piezas del torrent; [downloadedPieces.length] = piezas ya bajadas.
        // El bridge del prebuilt NO rellena numPieces/piecesDone (-1/0), así
        // que la fuente primaria correcta son los alerts nativos.
        final nativeTotalPieces = maxPieceSeen >= 0 ? (maxPieceSeen + 1) : 0;
        final nativeDonePieces = downloadedPieces.length;

        // ── TOTAL EN MB: TODO el torrent (todos los archivos), NO Torrentio ──
        // Prioridad:
        //  1) bestTotalWanted (totalWanted cacheado = torrent completo nativo)
        //  2) targetSizeBytes (getFiles)
        //  3) knownSizeBytes (Torrentio) — último recurso de magnitud
        // NO usamos knownSizeBytes como fuente preferida, porque suele reportar
        // SOLO el tamaño del archivo objetivo y no el de todo el torrent (p.ej.
        // 1011MB en vez de 1.78GB). Pero si es lo único disponible, al menos lo
        // usamos para escalar doneMB de forma consistente con el %.
        double totalMB = 0.0;
        if (bestTotalWanted > 0) {
          totalMB = bestTotalWanted / 1048576.0;
        } else if (targetSizeBytes != null && targetSizeBytes > 0) {
          totalMB = targetSizeBytes / 1048576.0;
        } else if (knownSizeBytes != null && knownSizeBytes > 0) {
          totalMB = knownSizeBytes / 1048576.0;
        } else if (t.progress > 0.0005) {
          totalMB = t.progress > 0 ? (totalDone / 1048576.0) / t.progress : 0.0;
        }

        // doneMB: lo derivamos del progreso NATIVO por piezas del torrent
        // completo, escalado al TOTAL (totalMB). Así los MB mostrados avanzan en
        // consonancia con el % aunque el bridge no dé bytes reales (totalDone=0).
        // Si aún no sabemos el nº de piezas, caemos a totalDone (contador nativo).
        double doneMB = 0.0;
        if (nativeTotalPieces > 0 && totalMB > 0) {
          doneMB = (nativeDonePieces / nativeTotalPieces) * totalMB;
        } else {
          doneMB = totalDone / 1048576.0;
        }

        // bytes por pieza estimado (solo diagnóstico / consistencia).
        final double bytesPerPiece = (nativeTotalPieces > 0 && totalMB > 0)
            ? (totalMB * 1048576.0) / nativeTotalPieces
            : 0.0;

        double speedMBps = 0.0;

        // Velocidad real calculada en Dart (delta de bytes descargados).
        final nowSample = DateTime.now();
        if (lastSampleTime != null) {
          final elapsedSec = nowSample.difference(lastSampleTime)
              .inMicroseconds / 1000000.0;
          if (elapsedSec > 0.01) {
            final deltaMB = (doneMB - lastDoneMB).clamp(-999.0, 999.0);
            speedMBps = deltaMB > 0 ? deltaMB / elapsedSec : 0.0;
          }
        }

        // El % se calcula PRIMERO con las piezas NATIVAS del torrent completo
        // (downloadedPieces.length / nativeTotalPieces) — la señal REAL e
        // independiente de cualquier tamaño de metadatos. Así llega a 100% solo
        // cuando TODO el torrent está en disco, y NO al terminar el archivo
        // objetivo (que era el bug: se medía contra 1011MB de Torrentio).
        if (nativeTotalPieces > 0) {
          pct = (100.0 * nativeDonePieces / nativeTotalPieces).clamp(0.0, 100.0);
        } else if (totalMB > 0) {
          pct = (100.0 * doneMB / totalMB).clamp(0.0, 100.0);
        }
        if (isFinished) pct = 100.0;

        // ── SEÑALES DE COMPLETADO / STALL (por piezas NATIVAS) ──
        // [quietFor] = segundos SIN recibir una pieza nueva (o desde el arranque).
        // [fullRange] = las piezas vistas cubren CONTIGUAS 0..max. Como el archivo
        // objetivo tiene prioridad 7 (el resto 0), "0..max completo" = el archivo
        // está al 100% real (no es una estimación por tamaño).
        // [progressRatio] = % de bytes (solo diagnóstico).
        final quietFor = lastNewPieceTime == null
            ? DateTime.now().difference(loopStart).inSeconds
            : DateTime.now().difference(lastNewPieceTime!).inSeconds;
        final maxPiece = downloadedPieces.isEmpty
            ? -1
            : downloadedPieces.reduce((a, b) => a > b ? a : b);
        final fullRange = maxPiece >= 0 && downloadedPieces.length == maxPiece + 1;
        final progressRatio = totalMB > 0 ? (doneMB / totalMB).clamp(0.0, 1.0) : 0.0;

        // ── DETECCIÓN DE DESCARGA ACTIVA / STALL ──
        // Señal primaria = piezas NUEVAS (native) o totalDone avanza — ambos
        // NATIVOS. `state=checkingFiles` + `isPaused=true` con el archivo en
        // disco NO es "descarga activa": es el torrent re-chequeando/pausado
        // tras terminar, así que NO debe mantener el loop vivo para siempre.
        final newPieceRecent = lastNewPieceTime != null &&
            nowSample.difference(lastNewPieceTime!).inSeconds < 3;
        bool progressed = doneMB > lastDoneMB || newPieceRecent;
        bool isActuallyDownloading =
            (stateStr == 'downloading' || stateStr == 'allocating' ||
             stateStr == 'downloadingMetadata' || stateStr == 'checkingResume' ||
             stateStr == 'checkingFiles') &&
            !t.isPaused;
        bool hasActiveDownload = progressed || speedMBps > 0.01 ||
            isActuallyDownloading || consecutiveDownloadingTicks > 0;

        if (progressed) {
          lastProgressTime = nowSample;
          noProgressTicks = 0;
          consecutiveDownloadingTicks++;
        } else if (isActuallyDownloading) {
          consecutiveDownloadingTicks++;
          noProgressTicks = 0;
        } else {
          consecutiveDownloadingTicks = 0;
          noProgressTicks++;
        }
        lastDoneMB = doneMB;
        lastSampleTime = nowSample;

        // Emitir progreso a UI
        if (onProgress != null) {
          onProgress(TorrentDownloadProgress(
            percent: pct,
            downloadedMB: doneMB,
            totalMB: totalMB,
            speedMBps: speedMBps,
            peers: peers,
            seeds: seeds,
            state: stateStr,
            finished: isFinished,
          ));
        }

        // Log cada cambio de rate o cada 10s
        if (speedMBps != 0 || DateTime.now().difference(lastProgressTime).inSeconds > 10) {
          print('TORRENT_DBG: dl state=$stateStr '
              '${pct >= 0 ? '${pct.toStringAsFixed(1)}%' : '?%'} '
              'done=${doneMB.toStringAsFixed(1)}/${totalMB.toStringAsFixed(1)}MB '
              'rate=${speedMBps.toStringAsFixed(2)}MB/s peers=$peers seeds=$seeds '
              'piecesAlert=${downloadedPieces.length} totalDone=${totalDone}B '
              'states=$stateStr activeDL=$hasActiveDownload consecDL=$consecutiveDownloadingTicks '
              '[TOTAL bestTW=${bestTotalWanted}B maxPiece=$maxPieceSeen '
              'nativePieces=$nativeTotalPieces donePieces=$nativeDonePieces '
              'bytesPiece=${bytesPerPiece.round()}B knownSize=$knownSizeBytes]');
        }

        // ── COMPLETADO ──
        // El status del bridge es basura (isFinished casi nunca se vuelve true y
        // queda pegado en checkingFiles). Completamos SOLO si:
        //   1) el status lo dice (isFinished),
        //   2) el alert NATIVO "torrent finished downloading" / "state changed
        //      to: finished" — el nativo libtorrent lo dispara cuando TODAS las
        //      piezas wanted están en disco (con todos los archivos priorizados
        //      = el torrent completo real, señal REAL),
        //   3) FALLBACK ULTRA-CONSERVADOR: el archivo objetivo existe Y las piezas
        //      vistas (alerts nativos) cubren CONTIGUAS 0..max (cubiertos) Y
        //      llevamos >=45s quietos (re-check/pausa después de terminar).
        //    → SIN gate "terminalState": el bridge reporta checkingFiles durante
        //      TODA la descarga (nunca textualizaba el fin real).
        //    → SIN umbral de % por bytesPorPieza: las piezas reales son ~1-2MB y
        //      una estimación puede aprobarse antes del 100% real.
        final exists = await File(localPath).exists();
        final fileLenBytes = exists ? await File(localPath).length() : 0;
        // Con TODOS los archivos liberados, downloadedPieces abarca el torrent
        // completo; fullRange (0..maxPiece contiguas) solo se alcanza al 100%.
        final fileCompleteHigh = exists &&
            downloadedPieces.isNotEmpty &&
            fullRange &&
            quietFor >= 45;
        if (isFinished || alertFinished || fileCompleteHigh) {
          print('TORRENT_DBG: downloadAndPlay ⏭ COMPLETO (state=$stateStr '
              'alertFinished=$alertFinished fileSafe=$fileCompleteHigh '
              'pieces=${downloadedPieces.length} maxPiece=$maxPiece '
              'size=${(fileLenBytes / 1048576).toStringAsFixed(1)}MB) '
              'archivoExiste=$exists localPath=$localPath');
          if (onProgress != null) {
            onProgress(TorrentDownloadProgress(
              percent: 100.0,
              downloadedMB: fileLenBytes / 1048576.0,
              totalMB: totalMB > 0 ? totalMB : (fileLenBytes / 1048576.0),
              speedMBps: 0,
              peers: peers,
              seeds: seeds,
              state: 'finished',
              finished: true,
            ));
          }
          if (exists) {
            return TorrentPlaybackSession(
              torrentId: torrentId,
              streamId: 0,
              localPath: fileUrl,
              name: fileUrl,
            );
          }
        }

        // ── STALL REAL: 60s sin ninguna pieza nueva y sin llegar a rango
        // completo = descarga estancada. Abortamos (nunca reproducir un archivo
        // incompleto/truncado).
        if (!alertFinished && downloadedPieces.isNotEmpty &&
            quietFor >= 60 && !fullRange) {
          print('TORRENT_DBG: ⚠ stall REAL ${quietFor}s sin piezas nuevas, '
              'abortando (state=$stateStr pieces=${downloadedPieces.length} '
              'maxPiece=$maxPiece fullRange=$fullRange done=${doneMB.toStringAsFixed(1)}MB '
              'ratio=${progressRatio.toStringAsFixed(2)})');
          break;
        }

        // ── STALL DETECTION (status bridge): aborta torrents muertos sin seeds ──
        final bool trulyStalled = !hasActiveDownload && !isActuallyDownloading &&
            consecutiveDownloadingTicks == 0 && noProgressTicks >= 60;
        if (trulyStalled) {
          print('TORRENT_DBG: ⚠ sin progreso REAL 60s, abortando (state=$stateStr done=${doneMB.toStringAsFixed(1)}MB consecDL=$consecutiveDownloadingTicks)');
          break;
        }

        await Future.delayed(const Duration(seconds: 1));
      }
      } finally {
        await alertSub?.cancel();
      }

      // ── TIMEOUT / STALL: NUNCA reproducir un archivo incompleto ──
      print('TORRENT_DBG: ✖ timeout/stall sin llegar al 100% — abortando '
          '(pieces=${downloadedPieces.length} alertFinished=$alertFinished)');
      throw Exception(
          'No se pudo completar la descarga (tiempo agotado o estancada). '
          'Reintenta o elige otro servidor.');

    } catch (e, st) {
      print('TORRENT_DBG: downloadAndPlay ERROR: $e\n$st');
      _stopKeepAliveFor(torrentId);
      _managedTorrentIds.remove(torrentId);
      _infohashToTorrentId.remove(infoHash.toLowerCase());
      engine.disposeTorrent(torrentId);
      rethrow;
    }
  }

  Timer? _keepAliveTimer;
  StreamSubscription<Map<int, TorrentInfo>>? _torrentUpdatesSub;

  /// Buffer inicial tipo Stremio: espera a que el servidor HTTP interno nativo
  /// tenga pre-descargado [preloadBytes] contiguos DESDE EL INICIO (por defecto
  /// 50MB). Hace peticiones HTTP con rango `bytes=0-N` crecientes: cada petición
  /// alimenta `serve_range`, que descarga de forma SECUENCIAL en orden (pieza
  /// actual + pipeline por delante). Cuando el servidor ya devuelve ≥ [preloadBytes]
  /// bytes, la descarga va "por delante" y devolvemos la URL para que media_kit
  /// reproduzca con margen (el seek dentro de lo descargado no salta).
  ///
  /// Cada sonda usa un HttpClient nuevo y un timeout estricto de lectura (vía
  /// Timer) para no colgar la UI si una pieza tarda. Se registra la velocidad.
  Future<void> _waitForStreamStart(
    LibtorrentFlutter engine,
    int torrentId,
    int streamId, {
    required String url,
    int preloadBytes = 50 * 1024 * 1024,
    int? fileSize,
    Duration timeout = const Duration(seconds: 120),
  }) async {
    print('TORRENT_DBG: _waitForStreamStart url=$url preloadBytes=$preloadBytes '
        'fileSize=$fileSize timeout=${timeout.inSeconds}s');
    final start = DateTime.now();
    var target = preloadBytes > 0 ? preloadBytes : 50 * 1024 * 1024;
    var ready = false;
    var lastServed = 0;
    var stallCount = 0;
    Map<int, double> servedAt = {};

    while (DateTime.now().difference(start) < timeout) {
      final ti = engine.torrents[torrentId];
      if (ti != null && ti.isPaused) {
        engine.resumeTorrent(torrentId);
      }

      final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
      int served = 0;
      try {
        final req = await client.getUrl(Uri.parse(url))
            .timeout(const Duration(seconds: 2));
        req.headers.set(HttpHeaders.rangeHeader, 'bytes=0-${target - 1}');
        req.headers.set(HttpHeaders.acceptHeader, '*/*');
        final res = await req.close().timeout(const Duration(seconds: 2));
        if (res.statusCode == 200 || res.statusCode == 206) {
          // Leer con timeout: si una pieza media tarda en llegar, salimos del
          // read (guardamos lo servido hasta ahora) y reintentamos en la
          // siguiente iteración. Así no colgamos sin control; el socket se
          // cierra con force en el finally del cliente de esta iteración.
          var read = served;
          Future<int> counting() async {
            var n = 0;
            await for (final chunk in res) {
              n += chunk.length;
            }
            return n;
          }
          read = await counting().timeout(const Duration(seconds: 10),
              onTimeout: () {
            print('TORRENT_DBG: [preload] read timeout (pieza media lenta)');
            return served;
          });
          served = read;
          servedAt[served] = DateTime.now().difference(start).inMilliseconds / 1000.0;
          if (served != lastServed) {
            print('TORRENT_DBG: [preload] served=${served}B '
                '(${(served / (1024 * 1024)).toStringAsFixed(1)}MB) / '
                '${(target / (1024 * 1024)).toStringAsFixed(1)}MB');
            lastServed = served;
          }
          if (served >= target) {
            ready = true;
            break;
          }
          // Archivo completo servido: si el fichero es más pequeño que el
          // umbral deseado, reproduce con lo que hay (se descargó entero).
          if (fileSize != null && served >= fileSize) {
            print('TORRENT_DBG: [preload] archivo completo servido '
                '(served=$served == fileSize=$fileSize), listo para reproducir');
            ready = true;
            break;
          }
        } else {
          print('TORRENT_DBG: [preload] status inesperado=${res.statusCode}');
          await res.drain<void>();
        }
      } catch (e) {
        print('TORRENT_DBG: [preload] probe error: $e');
      } finally {
        client.close(force: true);
      }

      // Detección de estancamiento: si no crece lo servido (p.ej. archivo menor
      // que el target, o descarga frenada), no esperamos el timeout completo.
      if (served <= 0 && lastServed <= 0) {
        stallCount++;
      } else if (served == lastServed) {
        stallCount++;
      } else {
        stallCount = 0;
      }
      // Si llevamos unas cuantas iteraciones sin avanzar y ya servimos algo,
      // el archivo es más pequeño que el target: reproducimos con lo que hay.
      if (stallCount >= 3 && lastServed > 0) {
        print('TORRENT_DBG: [preload] sin avance (archivo menor al target?), '
            'arranco con ${lastServed}B');
        break;
      }
      await Future.delayed(const Duration(milliseconds: 200));
    }

    if (servedAt.length >= 2) {
      final keys = servedAt.keys.toList()..sort();
      final last = keys.last;
      final t = servedAt[last]!;
      if (t > 0) {
        print('TORRENT_DBG: [preload] velocidad media ≈ '
            '${(last / t / (1024 * 1024)).toStringAsFixed(1)}MB/s a '
            '${(last / (1024 * 1024)).toStringAsFixed(1)}MB en ${t.toStringAsFixed(1)}s');
      }
    }
    print('TORRENT_DBG: _waitForStreamStart $ready en '
        '${DateTime.now().difference(start).inSeconds}s (served=${lastServed}B)');
  }

  /// Registra el torrentId en el keepalive multi-torrent. El keepalive vigila
  /// TODOS los torrents activos del servicio (no solo el último), y reanuda
  /// cualquier torrent pausado que aún no esté finished/seeding. Un torrent
  /// que queda `isPaused=true` (p.ej. tras errores I/O o en `checkingFiles`)
  /// sin keepalive se queda clavado para siempre al % actual.
  void _startKeepAlive(LibtorrentFlutter engine, int torrentId) {
    _managedTorrentIds.add(torrentId);
    _torrentUpdatesSub ??= engine.torrentUpdates.listen((torrents) {
      for (final id in List.of(_managedTorrentIds)) {
        final t = torrents[id];
        if (t == null) continue;
        _resumeIfStalled(engine, id, t);
      }
    });
    _keepAliveTimer ??= Timer.periodic(const Duration(seconds: 5), (_) {
      for (final id in List.of(_managedTorrentIds)) {
        final ti = engine.torrents[id];
        if (ti == null) {
          _managedTorrentIds.remove(id);
          continue;
        }
        _resumeIfStalled(engine, id, ti);
        print('TORRENT_DBG: [keepalive] id=$id state=${ti.state} '
            'progress=${(ti.progress * 100).toStringAsFixed(1)}% '
            'done=${ti.totalDone}/${ti.totalWanted}B '
            'peers=${ti.numPeers} isPaused=${ti.isPaused}');
      }
    });
  }

  /// Reanuda un torrent pausado mientras no esté finished/seeding/error.
  /// Antes solo reanudaba si `state` era downloading/seeding; un torrent
  /// pausado en `checkingFiles` (por errores I/O al borrarse el saveDir, o al
  /// verificar piezas) nunca se reanudaba y el % quedaba congelado.
  void _resumeIfStalled(LibtorrentFlutter engine, int id, TorrentInfo t) {
    if (!t.isPaused) return;
    if (t.isFinished) return;
    if (t.state == TorrentState.error || t.state == TorrentState.unknown) return;
    if (t.hasMetadata == false && t.state == TorrentState.downloadingMetadata) {
      return; // Esperando metadata es normal que aparezca pausado.
    }
    engine.resumeTorrent(id);
  }

  /// Quita UN torrent del keepalive (tras stop()/dispose de esa sesión), sin
  /// afectar a los demás torrents que sigan activos.
  void _stopKeepAliveFor(int torrentId) {
    _managedTorrentIds.remove(torrentId);
    if (_managedTorrentIds.isEmpty) _stopTorrentKeepAlive();
  }

  void _stopTorrentKeepAlive() {
    _keepAliveTimer?.cancel();
    _keepAliveTimer = null;
    _torrentUpdatesSub?.cancel();
    _torrentUpdatesSub = null;
    _managedTorrentIds.clear();
  }

  int _pickFileIndex(List<FileInfo> files, int? requested) {
    if (files.isEmpty) return -1;
    if (requested != null && requested >= 0 && requested < files.length) {
      return requested;
    }
    // Auto: mayor archivo reproducible.
    FileInfo? best;
    for (final f in files) {
      if (!f.isStreamable) continue;
      if (best == null || f.size > best.size) best = f;
    }
    return best?.index ?? -1;
  }

  Future<List<FileInfo>> _waitForMetadata(
    LibtorrentFlutter engine,
    int torrentId, {
    required Duration timeout,
  }) async {
    print('TORRENT_DBG: _waitForMetadata start torrentId=$torrentId timeout=${timeout.inSeconds}s');
    // Check initial state
    final initialState = engine.torrents[torrentId]?.state;
    final initialHasMetadata = engine.torrents[torrentId]?.hasMetadata;
    if (initialState != null &&
        initialState != TorrentState.downloadingMetadata) {
      print('TORRENT_DBG: _waitForMetadata: already past downloadingMetadata (state=$initialState)');
      final files = engine.getFiles(torrentId);
      if (files.isNotEmpty) return files;
    }
    if (initialHasMetadata == true) {
      print('TORRENT_DBG: _waitForMetadata: already has metadata');
      final files = engine.getFiles(torrentId);
      if (files.isNotEmpty) return files;
    }

    final completer = Completer<List<FileInfo>>();
    late StreamSubscription<Map<int, TorrentInfo>> sub;
    sub = engine.torrentUpdates.listen((torrents) {
      final t = torrents[torrentId];
      print('TORRENT_DBG: torrentUpdates tick torrentId=$torrentId hasMetadata=${t?.hasMetadata} state=${t?.state}');
      if (t != null) {
        if (t.state == TorrentState.error) {
          print('TORRENT_DBG: torrent error: ${t.errorMsg}');
          if (!completer.isCompleted) {
            completer.completeError(
                Exception(t.errorMsg.isNotEmpty ? t.errorMsg : 'Error del torrent'));
          }
          sub.cancel();
        } else if (_isMetadataReady(t, engine, torrentId)) {
          // Metadata really available - fetch files IMMEDIATELY
          final files = engine.getFiles(torrentId);
          if (files.isNotEmpty) {
            if (!completer.isCompleted) completer.complete(files);
            sub.cancel();
          }
        } else {
          print('TORRENT_DBG: still waiting (hasMetadata=${t.hasMetadata}, state=${t.state})');
        }
      }
    });
    // Race-condition fix: check directly after subscription
    final afterSub = engine.torrents[torrentId]?.state;
    final afterSubHasMetadata = engine.torrents[torrentId]?.hasMetadata;
    final afterSubTorrent = engine.torrents[torrentId];
    print('TORRENT_DBG: _waitForMetadata re-check after subscription: state=$afterSub hasMetadata=$afterSubHasMetadata');
    if (afterSubTorrent != null && _isMetadataReady(afterSubTorrent, engine, torrentId)) {
      print('TORRENT_DBG: metadata already available in re-check, fetching files');
      final files = engine.getFiles(torrentId);
      if (files.isNotEmpty) {
        if (!completer.isCompleted) completer.complete(files);
        await sub.cancel();
        return files;
      }
    }
    // Fallback polling loop: check hasMetadata directly every 500ms
    // This catches cases where torrentUpdates is delayed but metadata is already available
    Timer? pollTimer;
    int consecutiveNulls = 0;
    pollTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      final current = engine.torrents[torrentId];
      if (current == null) {
        consecutiveNulls++;
        // Don't fail immediately - the internal poll timer (600ms default) might not have run yet
        // Allow up to 3 consecutive nulls (1.5 seconds) before giving up
        if (consecutiveNulls > 3) {
          print('TORRENT_DBG: torrent disappeared during polling after $consecutiveNulls consecutive nulls');
          if (!completer.isCompleted) {
            completer.completeError(Exception('Torrent desaparecido'));
          }
          pollTimer?.cancel();
          sub.cancel();
        }
        return;
      }
      consecutiveNulls = 0;
      if (_isMetadataReady(current, engine, torrentId)) {
        print('TORRENT_DBG: polling detected metadata ready (hasMetadata=${current.hasMetadata}, state=${current.state})');
        final files = engine.getFiles(torrentId);
        if (files.isNotEmpty) {
          if (!completer.isCompleted) completer.complete(files);
          pollTimer?.cancel();
          sub.cancel();
        }
      }
    });
    try {
      final files = await completer.future.timeout(timeout);
      print('TORRENT_DBG: _waitForMetadata completed successfully with ${files.length} files');
      return files;
    } on TimeoutException {
      print('TORRENT_DBG: _waitForMetadata TIMEOUT after ${timeout.inSeconds}s');
      throw Exception(
          'No se pudo obtener los metadatos del torrent (verifica las seeds).');
    } finally {
      await sub.cancel();
      pollTimer?.cancel();
    }
  }

  /// Determina si los metadatos (lista de archivos) ya están realmente disponibles.
  /// Evita tratar estados intermedios (p.ej. `checkingFiles`) como "metadata listo"
  /// cuando `getFiles` aún devuelve vacío, que causaba un bucle inútil de reintentos.
  bool _isMetadataReady(TorrentInfo t, LibtorrentFlutter engine, int torrentId) {
    // Error siempre cuenta como listo para manejo en el caller (no usado aquí)
    if (t.hasMetadata == true) return true;
    if (t.state == TorrentState.downloadingMetadata) return false;
    // Estados posteriores a la metadata: solo listo si los archivos existen
    try {
      return engine.getFiles(torrentId).isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  /// Parsea el índice de pieza desde un alert nativo "piece: N finished
  /// downloading". Devuelve null si el alert no es de pieza terminada.
  int? _parsePieceFinished(String alert) {
    final m = RegExp(r'piece:\s*(-?\d+)\s+finished').firstMatch(alert);
    if (m == null) return null;
    final p = int.parse(m.group(1)!);
    return p >= 0 ? p : null;
  }

  /// Registra en logs la lista completa de archivos del torrent para poder
  /// decodificar qué es lo que trae el enlace extraído por el addon.
  void _logFileList(List<FileInfo> files, {int max = 200}) {
    print('TORRENT_DBG: ── FILE LIST (${files.length} archivos) ──');
    final printable = files.length > max ? files.sublist(0, max) : files;
    for (final f in printable) {
      print('TORRENT_DBG:   [${f.index}] ${f.name} | path=${f.path} '
          '| size=${f.size}B (${(f.size / (1024 * 1024)).toStringAsFixed(2)}MB) '
          '| streamable=${f.isStreamable}');
    }
    if (files.length > max) {
      print('TORRENT_DBG:   ... y ${files.length - max} archivos más');
    }
    print('TORRENT_DBG: ── FIN FILE LIST ──');
  }

  /// Libera el stream y el torrent cuando termina la reproducción.
  Future<void> stop(TorrentPlaybackSession session) async {
    print('TORRENT_DBG: stop() llamado streamId=${session.streamId} torrentId=${session.torrentId}');
    _stopKeepAliveFor(session.torrentId);
    _managedTorrentIds.remove(session.torrentId);
    if (!_initDone) return;
    try {
      final engine = LibtorrentFlutter.instance;
      if (session.streamId > 0) {
        engine.stopStream(session.streamId);
      }
      engine.disposeTorrent(session.torrentId);
      print('TORRENT_DBG: stop() completado');
    } catch (_) {}
  }

  /// Descarga el torrent COMPLETO (todos los archivos) a la carpeta pública
  /// `Descargas/K7-MOVIE/<movieName>/` del almacenamiento externo. A diferencia
  /// de `startStreaming`/`downloadAndPlay`, no reproduce: solo descarga y copia
  /// todos los archivos del torrent a una carpeta con nombre legible, y luego
  /// libera el torrent. Emite progreso vía [onProgress] hasta el 100% y devuelve
  /// la ruta de la carpeta destino.
  Future<String> downloadComplete({
    required String infoHash,
    required String movieName,
    Duration metadataTimeout = const Duration(seconds: 120),
    Duration maxWait = const Duration(minutes: 60),
    int? knownSizeBytes,
    void Function(TorrentDownloadProgress)? onProgress,
  }) async {
    print('TORRENT_DBG: downloadComplete() infohash=$infoHash movieName=$movieName');
    await _ensureInit();
    final engine = LibtorrentFlutter.instance;
    final saveDir = _saveDirFor(infoHash);

    // Limpia SOLO el subdirectorio de ESTE infohash (nunca el global).
    try {
      final dir = Directory(saveDir);
      if (dir.existsSync()) {
        dir.deleteSync(recursive: true);
        dir.createSync(recursive: true);
        print('TORRENT_DBG: downloadComplete limpieza subdir infohash OK');
      }
    } catch (_) {}

    // Libera un torrent previo del mismo infohash que siga vivo en el engine.
    final existing = _infohashToTorrentId[infoHash.toLowerCase()];
    if (existing != null) {
      print('TORRENT_DBG: downloadComplete libera torrent previo (id=$existing)');
      try { engine.disposeTorrent(existing); } catch (_) {}
      _managedTorrentIds.remove(existing);
      _infohashToTorrentId.remove(infoHash.toLowerCase());
      _stopKeepAliveFor(existing);
    }

    final magnet = _magnet(infoHash);
    final torrentId = engine.addMagnet(magnet, saveDir, false);
    _infohashToTorrentId[infoHash.toLowerCase()] = torrentId;
    print('TORRENT_DBG: downloadComplete addMagnet(id=$torrentId) OK');

    // Carpeta destino: Descargas/K7-MOVIE/<movieName>/
    final downloadsRoot = await _downloadsRootDir();
    final safeName = movieName
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
        .trim();
    final destDir = Directory(p.join(downloadsRoot, 'K7-MOVIE', safeName));
    destDir.createSync(recursive: true);
    print('TORRENT_DBG: downloadComplete carpeta destino=$destDir.path');

    final deadline = DateTime.now().add(maxWait);
    late StreamSubscription<(int, String)> alertSub;
    int maxPieceSeen = -1;
    int bestTotalWanted = 0;
    final Set<int> downloadedPieces = {};
    bool alertFinished = false;
    double lastEmittedPct = -1;

    try {
      final files = await _waitForMetadata(engine, torrentId, timeout: metadataTimeout);
      if (files.isEmpty) {
        engine.disposeTorrent(torrentId);
        throw Exception('Torrent sin archivos.');
      }
      _logFileList(files);

      // Descargar TODOS los archivos (torrent completo).
      engine.setFilePriorities(torrentId, List<int>.filled(files.length, 7));

      _startKeepAlive(engine, torrentId);
      alertSub = LibtorrentFlutter.alertStream.listen((e) {
        if (e.$1 != torrentId) return;
        final piece = _parsePieceFinished(e.$2);
        if (piece != null) {
          downloadedPieces.add(piece);
          if (piece > maxPieceSeen) maxPieceSeen = piece;
        } else if (e.$2.contains('torrent finished downloading') ||
            e.$2.contains('state changed to: finished') ||
            e.$2.contains('state changed to: seeding')) {
          if (!alertFinished) {
            alertFinished = true;
            print('TORRENT_DBG: downloadComplete alert NATIVO completado');
          }
        }
      }, onError: (_) {});

      int totalMB = 0;
      int nativeTotalPieces = 0;
      while (DateTime.now().isBefore(deadline)) {
        final ti = engine.torrents[torrentId];
        if (ti != null && ti.totalWanted is int && (ti.totalWanted as int) > bestTotalWanted) {
          bestTotalWanted = ti.totalWanted as int;
        }
        if (bestTotalWanted > 0 && totalMB == 0) totalMB = bestTotalWanted ~/ 1048576;
        if (maxPieceSeen >= 0) nativeTotalPieces = maxPieceSeen + 1;

        final nativeDone = downloadedPieces.length;
        final pct = nativeTotalPieces > 0
            ? (100.0 * nativeDone / nativeTotalPieces)
            : (bestTotalWanted > 0 ? (100.0 * (ti?.totalDone ?? 0) / bestTotalWanted) : 0.0);
        final doneMB = totalMB > 0 ? pct / 100.0 * totalMB : nativeDone.toDouble();

        if (onProgress != null &&
            (pct - lastEmittedPct >= 0.5 || (alertFinished && pct >= 100))) {
          lastEmittedPct = pct;
          onProgress(TorrentDownloadProgress(
            percent: pct.clamp(0.0, 100.0).toDouble(),
            downloadedMB: doneMB,
            totalMB: totalMB.toDouble(),
            speedMBps: (ti?.downloadRate ?? 0) / 1048576.0,
            peers: ti?.numPeers ?? 0,
            seeds: ti?.numSeeds ?? 0,
            state: 'downloading',
            finished: false,
          ));
        }

        if (alertFinished ||
            (nativeTotalPieces > 0 && nativeDone >= nativeTotalPieces)) {
          if (onProgress != null) {
            onProgress(TorrentDownloadProgress(
              percent: 100,
              downloadedMB: totalMB.toDouble(),
              totalMB: totalMB.toDouble(),
              speedMBps: 0,
              peers: ti?.numPeers ?? 0,
              seeds: ti?.numSeeds ?? 0,
              state: 'finished',
              finished: true,
            ));
          }
          break;
        }
        await Future.delayed(const Duration(seconds: 1));
      }
      await alertSub.cancel();

      if (!alertFinished && downloadedPieces.isNotEmpty) {
        // Render parcial: si no llegó a 100% en el tiempo límite, aborta.
        throw Exception('La descarga no completó a tiempo.');
      }

      // ── Copiar TODOS los archivos a la carpeta destino ──
      _copyTorrentTo(saveDir, destDir.path);

      _stopKeepAliveFor(torrentId);
      _managedTorrentIds.remove(torrentId);
      _infohashToTorrentId.remove(infoHash.toLowerCase());
      engine.disposeTorrent(torrentId);
      print('TORRENT_DBG: downloadComplete listo en ${destDir.path}');
      return destDir.path;
    } catch (e) {
      print('TORRENT_DBG: downloadComplete error: $e');
      try { await alertSub.cancel(); } catch (_) {}
      _stopKeepAliveFor(torrentId);
      _managedTorrentIds.remove(torrentId);
      _infohashToTorrentId.remove(infoHash.toLowerCase());
      engine.disposeTorrent(torrentId);
      rethrow;
    }
  }

  Future<String> _downloadsRootDir() async {
    // Almacenamiento externo raíz: /storage/emulated/0 (Android).
    try {
      if (Platform.isAndroid) {
        final ext = await getExternalStorageDirectory();
        if (ext != null) return ext.path;
      }
    } catch (_) {}
    final docs = await getApplicationDocumentsDirectory();
    return docs.path;
  }

  void _copyTorrentTo(String srcDir, String destDir) {
    // Recorre recursivamente saveDir y copia cada archivo real a destDir,
    // respetando la estructura de subcarpetas internas del torrent.
    final src = Directory(srcDir);
    if (!src.existsSync()) return;
    for (final entity in src.listSync(recursive: false)) {
      final rel = p.relative(entity.path, from: srcDir);
      if (entity is File) {
        final target = p.join(destDir, rel);
        final parent = p.dirname(target);
        Directory(parent).createSync(recursive: true);
        try {
          entity.copySync(target);
          print('TORRENT_DBG: copiado ${entity.path} → $target');
        } catch (e) {
          print('TORRENT_DBG: error copiando ${entity.path}: $e');
        }
      } else if (entity is Directory) {
        _copyTorrentTo(entity.path, p.join(destDir, rel));
      }
    }
  }

  /// Detiene todos los torrents activos (p.ej. al salir de la app).
  Future<void> disposeAll() async {
    _stopTorrentKeepAlive();
    if (!_initDone) return;
    try {
      LibtorrentFlutter.instance.disposeAll();
    } catch (_) {}
  }
}
