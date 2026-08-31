import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

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

/// Abstracción sobre `libtorrent_flutter` para reproducir torrents sin debrid.
///
/// En lugar de depender del servidor HTTP interno (que no sirve datos a tiempo
/// y provoca `SocketTimeoutException` en ExoPlayer), esta clase descarga el
/// archivo objetivo a disco de forma secuencial (piezas 0..N del fichero),
/// espera a tener pre-descargado ~1 minuto (~15-20 MB) y devuelve la ruta
/// local del archivo ya escrito en disco. El reproductor (media_kit vía
/// `video_player_media_kit`) reproduce ese archivo local sin sniffing ni
/// timeouts: un fichero real que, además, sigue creciendo mientras el torrent
/// continúa descargando.
class TorrentStreamingService {
  TorrentStreamingService._();
  static final TorrentStreamingService instance = TorrentStreamingService._();

  bool _initStarted = false;
  bool _initDone = false;
  Completer<void>? _initCompleter;
  String? _saveDir;

  Future<String> _defaultSaveDir() async {
    final base = await getTemporaryDirectory();
    final dir = Directory(p.join(base.path, 'torrents'));
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

  /// Inicia la descarga de un torrent y devuelve la ruta local del archivo
  /// objetivo una vez pre-descargado lo suficiente para empezar a reproducir.
  ///
  /// [preloadBytes] indica cuántos bytes del inicio del archivo queremos en
  /// disco antes de devolver la sesión (≈1 minuto de vídeo ≈ 10-20 MB por
  /// defecto). Como no conocemos el bitrate exacto, usamos un tamaño fijo.
  Future<TorrentPlaybackSession> start({
    required String infoHash,
    int? fileIndex,
    int preloadBytes = 64 * 1024 * 1024,
    Duration metadataTimeout = const Duration(seconds: 120),
  }) async {
    print('TORRENT_DBG: start() infohash=$infoHash fileIdx=$fileIndex preloadBytes=$preloadBytes');
    await _ensureInit();
    final engine = LibtorrentFlutter.instance;
    final saveDir = _saveDir!;
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

      // Ruta real en disco: saveDir + path relativo dentro del torrent.
      // Limpiamos separadores y evitamos path traversal.
      final relPath = (targetFile?.path ?? '')
          .replaceAll('\\', '/')
          .split('/')
          .where((s) => s.isNotEmpty && s != '.' && s != '..')
          .join('/');
      final localPath = p.join(saveDir, relPath);
      print('TORRENT_DBG: ▶ LOCAL FILE path=$localPath');

      // Prioridades de archivo: SOLO el archivo objetivo se descarga (nonzero),
      // el resto se marca 0 (dont_download) para no desperdiciar ancho de banda
      // en muestras/avisos. La prioridad de archivo multiplica la prioridad por
      // pieza que fija startStream, así que los ficheros no objetivo quedan a 0.
      if (target >= 0 && target < files.length) {
        final priorities = List<int>.filled(files.length, 0);
        priorities[target] = 1;
        engine.setFilePriorities(torrentId, priorities);
        print('TORRENT_DBG: setFilePriorities target=$target (others=0/skip)');
      }

      // startStream: la lógica nativa (PARCHEADA en torrent_bridge.cpp) ahora
      // mantiene TODO el archivo con prioridad no-cero (nunca pasa a `finished`
      // de forma prematura) y da top_priority al INICIO (primeros 256MB), de modo
      // que libtorrent descarga las piezas 0..N en orden PRIMERO: se escribe un
      // tramo de cabecera contiguo en disco rápido para poder reproducirlo.
      // No usamos su URL HTTP; sólo empleamos su motor para dirigir la descarga
      // secuencial del fichero local (media_kit reproduce file://).
      var streamId = 0;
      if (target >= 0 && target < files.length) {
        final stream = engine.startStream(torrentId, fileIndex: target);
        streamId = stream.id;
        print('TORRENT_DBG: startStream(parcheado) id=$streamId torrentId=$torrentId'
            ' targetFile=$target → descarga head-first a fichero');
      } else {
        engine.resumeTorrent(torrentId);
        print('TORRENT_DBG: resumeTorrent fallback torrentId=$torrentId');
      }

      final targetSize = targetFile?.size ?? 0;
      final desired = (preloadBytes <= 0 || targetSize == 0)
          ? (targetSize > 0 ? targetSize : preloadBytes)
          : preloadBytes.clamp(1, targetSize);

      // Esperar a tener pre-descargado el inicio del archivo.
      final waited = await _waitForPreload(engine, torrentId, desired,
          localPath: 'file://$localPath');
      _startKeepAlive(engine, torrentId);

      print('TORRENT_DBG: preload completado en ${waited.inSeconds}s → reproduciendo archivo local');
      final session = TorrentPlaybackSession(
        torrentId: torrentId,
        streamId: streamId,
        localPath: 'file://$localPath',
        name: localPath,
      );
      return session;
    } catch (_) {
      print('TORRENT_DBG: start() threw, disposing torrentId=$torrentId');
      engine.disposeTorrent(torrentId);
      rethrow;
    }
  }

  Timer? _keepAliveTimer;
  StreamSubscription<Map<int, TorrentInfo>>? _torrentUpdatesSub;

  /// Espera a que el torrent haya descargado [desired] bytes a disco.
  ///
  /// El archivo objetivo tiene prioridad máxima, así que `totalDone` crece
  /// principalmente con esas piezas. Comprobamos también que el fichero en disco
  /// realmente haya crecido y tenga bytes al inicio (evita devolver un archivo
  /// vacío por sparse/checksum). Devolvemos el tiempo utilizado.
  Future<Duration> _waitForPreload(
    LibtorrentFlutter engine,
    int torrentId,
    int desired, {
    Duration timeout = const Duration(seconds: 180),
    String? localPath,
  }) async {
    print('TORRENT_DBG: _waitForPreload desired=$desired bytes localPath=$localPath');
    final start = DateTime.now();
    final deadline = start.add(timeout);
    int lastDone = 0;
    int lastContiguous = -1;
    final stopwatch = Stopwatch()..start();

    while (DateTime.now().isBefore(deadline)) {
      final ti = engine.torrents[torrentId];
      final done = ti?.totalDone ?? 0;

      // Descarga normal (rarest-first): forzamos resume periódicamente para
      // mantener el torrent activo/announceando si libtorrent se pausa o
      // queda en un estado "stalleado". `resumeTorrent` es idempotente y barato.
      if (ti != null) {
        final stalled = ti.isPaused ||
            ti.state == TorrentState.finished ||
            ti.state == TorrentState.seeding;
        if (stalled && done < ti.totalWanted) {
          engine.resumeTorrent(torrentId);
        }
      }

      final elapsed = stopwatch.elapsed;
      // Log cada ~5s
      if ((elapsed.inSeconds % 5 == 0) ||
          (done - lastDone) >= (desired ~/ 4).clamp(1024 * 1024, 50 * 1024 * 1024)) {
        final conn = ti?.numPeers ?? -1;
        // Velocidad derivada de totalDone (la descarga real a disco, no la del
        // servidor HTTP que reportaba 0).
        final rate = elapsed.inSeconds > 0
            ? (done / elapsed.inSeconds).round()
            : 0;
        final totalWanted = ti?.totalWanted ?? 0;
        print('TORRENT_DBG: [preload] done=${done}B / ${desired}B '
            '(${(done / desired * 100).toStringAsFixed(1)}%) '
            'dl=${(rate / 1024).round()}KB/s peers=$conn '
            'state=${ti?.state} pct=${ti != null ? (ti.progress * 100).toStringAsFixed(1) : '?'}% '
            'wanted=${totalWanted}B isPaused=${ti?.isPaused}');
        lastDone = done;
      }

      // Con descarga normal (rarest-first) `totalDone` mezcla piezas de todo el
      // fichero, así que no garantiza que EL INICIO tenga datos. La señal
      // correcta para reproducir es cuántos bytes CONTIGUOS desde el offset 0
      // hay ya escritos en disco (libtorrent deja 0x00 en los huecos sparse).
      // Determinamos la longitud del tramo cabecera contiguo y devolvemos al
      // alcanzar [desired] bytes (o al agotar el timeout).
      try {
        if (localPath != null && localPath.startsWith('file://')) {
          final f = File(localPath.substring('file://'.length));
          final contiguous = _contiguousHeadBytes(f, desired);
          if (contiguous != lastContiguous) {
            print('TORRENT_DBG: [preload] headContiguous=${contiguous}B / ${desired}B');
            lastContiguous = contiguous;
          }
          if (contiguous >= desired) {
            print('TORRENT_DBG: _waitForPreload satisfecho: ${contiguous}B contiguos al inicio');
            return stopwatch.elapsed;
          }
        } else {
          return stopwatch.elapsed;
        }
      } catch (e) {
        print('TORRENT_DBG: _waitForPreload error verificando archivo: $e');
      }

      await Future.delayed(const Duration(milliseconds: 500));
    }
    print('TORRENT_DBG: _waitForPreload TIMEOUT tras ${timeout.inSeconds}s, continúo con lo descargado');
    return stopwatch.elapsed;
  }

  /// Cuenta cuántos bytes CONTIGUOS desde el offset 0 de [f] están ya escritos
  /// en disco (máx. [limit]). libtorrent usa ficheros sparse: las regiones no
  /// descargadas son 0x00, así que recorremos el inicio hasta encontrar un hueco
  /// genuino (una racha de ceros ≥ 64KB, mucho mayor que cualquier racha de CERO
  /// legítima en los primeros bytes de un contenedor de vídeo). Leemos en
  /// bloques para no cargar todo el fichero en memoria.
  int _contiguousHeadBytes(File f, int limit) {
    if (!f.existsSync()) return 0;
    const chunk = 256 * 1024;
    final raf = f.openSync(mode: FileMode.read);
    try {
      int contiguous = 0;
      int zeroRun = 0;
      final buffer = Uint8List(chunk);
      while (contiguous < limit) {
        final toRead = (limit - contiguous) < chunk ? (limit - contiguous) : chunk;
        final n = raf.readIntoSync(buffer, 0, toRead);
        if (n <= 0) break;
        for (int i = 0; i < n; i++) {
          if (buffer[i] == 0) {
            zeroRun++;
            if (zeroRun >= 64 * 1024) {
              // hueco sparse: fin del tramo contiguo descargado
              return contiguous;
            }
          } else {
            zeroRun = 0;
            contiguous++;
          }
        }
        // Fin prematuro de archivo
        if (n < toRead) break;
      }
      return contiguous;
    } finally {
      raf.closeSync();
    }
  }

  /// Mantiene el torrent vivo (reanudando si se pausa o queda en finished/
  /// seeding con datos incompletos) mientras se reproduce el archivo local, y
  /// registra el progreso de descarga a disco.
  void _startKeepAlive(LibtorrentFlutter engine, int torrentId) {
    _keepAliveTimer?.cancel();
    _torrentUpdatesSub?.cancel();
    _torrentUpdatesSub = engine.torrentUpdates.listen((torrents) {
      final t = torrents[torrentId];
      if (t == null) return;
      // Reanuda si está pausado O "finished"/"seeding" pero el fichero no está
      // completo aún (rarest-first puede marcar finished puntualmente).
      final incomplete = t.totalDone < t.totalWanted;
      if (t.isPaused || ((t.state == TorrentState.finished ||
              t.state == TorrentState.seeding) &&
          incomplete)) {
        engine.resumeTorrent(torrentId);
        print('TORRENT_DBG: [keepalive] resume torrentId=$torrentId done=${t.totalDone}/${t.totalWanted}');
      }
    });
    _keepAliveTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      final ti = engine.torrents[torrentId];
      if (ti == null) {
        _keepAliveTimer?.cancel();
        _torrentUpdatesSub?.cancel();
        return;
      }
      final incomplete = ti.totalDone < ti.totalWanted;
      if (ti.isPaused || ((ti.state == TorrentState.finished ||
              ti.state == TorrentState.seeding) &&
          incomplete)) {
        engine.resumeTorrent(torrentId);
      }
      print('TORRENT_DBG: [keepalive] state=${ti.state} progress=${(ti.progress * 100).toStringAsFixed(1)}% '
          'done=${ti.totalDone}/${ti.totalWanted}B '
          'peers=${ti.numPeers} isPaused=${ti.isPaused}');
    });
  }

  void _stopTorrentKeepAlive() {
    _keepAliveTimer?.cancel();
    _keepAliveTimer = null;
    _torrentUpdatesSub?.cancel();
    _torrentUpdatesSub = null;
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
    _stopTorrentKeepAlive();
    if (!_initDone) return;
    try {
      final engine = LibtorrentFlutter.instance;
      engine.stopStream(session.streamId);
      engine.disposeTorrent(session.torrentId);
      print('TORRENT_DBG: stop() completado');
    } catch (_) {}
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
