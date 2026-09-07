import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

class StorageService {
  static const String _keyEmail = 'remembered_email';
  static const String _keyPassword = 'remembered_password';
  static const String _keyAutoLogin = 'auto_login_enabled';
  static const String _keyVolume = 'player_volume';
  static const String _keyBrightness = 'player_brightness';
  static const String _keySearchHistory = 'smart_search_history';
  static const int _maxSearchHistory = 20;

  static Future<void> saveCredentials(String email, String password) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyEmail, email);
    await prefs.setString(_keyPassword, password);
    await prefs.setBool(_keyAutoLogin, true);
  }

  static Future<void> setAutoLoginEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyAutoLogin, enabled);
  }

  static Future<String?> getStoredEmail() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyEmail);
  }

  static Future<String?> getStoredPassword() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keyPassword);
  }

  static Future<bool> isAutoLoginEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyAutoLogin) ?? false;
  }

  static Future<void> savePlayerSettings(double volume, double brightness) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_keyVolume, volume);
    await prefs.setDouble(_keyBrightness, brightness);
  }

  static Future<void> saveVolume(double volume) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_keyVolume, volume);
  }

  static Future<void> saveBrightness(double brightness) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_keyBrightness, brightness);
  }

  static Future<double?> getStoredVolume() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getDouble(_keyVolume);
  }

  static Future<double?> getStoredBrightness() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getDouble(_keyBrightness);
  }

  /// Guarda una búsqueda en el historial local (máx [_maxSearchHistory],
  /// deduplicada por tmdbId+mediaType, la más reciente primero).
  static Future<void> saveSearchEntry(Map<String, dynamic> entry) async {
    final prefs = await SharedPreferences.getInstance();
    final history = await loadSearchHistory();
    history.removeWhere((e) =>
        e['tmdbId'] == entry['tmdbId'] &&
        e['mediaType'] == entry['mediaType']);
    history.insert(0, entry);
    if (history.length > _maxSearchHistory) {
      history.removeRange(_maxSearchHistory, history.length);
    }
    await prefs.setString(_keySearchHistory, jsonEncode(history));
  }

  static Future<List<Map<String, dynamic>>> loadSearchHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_keySearchHistory);
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list
          .map((e) => (e as Map).cast<String, dynamic>())
          .toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> clearSearchHistory() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keySearchHistory);
  }
}
