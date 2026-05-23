import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_cast/dart_cast.dart' as dc;
import 'package:http/http.dart' as http;

class RokuAppInfo {
  final String id;
  final String name;

  const RokuAppInfo({required this.id, required this.name});
}

class RokuEcpService {
  static const int ecpPort = 8060;
  static const _ssdpAddress = '239.255.255.250';
  static const _ssdpPort = 1900;

  RawDatagramSocket? _socket;

  Stream<List<dc.CastDevice>> discover({
    Duration timeout = const Duration(seconds: 8),
  }) async* {
    final found = <String, dc.CastDevice>{};
    final controller = StreamController<List<dc.CastDevice>>();
    Timer? timer;

    try {
      _socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      _socket!.broadcastEnabled = true;

      final message = utf8.encode(
        'M-SEARCH * HTTP/1.1\r\n'
        'HOST: $_ssdpAddress:$_ssdpPort\r\n'
        'MAN: "ssdp:discover"\r\n'
        'MX: 2\r\n'
        'ST: roku:ecp\r\n'
        '\r\n',
      );

      void emitIfChanged(dc.CastDevice device) {
        final key = device.address.address;
        final previous = found[key];
        found[key] = device;
        if (previous == null || previous.name != device.name) {
          controller.add(found.values.toList(growable: false));
        }
      }

      _socket!.listen((event) async {
        if (event != RawSocketEvent.read) return;
        final datagram = _socket!.receive();
        if (datagram == null) return;

        final response = utf8.decode(datagram.data, allowMalformed: true);
        final headers = _parseSsdpHeaders(response);
        final location = headers['location'];
        final server = headers['server'] ?? '';
        final usn = headers['usn'] ?? datagram.address.address;

        final isRoku =
            response.toLowerCase().contains('roku') ||
            server.toLowerCase().contains('roku') ||
            (location?.contains(':$ecpPort') ?? false);
        if (!isRoku) return;

        final baseUrl = location != null
            ? _baseUrlFromLocation(location)
            : null;
        final address = baseUrl != null
            ? Uri.tryParse(baseUrl)?.host
            : datagram.address.address;
        if (address == null || address.isEmpty) return;

        final metadata = <String, String>{
          'roku': 'true',
          'ecpBaseUrl': baseUrl ?? 'http://$address:$ecpPort',
          if (location != null) 'location': location,
          if (server.isNotEmpty) 'server': server,
          if (usn.isNotEmpty) 'usn': usn,
        };

        final info = await getDeviceInfo(metadata['ecpBaseUrl']!);
        metadata.addAll(info);

        final friendlyName =
            info['user-device-name'] ??
            info['friendly-device-name'] ??
            info['default-device-name'] ??
            info['model-name'] ??
            'Roku';

        emitIfChanged(
          dc.CastDevice(
            id: 'roku-$address',
            name: friendlyName,
            protocol: dc.CastProtocol.dlna,
            address: InternetAddress(address),
            port: ecpPort,
            metadata: metadata,
          ),
        );
      });

      _socket!.send(message, InternetAddress(_ssdpAddress), _ssdpPort);
      Future.delayed(const Duration(seconds: 2), () {
        _socket?.send(message, InternetAddress(_ssdpAddress), _ssdpPort);
      });

      timer = Timer(timeout, () {
        if (!controller.isClosed) controller.close();
      });

      yield* controller.stream;
    } finally {
      timer?.cancel();
      await controller.close();
      stop();
    }
  }

  Future<Map<String, String>> getDeviceInfo(String baseUrl) async {
    try {
      final response = await http
          .get(Uri.parse('$baseUrl/query/device-info'))
          .timeout(const Duration(seconds: 3));
      if (response.statusCode != 200) return const {};
      return _parseSimpleXml(response.body);
    } catch (_) {
      return const {};
    }
  }

  Future<List<RokuAppInfo>> queryApps(String baseUrl) async {
    final response = await http
        .get(Uri.parse('$baseUrl/query/apps'))
        .timeout(const Duration(seconds: 4));
    if (response.statusCode != 200) return const [];

    final appPattern = RegExp(
      r'<app\b[^>]*\bid="([^"]+)"[^>]*>([^<]+)</app>',
      caseSensitive: false,
    );
    return appPattern
        .allMatches(response.body)
        .map(
          (m) => RokuAppInfo(
            id: m.group(1)!.trim(),
            name: _decodeXml(m.group(2)!.trim()),
          ),
        )
        .toList(growable: false);
  }

  Future<bool> launch(
    String baseUrl,
    String appId, {
    Map<String, String>? params,
  }) async {
    final uri = Uri.parse(
      '$baseUrl/launch/$appId',
    ).replace(queryParameters: params?.isEmpty ?? true ? null : params);
    final response = await http.post(uri).timeout(const Duration(seconds: 5));
    return response.statusCode >= 200 && response.statusCode < 300;
  }

  Future<void> keypress(String baseUrl, String key) async {
    await http
        .post(Uri.parse('$baseUrl/keypress/$key'))
        .timeout(const Duration(seconds: 3));
  }

  Future<Map<String, String>> queryMediaPlayer(String baseUrl) async {
    try {
      final response = await http
          .get(Uri.parse('$baseUrl/query/media-player'))
          .timeout(const Duration(seconds: 3));
      if (response.statusCode != 200) return const {};
      return _parseSimpleXml(response.body);
    } catch (_) {
      return const {};
    }
  }

  void stop() {
    _socket?.close();
    _socket = null;
  }

  static Map<String, String> _parseSsdpHeaders(String response) {
    final result = <String, String>{};
    for (final line in response.split(RegExp(r'\r?\n'))) {
      final index = line.indexOf(':');
      if (index <= 0) continue;
      result[line.substring(0, index).trim().toLowerCase()] = line
          .substring(index + 1)
          .trim();
    }
    return result;
  }

  static String _baseUrlFromLocation(String location) {
    final uri = Uri.parse(location);
    final port = uri.hasPort ? uri.port : ecpPort;
    return '${uri.scheme}://${uri.host}:$port';
  }

  static Map<String, String> _parseSimpleXml(String xml) {
    final result = <String, String>{};
    final pattern = RegExp(
      r'<([a-zA-Z0-9_-]+)>([^<]*)</\1>',
      caseSensitive: false,
    );
    for (final match in pattern.allMatches(xml)) {
      result[match.group(1)!.toLowerCase()] = _decodeXml(match.group(2)!);
    }
    return result;
  }

  static String _decodeXml(String value) {
    return value
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&apos;', "'");
  }
}
