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
  static const Duration _kIdleEvictAfter = Duration(minutes: 30);
  // Tope blando del caché en disco (archivos completos se reutilizan).
  static const int _kMaxCacheBytes = 1500 * 1024 * 1024;

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
    final existingToken = _urlToToken[urlKey];
    if (existingToken != null) {
      final existing = _entries[existingToken];
      if (existing != null && !existing.dead) {
        existing.lastUse = DateTime.now();
        await _evictOthers(existingToken);
        if (prefetch) _ensureFetch(existing);
        return existingToken;
      }
      _urlToToken.remove(urlKey);
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
      // Rango abierto (bytes=N-): NO esperar el archivo completo, servir lo
      // disponible y el reproductor pide más (arranque en segundos).
      bool openEnded = true;
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
        openEnded = RegExp(r'bytes=\d+\s*-\s*$')
            .hasMatch(rangeHeader.trim());
      }

      // Esperar a que existan bytes para servir: en rango explícito hasta
      // el fin pedido; en rango abierto basta con pasar el inicio (luego se
      // recorta a lo disponible y el reproductor pide más).
      final waitTarget = openEnded ? start : end;
      final ok = await _waitForBytes(entry, waitTarget);
      if (!ok) {
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
      if (end >= available) end = available - 1;

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
      // de lo que descarga el origen, se pausa hasta que lleguen bytes (o
      // hasta el timeout), en vez de cerrar el tramo.
      final raf = await entry.file.open(mode: FileMode.read);
      try {
        var pos = start;
        final deadline =
            DateTime.now().add(_kWaitForBytesTimeout);
        const chunk = 256 * 1024;
        while (pos <= end) {
          final have = await entry.localSize();
          if (pos >= have) {
            if (entry.done || entry.fatal) break;
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

  // --- Descarga secuencial única ---

  void _ensureFetch(_PgEntry entry) {
    if (entry.fetching || entry.done || entry.fatal) return;
    entry.fetching = true;
    _fetchLoop(entry);
  }

  Future<void> _fetchLoop(_PgEntry entry) async {
    try {
      while (!entry.done && !entry.fatal && !entry.dead) {
        final ok = await _fetchOnce(entry);
        if (ok) break;
        entry.failures++;
        if (entry.failures >= 4) {
          entry.fatal = true;
          break;
        }
        await Future.delayed(const Duration(seconds: 2));
      }
    } finally {
      entry.fetching = false;
    }
  }

  /// Un intento de descarga (con resume si hay parcial). Devuelve true si el
  /// archivo quedó completo.
  Future<bool> _fetchOnce(_PgEntry entry) async {
    final client = http.Client();
    try {
      final from = await entry.localSize();
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
      if (from > 0) req.headers['Range'] = 'bytes=$from-';
      req.followRedirects = true;

      final res = await client.send(req).timeout(const Duration(seconds: 30));
      if (res.statusCode != 200 && res.statusCode != 206) {
        return false;
      }
      if (res.statusCode == 200 && from > 0) {
        // El origen ignoró el resume: reiniciar archivo.
        await entry.file.writeAsBytes([], mode: FileMode.write);
      }
      // Tamaño total desde la primera respuesta con longitud.
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

      final sink = entry.file.openWrite(mode: FileMode.append);
      try {
        // Vigilante de estancamiento: si el origen deja de mandar bytes, se
        // aborta el intento y se reintenta con resume (el reproductor sigue
        // servido desde lo ya descargado en disco).
        final watched = res.stream.timeout(
          ProgressiveFileProxy._kStallTimeout,
          onTimeout: (sink) => sink.addError(TimeoutException(
              'origen estancado', ProgressiveFileProxy._kStallTimeout)),
        );
        await for (final data in watched) {
          // Si el enlace fue desplazado por otro nuevo, dejar de descargar.
          if (entry.dead) return false;
          sink.add(data);
          await sink.flush();
        }
      } finally {
        await sink.close();
      }
      // Verificar compleción por tamaño.
      final total = entry.totalBytes;
      final have = await entry.localSize();
      if (total != null && have >= total) {
        entry.done = true;
        return true;
      }
      // Sin total conocido pero el stream terminó: asumir completo.
      if (total == null) {
        entry.done = true;
        return true;
      }
      // Incompleto y sin error explícito: el origen cortó; reintentar resume.
      return false;
    } catch (_) {
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
            await e.file.delete();
          } catch (_) {}
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
          try {
            await e.file.delete();
          } catch (_) {}
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
  int? totalBytes;
  String contentType;
  bool fetching = false;
  bool done = false;
  bool fatal = false;
  bool dead = false;
  int failures = 0;
  DateTime lastUse = DateTime.now();

  _PgEntry({
    required this.token,
    required this.url,
    required this.headers,
    required this.ext,
    required this.file,
  }) : contentType = ProgressiveFileProxy._kExtToContentType[ext] ?? 'video/mp4';

  Future<int> localSize() async {
    try {
      return await file.length();
    } catch (_) {
      return 0;
    }
  }
}
