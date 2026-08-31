import 'dart:async';

import 'package:libtorrent_flutter/libtorrent_flutter.dart';

/// Resultado de iniciar la reproducción de un torrent vía libtorrent.
class TorrentPlaybackSession {
  final int torrentId;
  final int streamId;
  final String url;
  final String name;

  const TorrentPlaybackSession({
    required this.torrentId,
    required this.streamId,
    required this.url,
    required this.name,
  });
}

/// Abstracción sobre `libtorrent_flutter` para reproducir torrents sin debrid.
///
/// Añade un magnet por su infohash, espera a tener metadatos, elige el archivo
/// correcto y arranca el servidor HTTP local que devuelve una URL compatible
/// con el reproductor (`video_player`), gracias a que soporta HTTP range.
class TorrentStreamingService {
  TorrentStreamingService._();
  static final TorrentStreamingService instance = TorrentStreamingService._();

  bool _initStarted = false;
  bool _initDone = false;
  Completer<void>? _initCompleter;

  Future<void> _ensureInit() async {
    if (_initDone) return;
    if (_initStarted) {
      await _initCompleter!.future;
      return;
    }
    _initStarted = true;
    _initCompleter = Completer<void>();
    try {
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

  /// Inicia la reproducción de un torrent. Devuelve la URL HTTP local lista
  /// para pasar al reproductor.
  Future<TorrentPlaybackSession> start({
    required String infoHash,
    int? fileIndex,
    Duration metadataTimeout = const Duration(seconds: 120),
  }) async {
    print('TORRENT_DBG: start() infohash=$infoHash fileIdx=$fileIndex');
    await _ensureInit();
    final engine = LibtorrentFlutter.instance;

    final magnet = _magnet(infoHash);
    // streamOnly = false para que el torrent descargue todos los archivos y continúe sembrando (seeding)
    // Esto mantiene el torrent en estado "downloading/seeding" y el servidor HTTP activo
    final torrentId = engine.addMagnet(magnet, null, false);
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
      print('TORRENT_DBG: ▶ TARGET FILE seleccionado: fileIndex=$target ${target >= 0 && target < files.length ? files[target].name : '(out of range)'} '
          '${target >= 0 && target < files.length ? '| path=${files[target].path} size=${files[target].size} streamable=${files[target].isStreamable}' : ''} (solicitado=$fileIndex)');

      // Prioritize the target file
      if (target >= 0 && target < files.length) {
        // Set target file to highest priority (7), others to low priority (1) instead of 0
      // This keeps the torrent in "downloading" state instead of finishing and pausing
      final priorities = List<int>.filled(files.length, 1);
      priorities[target] = 7;
      engine.setFilePriorities(torrentId, priorities);
      print('TORRENT_DBG: setFilePriorities for torrentId=$torrentId target=$target (others=1)');
      }

      // Ensure torrent is resumed (might have auto-paused after finishing)
      final torrentInfo = engine.torrents[torrentId];
      if (torrentInfo != null && torrentInfo.isPaused) {
        engine.resumeTorrent(torrentId);
        print('TORRENT_DBG: resumed paused torrentId=$torrentId');
      }

      final stream = engine.startStream(torrentId, fileIndex: target);
      if (stream.id <= 0 || stream.url.isEmpty) {
        engine.disposeTorrent(torrentId);
        throw Exception('No se pudo iniciar el stream del torrent.');
      }

      // Mantener el torrent activo para que el servidor HTTP siga sirviendo
      engine.resumeTorrent(torrentId);
      print('TORRENT_DBG: resumed torrent after startStream torrentId=$torrentId');

      // Configurar cache para buffering agresivo (sin preloadStream que crashea)
      engine.setCacheSettings(
        stream.id,
        capacity: 512 * 1024 * 1024,
        readAheadPct: 95,
        connectionsLimit: 80,
      );

      // Esperar a que el stream esté activo antes de devolver la sesión
      await _waitForStreamReady(engine, stream.id, timeout: const Duration(seconds: 30));

      final session = TorrentPlaybackSession(
        torrentId: torrentId,
        streamId: stream.id,
        url: stream.url,
        name: stream.url,
      );
      _startTorrentKeepAlive(engine, torrentId, stream.id);
      return session;
    } catch (_) {
      print('TORRENT_DBG: start() threw, disposing torrentId=$torrentId');
      engine.disposeTorrent(torrentId);
      rethrow;
    }
  }

  Timer? _keepAliveTimer;
  StreamSubscription<Map<int, TorrentInfo>>? _torrentUpdatesSub;

  Future<void> _waitForStreamReady(
    LibtorrentFlutter engine,
    int streamId, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    print('TORRENT_DBG: waiting for stream $streamId to become active...');
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final stream = engine.streams[streamId];
      if (stream != null && stream.isActive) {
        print('TORRENT_DBG: stream ready, state=${stream.streamState} fileSize=${stream.fileSize} '
            'url=${stream.url} fileIndex=${stream.fileIndex} buffer=${stream.bufferSeconds}s');
        return;
      }
      await Future.delayed(const Duration(milliseconds: 500));
    }
    print('TORRENT_DBG: stream wait timed out, continuing anyway');
  }

  void _startTorrentKeepAlive(LibtorrentFlutter engine, int torrentId, int streamId) {
    _keepAliveTimer?.cancel();
    _torrentUpdatesSub?.cancel();
    // Log del estado del torrent en cada actualización para poder DEPURAR
    // por qué se pausa / se queda sin datos. Además reanuda SOLO si el torrent
    // terminó de descargar (finished) y quedó pausado, que es cuando el servidor
    // HTTP deja de servir y cierra el socket que ExoPlayer está leyendo.
    _torrentUpdatesSub = engine.torrentUpdates.listen((torrents) {
      final t = torrents[torrentId];
      if (t == null) return;
      print('TORRENT_DBG: [upd] state=${t.state} paused=${t.isPaused} finished=${t.isFinished} '
          'progress=${(t.progress * 100).toStringAsFixed(1)}% '
          'dl=${t.downloadRate ~/ 1024}KB/s up=${t.uploadRate ~/ 1024}KB/s '
          'peers=${t.numPeers} seeds=${t.numSeeds} done=${t.totalDone}B wanted=${t.totalWanted}B');
      // Reanudar INMEDIATAMENTE cuando el torrent termina para que el servidor HTTP siga sirviendo
      if (t.isFinished && t.isPaused) {
        engine.resumeTorrent(torrentId);
        print('TORRENT_DBG: ▶ resume porque finished+paused torrentId=$torrentId');
      }
    });
    _keepAliveTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      final torrentInfo = engine.torrents[torrentId];
      final streamInfo = engine.streams[streamId];
      if (torrentInfo == null || streamInfo == null || !streamInfo.isActive) {
        // Stream ya no activo, intentar reanudar torrent
        if (torrentInfo != null && (torrentInfo.isPaused || torrentInfo.isFinished)) {
          engine.resumeTorrent(torrentId);
          print('TORRENT_DBG: keep-alive resuming torrent (stream inactive) torrentId=$torrentId state=${torrentInfo.state}');
        }
        _keepAliveTimer?.cancel();
        _torrentUpdatesSub?.cancel();
        return;
      }
      // Reanudar solo cuando terminó y se pausó (servidor dejó de servir)
      if (torrentInfo.isFinished && torrentInfo.isPaused) {
        engine.resumeTorrent(torrentId);
        print('TORRENT_DBG: keep-alive resume finished+paused torrentId=$torrentId');
      }
      print('TORRENT_DBG: [timer] streamState=${streamInfo.streamState} buffer=${streamInfo.bufferSeconds.toStringAsFixed(1)}s '
          'readHead=${streamInfo.readHead}/${streamInfo.fileSize} peers=${streamInfo.activePeers} '
          'dl=${streamInfo.downloadRate ~/ 1024}KB/s bufpcs=${streamInfo.bufferPieces}');
      // Refrescar configuración de cache
      try {
        engine.setCacheSettings(
          streamId,
          capacity: 512 * 1024 * 1024,
          readAheadPct: 95,
          connectionsLimit: 80,
        );
      } catch (_) {}
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
