import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

/// Proxy progresivo estilo Stremio (enginefs/stream-server open source):
/// UNA sola conexión secuencial al origen que va llenando un archivo local,
/// y TODAS las peticiones del reproductor (múltiples rangos en paralelo) se
/// sirven desde ese archivo en disco.
///
/// Por qué existe: algunos orígenes (p.ej. Dropbox con su cookie
/// `uc_session`) atan la descarga a la sesión/conexión. Si cada rango del
/// reproductor abre su propia conexión al origen, las sesiones chocan y el
/// stream muere a los pocos segundos. Con una única descarga secuencial el
/// origen ve un solo cliente sano y el reproductor ve un servidor local
/// rápido con soporte total de rangos. Arranque en segundos, sin esperar la
/// descarga completa.
class ProgressiveFileProxy {
  ProgressiveFileProxy._();
  static final ProgressiveFileProxy instance = ProgressiveFileProxy._();

  static const String _kDirName = 'pgcache';
  static const Duration _kPollInterval = Duration(milliseconds: 250);
  static const Duration _kWaitForBytesTimeout = Duration(seconds: 30);
  static const Duration _kStallTimeout = Duration(seconds: 20);
  // Paciencia del hold-open sirviendo (bomba): se renueva con cada chunk.
  // Debe superar los baches del origen para no cortarle el input a FFmpeg
  // (un corte = EOF = fMP4 truncado = EOS prematuro en el reproductor).
  // En fatal se aborta de inmediato (ver bomba).
  static const Duration _kPumpIdleTimeout = Duration(seconds: 180);
  static const Duration _kIdleEvictAfter = Duration(minutes: 30);
  // Tope blando del caché en disco (archivos completos se reutilizan).
  static const int _kMaxCacheBytes = 1500 * 1024 * 1024;
  // Cola del archivo que se trae PRIMERO (ahí vive el índice moov del MP4).
  // Sin ella el reproductor no puede mapear minuto→byte y los seeks lejanos
  // fallan aunque el resto ya haya bajado. 5 MB cubren el moov típico.
  static const int _kTailSize = 5 * 1024 * 1024;

  final Map<String, _PgEntry> _entries = {}; // token → entry
  final Map<String, String> _urlToToken = {}; // urlKey → token

  static const _kExtToContentType = {
    'mp4': 'video/mp4',
    'mkv': 'video/x-matroska',
    'webm': 'video/webm',
    'avi': 'video/x-msvideo',
    'mov': 'video/quicktime',
  };

  /// Registra una URL y devuelve el token para servirla en `/pg/<token>.<ext>`.
  /// La descarga NO empieza aquí: arranca con la primera petición (o con
  /// [prefetch], que calienta los primeros bytes para arranque instantáneo).
  Future<String> register(
    String url,
    Map<String, String> headers, {
    String ext = 'mp4',
    bool prefetch = false,
  }) async {
    final urlKey = '$url|${headers.toString()}';
    // Borrado agresivo: aunque sea el MISMO enlace ya en disco, se elimina
    // y se empieza limpio. El archivo previo puede traer bytes mezclados o
    // truncos de sesiones con reinicios del origen, y reutilizarlo recicla
    // el error (pantalla negra tras seek). Se prefiere re-descargar.
    final existingToken = _urlToToken[urlKey];
    if (existingToken != null) {
      final existing = _entries.remove(existingToken);
      _urlToToken.remove(urlKey);
      if (existing != null) {
        existing.dead = true;
        try {
          final mb = (await existing.localSize()) / 1048576;
          await existing.deleteFiles();
          print('[PG] Archivo previo eliminado '
              '(${mb.toStringAsFixed(1)} MB) para reapertura limpia');
        } catch (_) {}
      }
    }
    await _evictIdle();
    final dir = await _cacheDir();
    final token =
        '${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}${(url.hashCode & 0xffff).toRadixString(36)}';
    final entry = _PgEntry(
      token: token,
      url: url,
      headers: Map<String, String>.from(headers),
      ext: ext,
      file: File('${dir.path}/$token.$ext'),
      tailFile: File('${dir.path}/$token.tail.$ext'),
    );
    _entries[token] = entry;
    _urlToToken[urlKey] = token;
    // Limpieza agresiva: al abrir OTRO enlace se borra lo anterior para no
    // saturar el almacenamiento. Solo entra lo abandonado (sin uso
    // reciente); lo que se sigue reproduciendo (PiP, reanudación del mismo
    // enlace) tiene lastUse fresco y se conserva.
    await _evictOthers(token);
    if (prefetch) _ensureFetch(entry);
    return token;
  }

  /// Calienta la descarga sin bloquear (para que al abrir WVC ya haya bytes).
  void prefetch(String token) {
    final entry = _entries[token];
    if (entry != null && !entry.dead) _ensureFetch(entry);
  }

  /// Libera una entrada al cerrar el reproductor: detiene su descarga y
  /// borra sus archivos de inmediato (no espera a las ventanas de evicción).
  Future<void> release(String token) async {
    final e = _entries.remove(token);
    _urlToToken.removeWhere((_, t) => t == token);
    if (e == null) return;
    e.dead = true;
    await e.deleteFiles();
    print('[PG] Entrada $token liberada al cerrar reproductor');
  }

  _PgEntry? get(String token) => _entries[token];

  /// Sirve una petición HTTP con soporte total de rangos sobre el archivo
  /// creciente. Si el rango pedido aún no se descargó, espera hasta
  /// [_kWaitForBytesTimeout] (el reproductor reintenta si falla).
  Future<void> handle(HttpRequest request, _PgEntry entry) async {
    entry.lastUse = DateTime.now();
    _ensureFetch(entry);
    try {
      // Esperar cabeceras del origen (tamaño total) para responder rangos
      // con Content-Range exacto.
      final total = await _waitForTotal(entry);
      if (total == null || total <= 0) {
        request.response.statusCode = HttpStatus.badGateway;
        await request.response.close();
        return;
      }

      final rangeHeader = request.headers.value('range');
      int start = 0;
      int end = total - 1;
      if (rangeHeader != null) {
        final parsed = _parseRange(rangeHeader, total);
        if (parsed == null) {
          request.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
          request.response.headers.set('Content-Range', 'bytes */$total');
          await request.response.close();
          return;
        }
        start = parsed.$1;
        end = parsed.$2;
      }

      // Atajo de índice: si el rango cae dentro de la cola ya traída (moov),
      // servirlo directo del sidecar sin esperar la descarga secuencial.
      if (await _serveFromTail(request, entry, total, start, end)) return;
      // Esperar solo el byte INICIAL: lo pedido se sirve en hold-open
      // emitiendo según descarga (ver bomba abajo). Esperar el fin
      // explícito colgaba 30 s los rangos que llegan hasta EOF (p.ej. la
      // cola/moov) aunque sus primeros bytes ya estaban listos.
      final waitBegin = DateTime.now();
      final ok = await _waitForBytes(entry, start);
      final waitedMs = DateTime.now().difference(waitBegin).inMilliseconds;
      // Diagnóstico de layout: si un rango espera segundos, esa región va
      // por detrás de la descarga (pistas no intercaladas: una pista pide
      // lejos mientras la secuencial aún no llega).
      if (!ok || waitedMs > 3000) {
        final have = await entry.localSize();
        print('[PG] rango $start-$end de $total: esperó ${waitedMs}ms, '
            'hay $have bytes -> ${ok ? "OK" : (entry.fatal ? "FATAL" : "TIMEOUT")}');
      }
      if (!ok) {
        if (entry.fatal) {
          print('[PG] 504: rango $start- más allá de lo descargado y la '
              'descarga está FATAL (link expirado?).');
        }
        request.response.statusCode = HttpStatus.gatewayTimeout;
        await request.response.close();
        return;
      }
      // Recalcular fin por si la descarga terminó antes (end ya estaba
      // limitado al total, solo re-leer lo disponible).
      final available = await entry.localSize();
      if (available <= start) {
        request.response.statusCode = HttpStatus.gatewayTimeout;
        await request.response.close();
        return;
      }
      // NO recortar `end` a lo disponible: se mantiene la conexión abierta
      // emitiendo bytes según los descarga el origen (streaming progresivo
      // real). Recortarla hacía que el reproductor creyera que no había más
      // datos: arrancaba el audio y el video quedaba tardío para siempre
      // (pantalla negra). Content-Length declara el rango completo pedido.
      request.response.statusCode = HttpStatus.partialContent;
      request.response.headers.contentType = ContentType.parse(entry.contentType);
      request.response.headers.set('Accept-Ranges', 'bytes');
      request.response.headers.set(
          'Content-Range', 'bytes $start-$end/$total');
      request.response.headers.set(
          'Content-Length', '${end - start + 1}');
      request.response.headers.set('Access-Control-Allow-Origin', '*');
      request.response.headers.set('Connection', 'close');

      // Bombear del archivo con espera: si el reproductor pide más rápido
      // de lo que descarga el origen, se pausa hasta que lleguen bytes.
      // El deadline es de INACTIVIDAD LARGA (se renueva con cada chunk): una
      // transferencia sana nunca se corta. Es generoso a propósito: cortar
      // temprano le da EOF a FFmpeg (fMP4 truncado = EOS prematuro). En
      // fatal sí se aborta de inmediato.
      var clientGone = false;
      unawaited(request.response.done.then((_) {
        clientGone = true;
      }).catchError((_) {
        clientGone = true;
      }));
      final raf = await entry.file.open(mode: FileMode.read);
      try {
        var pos = start;
        var deadline =
            DateTime.now().add(_kPumpIdleTimeout);
        const chunk = 256 * 1024;
        final gen = entry.generation;
        while (pos <= end) {
          // Archivo reiniciado bajo nuestros pies (truncate): abortar para
          // no servir mezcla de bytes viejos con nuevos; el reproductor
          // reintenta el rango y recibe bytes consistentes.
          if (gen != entry.generation || clientGone || entry.fatal) break;
          final have = await entry.localSize();
          if (pos >= have) {
            if (entry.done) break;
            if (DateTime.now().isAfter(deadline)) break;
            await Future.delayed(_kPollInterval);
            continue;
          }
          var toRead = have - pos;
          final remaining = end - pos + 1;
          if (toRead > remaining) toRead = remaining;
          if (toRead > chunk) toRead = chunk;
          await raf.setPosition(pos);
          final data = await raf.read(toRead);
          if (data.isEmpty) {
            await Future.delayed(_kPollInterval);
            continue;
          }
          request.response.add(data);
          pos += data.length;
          deadline = DateTime.now().add(_kPumpIdleTimeout);
        }
      } finally {
        await raf.close();
      }
      await request.response.close();
    } catch (_) {
      try {
        request.response.statusCode = HttpStatus.badGateway;
        await request.response.close();
      } catch (_) {}
    }
  }

  /// Si [start..end] cae íntegro dentro de la cola ya traída (índice moov),
  /// lo sirve del sidecar al instante. Devuelve true si lo sirvió.
  Future<bool> _serveFromTail(
    HttpRequest request,
    _PgEntry entry,
    int total,
    int start,
    int end,
  ) async {
    try {
      if (!entry.tailReady) return false;
      final tailStart = total - entry.tailSize;
      if (tailStart < 0 || start < tailStart || end >= total) return false;
      final raf = await entry.tailFile.open(mode: FileMode.read);
      try {
        await raf.setPosition(start - tailStart);
        final data = await raf.read(end - start + 1);
        if (data.length != end - start + 1) return false;
        request.response.statusCode = HttpStatus.partialContent;
        request.response.headers.contentType =
            ContentType.parse(entry.contentType);
        request.response.headers.set('Accept-Ranges', 'bytes');
        request.response.headers
            .set('Content-Range', 'bytes $start-$end/$total');
        request.response.headers
            .set('Content-Length', '${end - start + 1}');
        request.response.headers.set('Access-Control-Allow-Origin', '*');
        request.response.headers.set('Connection', 'close');
        request.response.add(data);
        await request.response.close();
        return true;
      } finally {
        await raf.close();
      }
    } catch (_) {
      return false;
    }
  }

  // --- Descarga secuencial única ---

  void _ensureFetch(_PgEntry entry) {
    if (entry.dead) return;
    // Probe de cabeceras primero (total temprano para la cola).
    if (!entry.totalProbed) {
      if (entry.probing) return;
      entry.probing = true;
      _probeTotal(entry).whenComplete(() {
        entry.probing = false;
        entry.totalProbed = true;
        if (!entry.dead) _ensureFetch(entry);
      });
      return;
    }
    // Un solo bucle planificador: UNA sola conexión al origen a la vez
    // (probe → cola → chunks). Sin competencia por slots del origen.
    if (!entry.fetching && !entry.done && !entry.fatal) {
      entry.fetching = true;
      _fetchScheduler(entry);
    }
  }

  /// Lee SOLO las cabeceras del origen (tamaño total) y cierra sin bajar el
  /// cuerpo. Así la cola puede pedirse antes de abrir la descarga grande.
  Future<void> _probeTotal(_PgEntry entry) async {
    final client = http.Client();
    try {
      final req = http.Request('GET', Uri.parse(entry.url));
      req.headers['User-Agent'] =
          'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Mobile Safari/537.36';
      req.headers['Accept'] = '*/*';
      req.headers['Range'] = 'bytes=0-0';
      req.followRedirects = true;
      final res =
          await client.send(req).timeout(const Duration(seconds: 15));
      // Con Range 0-0 el total viene en Content-Range aunque el cuerpo sea 1 byte.
      final cr = res.headers['content-range'];
      if (cr != null && cr.contains('/')) {
        entry.totalBytes ??= int.tryParse(cr.split('/').last);
      }
      entry.totalBytes ??= int.tryParse(res.headers['content-length'] ?? '');
      final ct = res.headers['content-type'];
      if (ct != null && ct.toLowerCase().startsWith('video/')) {
        entry.contentType = ct.split(';').first.trim();
      }
      print('[PG] Probe: total=${entry.totalBytes} type=${entry.contentType}');
    } catch (e) {
      print('[PG] Probe falló ($e), se intentará directo');
    } finally {
      client.close();
    }
  }

  /// Trae la cola del archivo (índice moov). El planificador la pide primero
  /// y luego con backoff; NUNCA en paralelo con otra petición (una sola
  /// conexión al origen a la vez).
  Future<bool> _fetchTailOnce(
    _PgEntry entry, {
    Duration sendTimeout = const Duration(seconds: 30),
    Duration stallTimeout = _kStallTimeout,
  }) async {
    try {
      final total = entry.totalBytes;
      if (entry.dead) return false;
      if (total == null || total <= _kTailSize) return false;
      final tailStart = total - _kTailSize;
      final client = http.Client();
      try {
        final req = http.Request('GET', Uri.parse(entry.url));
        req.headers['User-Agent'] =
            'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Mobile Safari/537.36';
        req.headers['Accept'] = '*/*';
        req.headers['Range'] = 'bytes=$tailStart-';
        req.followRedirects = true;
        final res = await client.send(req).timeout(sendTimeout);
        if (res.statusCode != HttpStatus.partialContent) return false;
        final sink = entry.tailFile.openWrite(mode: FileMode.write);
        try {
          await for (final data in res.stream.timeout(stallTimeout,
              onTimeout: (s) =>
                  s.addError(TimeoutException('cola estancada')))) {
            if (entry.dead) return false;
            sink.add(data);
          }
          await sink.flush();
        } finally {
          await sink.close();
        }
        final got = await entry.tailFile.length();
        if (got == _kTailSize) {
          entry.tailSize = _kTailSize;
          entry.tailReady = true;
          print('[PG] Índice (últimos ${_kTailSize ~/ 1048576} MB) listo, '
              'seeks lejanos habilitados');
          return true;
        }
        return false;
      } finally {
        client.close();
      }
    } catch (_) {
      return false;
    }
  }

  /// Planificador con UNA sola conexión al origen a la vez: primero la cola
  /// (índice moov, con timeout corto en la primera ronda para no frenar el
  /// arranque), luego chunks secuenciales de 4 MB con resume. La cola se
  /// reintenta con backoff mientras falte. Los fallos se resetean con cada
  /// éxito; fatal tras 6 seguidos.
  static const int _kChunkSize = 4 * 1024 * 1024;

  Future<void> _fetchScheduler(_PgEntry entry) async {
    entry.fetchStartedAt ??= DateTime.now();
    var rounds = 0;
    try {
      while (!entry.done && !entry.fatal && !entry.dead) {
        rounds++;
        // 1) Cola pendiente: primera ronda con timeout corto, luego backoff.
        final total = entry.totalBytes;
        final needTail = !entry.tailReady &&
            total != null &&
            total > _kTailSize &&
            (entry.lastTailTry == null ||
                DateTime.now().difference(entry.lastTailTry!) >
                    const Duration(seconds: 60));
        if (needTail) {
          entry.lastTailTry = DateTime.now();
          final quick = rounds == 1;
          final okTail = await _fetchTailOnce(
            entry,
            sendTimeout:
                quick ? const Duration(seconds: 12) : const Duration(seconds: 30),
            stallTimeout:
                quick ? const Duration(seconds: 8) : _kStallTimeout,
          );
          if (okTail) {
            entry.failures = 0;
            continue;
          }
        }
        // 2) Chunk secuencial con resume.
        if (await _fetchChunk(entry)) {
          entry.failures = 0;
          if (entry.done) {
            final mb = (await entry.localSize()) / 1048576;
            final secs = DateTime.now()
                .difference(entry.fetchStartedAt!)
                .inSeconds;
            print('[PG] Descarga completa: ${mb.toStringAsFixed(1)} MB '
                'en ${secs}s (${entry.url})');
            break;
          }
          continue;
        }
        entry.failures++;
        if (entry.failures >= 6) {
          entry.fatal = true;
          print('[PG] FATAL tras ${entry.failures} fallos '
              '(${entry.url}). Los rangos más allá de lo descargado '
              'devolverán 504.');
          break;
        }
        await Future.delayed(const Duration(seconds: 2));
      }
    } finally {
      entry.fetching = false;
    }
  }

  /// Descarga el siguiente chunk (4 MB) con resume. Devuelve true si avanzó
  /// o completó. Aprende el total de las cabeceras si aún no se conoce.
  Future<bool> _fetchChunk(_PgEntry entry) async {
    final client = http.Client();
    try {
      final from = await entry.localSize();
      entry.memBytes = from;
      final knownTotal = entry.totalBytes;
      if (knownTotal != null && from >= knownTotal) {
        entry.done = true;
        return true;
      }
      final req = http.Request('GET', Uri.parse(entry.url));
      // UNA sola sesión estable: cabeceras mínimas, sin rotar cookies entre
      // peticiones (eso es lo que rompía los orígenes con sesión).
      req.headers['User-Agent'] =
          'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Mobile Safari/537.36';
      req.headers['Accept'] = '*/*';
      entry.headers.forEach((k, v) {
        if (k.toLowerCase() != 'cookie' &&
            k.toLowerCase() != 'range' &&
            k.toLowerCase() != 'user-agent') {
          req.headers[k] = v;
        }
      });
      var ranged = true;
      if (!entry.ignoreRange && (from > 0 || knownTotal != null)) {
        final end = knownTotal != null
            ? (from + _kChunkSize - 1).clamp(from, knownTotal - 1)
            : (from + _kChunkSize - 1);
        req.headers['Range'] = 'bytes=$from-$end';
      } else if (!entry.ignoreRange && from == 0 && knownTotal == null) {
        // Primer chunk sin total: rango explícito para descubrirlo por
        // Content-Range sin pedir el archivo entero.
        req.headers['Range'] = 'bytes=0-${_kChunkSize - 1}';
      } else {
        // Origen que ignora rangos: GET completo clásico con resume imposible.
        ranged = false;
        if (from > 0) {
          await entry.file.writeAsBytes([], mode: FileMode.write);
        }
      }
      req.followRedirects = true;

      final res = await client.send(req).timeout(const Duration(seconds: 30));
      if (res.statusCode == 401 || res.statusCode == 403) {
        // Token del enlace muerto: reintentar es inútil.
        entry.fatal = true;
        print('[PG] FATAL: origen responde ${res.statusCode} '
            '(link expirado?) (${entry.url})');
        return false;
      }
      if (res.statusCode == 200 && ranged && from > 0) {
        // El origen ignoró el resume. ANTES de truncar hay que verificar que
        // lo que viene es video real: una página de error (200 text/html)
        // truncaría un archivo sano y mezclaría basura bajo los offsets que
        // el reproductor ya está leyendo (pantalla negra tras seek). Con
        // generación nueva los lectores en curso abortan en vez de mezclar.
        final ct200 = (res.headers['content-type'] ?? '').toLowerCase();
        final len200 = int.tryParse(res.headers['content-length'] ?? '');
        final looksVideo = ct200.startsWith('video/') &&
            (len200 == null || len200 > 1024 * 1024);
        if (!looksVideo) {
          print('[PG] 200 inesperado no-video ($ct200 len=$len200), '
              'se descarta SIN truncar');
          return false;
        }
        entry.ignoreRange = true;
        entry.generation++;
        print('[PG] TRUNCATE gen=${entry.generation}: origen reinició con '
            '200, archivo reiniciado');
        await entry.file.writeAsBytes([], mode: FileMode.write);
        return false;
      }
      if (res.statusCode != 200 && res.statusCode != 206) {
        print('[PG] Chunk fallido (${entry.failures + 1}): '
            'status=${res.statusCode} (${entry.url})');
        return false;
      }
      if (res.statusCode == 206) {
        // Verificar que el tramo es el pedido (origen confundido = basura).
        final cr = res.headers['content-range'] ?? '';
        final m = RegExp(r'bytes\s+(\d+)-').firstMatch(cr);
        final crStart = m != null ? int.tryParse(m.group(1) ?? '') : null;
        if (crStart != null && crStart != from) {
          print('[PG] Chunk con offset inesperado ($crStart != $from), '
              'se reintenta');
          return false;
        }
      }
      // Aprender total y tipo de las cabeceras.
      if (entry.totalBytes == null) {
        final cr = res.headers['content-range'];
        final crTotal = cr != null && cr.contains('/')
            ? int.tryParse(cr.split('/').last)
            : null;
        entry.totalBytes = crTotal ??
            int.tryParse(res.headers['content-length'] ?? '');
        final ct = res.headers['content-type'];
        if (ct != null && ct.toLowerCase().startsWith('video/')) {
          entry.contentType = ct.split(';').first.trim();
        }
      }

      var got = 0;
      final sink = entry.file.openWrite(mode: FileMode.append);
      try {
        // Vigilante de estancamiento: aborta y el planificador reintenta
        // con resume (el reproductor sigue servido desde disco).
        final watched = res.stream.timeout(
          ProgressiveFileProxy._kStallTimeout,
          onTimeout: (sink) => sink.addError(TimeoutException(
              'origen estancado', ProgressiveFileProxy._kStallTimeout)),
        );
        await for (final data in watched) {
          if (entry.dead) return false;
          sink.add(data);
          await sink.flush();
          got += data.length;
          entry.memBytes += data.length;
          if (entry.memBytes - entry.lastLogBytes >= 100 * 1024 * 1024) {
            entry.lastLogBytes = entry.memBytes;
            final total = entry.totalBytes;
            final pct = total != null && total > 0
                ? '(${(entry.memBytes * 100 ~/ total)}%)'
                : '';
            print('[PG] Descargando... '
                '${(entry.memBytes / 1048576).toStringAsFixed(0)} MB $pct');
          }
          // Chunk completo: soltar la conexión aunque el origen mande más
          // (el próximo round pide el siguiente tramo).
          if (!entry.ignoreRange && got >= _kChunkSize) break;
        }
      } finally {
        await sink.close();
      }
      if (got == 0) return false;
      // Verificar compleción por tamaño.
      final total = entry.totalBytes;
      final have = await entry.localSize();
      if (total != null && have >= total) {
        entry.done = true;
      }
      return true;
    } catch (e) {
      print('[PG] Chunk fallido (${entry.failures + 1}): $e '
          '(${entry.url})');
      return false;
    } finally {
      client.close();
    }
  }

  Future<int?> _waitForTotal(_PgEntry entry) async {
    final deadline = DateTime.now().add(const Duration(seconds: 15));
    while (DateTime.now().isBefore(deadline)) {
      if (entry.totalBytes != null) return entry.totalBytes;
      if (entry.fatal) return null;
      await Future.delayed(_kPollInterval);
    }
    return entry.totalBytes;
  }

  /// Espera hasta que haya al menos 1 byte más allá de [pos] en disco.
  Future<bool> _waitForBytes(_PgEntry entry, int pos) async {
    final deadline = DateTime.now().add(_kWaitForBytesTimeout);
    while (DateTime.now().isBefore(deadline)) {
      if (entry.fatal) return false;
      if (await entry.localSize() > pos) return true;
      if (entry.done) return false;
      await Future.delayed(_kPollInterval);
    }
    return await entry.localSize() > pos;
  }

  (int, int)? _parseRange(String header, int total) {
    final m = RegExp(r'bytes=(\d*)-(\d*)').firstMatch(header.trim());
    if (m == null) return null;
    final a = m.group(1) ?? '';
    final b = m.group(2) ?? '';
    if (a.isEmpty) {
      // Sufijo: últimos N bytes.
      final n = int.tryParse(b);
      if (n == null || n <= 0) return null;
      if (n >= total) return (0, total - 1);
      return (total - n, total - 1);
    }
    final start = int.tryParse(a);
    if (start == null || start >= total) return null;
    var end = total - 1;
    if (b.isNotEmpty) {
      final e = int.tryParse(b);
      if (e == null) return null;
      end = e > total - 1 ? total - 1 : e;
    }
    if (end < start) return null;
    return (start, end);
  }

  Future<Directory> _cacheDir() async {
    final tmp = await getTemporaryDirectory();
    final dir = Directory('${tmp.path}/$_kDirName');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// Borra los archivos de OTROS enlaces abandonados (sin uso en los
  /// últimos 60 s). Lo que se sigue reproduciendo tiene lastUse fresco y se
  /// conserva. También detiene sus descargas en curso (ven `dead` y paran).
  Future<void> _evictOthers(String keepToken) async {
    try {
      final now = DateTime.now();
      var freed = 0;
      for (final e in _entries.values) {
        if (e.token == keepToken || e.dead) continue;
        if (now.difference(e.lastUse) >
            const Duration(seconds: 60)) {
          e.dead = true;
          try {
            freed += await e.file.length();
          } catch (_) {}
          await e.deleteFiles();
        }
      }
      _entries.removeWhere((_, e) => e.dead);
      _urlToToken.removeWhere((_, t) => !_entries.containsKey(t));
      if (freed > 0) {
        print('[PG] Limpieza al abrir otro enlace: '
            '${(freed / 1048576).toStringAsFixed(1)} MB liberados');
      }
    } catch (_) {}
  }

  Future<void> _evictIdle() async {
    try {
      final now = DateTime.now();
      int total = 0;
      final files = <FileSystemEntity>[];
      for (final e in _entries.values) {
        if (now.difference(e.lastUse) > _kIdleEvictAfter) {
          e.dead = true;
          await e.deleteFiles();
        } else {
          try {
            total += await e.file.length();
            files.add(e.file);
          } catch (_) {}
        }
      }
      _entries.removeWhere((_, e) => e.dead);
      _urlToToken.removeWhere((_, t) => !_entries.containsKey(t));
      if (total <= _kMaxCacheBytes) return;
      // Podar archivos huérfanos del caché hasta volver al tope.
      final dir = await _cacheDir();
      final all = await dir
          .list()
          .where((f) => f is File)
          .cast<File>()
          .toList();
      all.sort((a, b) => a.lastModifiedSync().compareTo(b.lastModifiedSync()));
      for (final f in all) {
        if (total <= _kMaxCacheBytes) break;
        if (_entries.values.any((e) => e.file.path == f.path)) continue;
        try {
          total -= await f.length();
          await f.delete();
        } catch (_) {}
      }
    } catch (_) {}
  }
}

class _PgEntry {
  final String token;
  final String url;
  final Map<String, String> headers;
  final String ext;
  final File file;
  final File tailFile;
  int? totalBytes;
  String contentType;
  bool fetching = false;
  bool done = false;
  bool fatal = false;
  bool dead = false;
  int failures = 0;
  DateTime? fetchStartedAt;
  // Orden de arranque: probe de cabeceras antes que descarga y cola.
  bool probing = false;
  bool totalProbed = false;
  // Fase de cola: último intento (backoff de 60 s en el planificador).
  DateTime? lastTailTry;
  // Origen que ignora rangos: se descarga completo clásico.
  bool ignoreRange = false;
  // Generación del archivo: cada truncate la sube; los lectores (pump) con
  // generación vieja abortan en vez de servir bytes mezclados.
  int generation = 0;
  // Contadores en memoria para log de progreso (evitan stat por chunk).
  int memBytes = 0;
  int lastLogBytes = 0;
  // Cola del archivo (índice) traída por adelantado.
  bool tailReady = false;
  int tailSize = 0;
  DateTime lastUse = DateTime.now();

  _PgEntry({
    required this.token,
    required this.url,
    required this.headers,
    required this.ext,
    required this.file,
    required this.tailFile,
  }) : contentType = ProgressiveFileProxy._kExtToContentType[ext] ?? 'video/mp4';

  Future<int> localSize() async {
    try {
      return await file.length();
    } catch (_) {
      return 0;
    }
  }

  Future<void> deleteFiles() async {
    try {
      await file.delete();
    } catch (_) {}
    try {
      await tailFile.delete();
    } catch (_) {}
  }
}
