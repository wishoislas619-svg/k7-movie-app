import 'package:shared_preferences/shared_preferences.dart';

class StorageService {
  static const String _keyEmail = 'remembered_email';
  static const String _keyPassword = 'remembered_password';
  static const String _keyAutoLogin = 'auto_login_enabled';
  static const String _keyVolume = 'player_volume';
  static const String _keyBrightness = 'player_brightness';

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
}
