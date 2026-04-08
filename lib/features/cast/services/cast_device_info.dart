import 'package:dart_cast/dart_cast.dart';
import 'package:flutter/material.dart';

/// Tipos de dispositivos detectados con su identidad visual
enum CastDeviceType {
  chromecast,
  samsung,
  lg,
  roku,
  appleTv,
  androidTv,
  dlnaGeneric,
  unknown,
}

/// Wrapper de presentación sobre [CastDevice]
class CastDeviceInfo {
  final CastDevice rawDevice;
  final String name;
  final String address;
  final CastProtocol protocol;
  final CastDeviceType deviceType;

  const CastDeviceInfo({
    required this.rawDevice,
    required this.name,
    required this.address,
    required this.protocol,
    required this.deviceType,
  });

  factory CastDeviceInfo.fromCastDevice(CastDevice device) {
    final type = _detectType(device);
    return CastDeviceInfo(
      rawDevice: device,
      name: device.name,
      address: device.address.address,
      protocol: device.protocol,
      deviceType: type,
    );
  }

  static CastDeviceType _detectType(CastDevice device) {
    final nameLower = device.name.toLowerCase();
    if (device.protocol == CastProtocol.chromecast) {
      if (nameLower.contains('chromecast')) return CastDeviceType.chromecast;
      if (nameLower.contains('android tv') || nameLower.contains('shield') || nameLower.contains('fire tv'))
        return CastDeviceType.androidTv;
      return CastDeviceType.chromecast;
    }
    if (device.protocol == CastProtocol.airplay) {
      if (nameLower.contains('apple tv') || nameLower.contains('appletv')) return CastDeviceType.appleTv;
      return CastDeviceType.appleTv;
    }
    if (device.protocol == CastProtocol.dlna) {
      if (nameLower.contains('samsung')) return CastDeviceType.samsung;
      if (nameLower.contains('lg')) return CastDeviceType.lg;
      if (nameLower.contains('roku')) return CastDeviceType.roku;
      if (nameLower.contains('android') || nameLower.contains('tv box')) return CastDeviceType.androidTv;
      return CastDeviceType.dlnaGeneric;
    }
    return CastDeviceType.unknown;
  }

  /// Retorna el ícono correspondiente al tipo de dispositivo
  IconData get icon {
    switch (deviceType) {
      case CastDeviceType.chromecast:    return Icons.cast;
      case CastDeviceType.samsung:       return Icons.tv;
      case CastDeviceType.lg:            return Icons.connected_tv;
      case CastDeviceType.roku:          return Icons.live_tv;
      case CastDeviceType.appleTv:       return Icons.apple;
      case CastDeviceType.androidTv:     return Icons.smart_display;
      case CastDeviceType.dlnaGeneric:   return Icons.tv;
      default:                           return Icons.devices_other;
    }
  }

  /// Color del ícono/acento según marca
  Color get accentColor {
    switch (deviceType) {
      case CastDeviceType.chromecast:    return const Color(0xFF4285F4); // Google Blue
      case CastDeviceType.samsung:       return const Color(0xFF1428A0); // Samsung Blue
      case CastDeviceType.lg:            return const Color(0xFFC00000); // LG Red
      case CastDeviceType.roku:          return const Color(0xFF6C2BD9); // Roku Purple
      case CastDeviceType.appleTv:       return const Color(0xFF9E9E9E); // Apple Silver
      case CastDeviceType.androidTv:     return const Color(0xFF3DDC84); // Android Green
      case CastDeviceType.dlnaGeneric:   return const Color(0xFF00A3FF); // K7 Blue
      default:                           return const Color(0xFF9E9E9E);
    }
  }

  /// Nombre amigable del protocolo
  String get protocolLabel {
    switch (protocol) {
      case CastProtocol.chromecast: return 'Chromecast';
      case CastProtocol.airplay:    return 'AirPlay';
      case CastProtocol.dlna:       return 'DLNA/Smart TV';
    }
  }

  /// Subtítulo con IP y protocolo
  String get subtitle => '$address · $protocolLabel';
}
