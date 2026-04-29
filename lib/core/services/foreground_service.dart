import 'dart:io';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';

class ForegroundService {
  static bool _started = false;

  static Future<void> init() async {
    if (!Platform.isAndroid) return;

    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'movie_app_foreground',
        channelName: 'Servicio en segundo plano',
        channelDescription: 'Mantiene las tareas activas (descargas/transmisión) en segundo plano',
        channelImportance: NotificationChannelImportance.HIGH,
        priority: NotificationPriority.HIGH,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        autoRunOnBoot: false,
        autoRunOnMyPackageReplaced: false,
        allowWakeLock: true,
        allowWifiLock: true,
        allowAutoRestart: true,
      ),
    );
  }

  static Future<void> start({required String title, String? text}) async {
    if (!Platform.isAndroid) return;

    if (_started) {
      await FlutterForegroundTask.updateService(
        notificationTitle: title,
        notificationText: text ?? 'Descarga en progreso',
      );
      return;
    }

    final result = await FlutterForegroundTask.startService(
      notificationTitle: title,
      notificationText: text ?? 'Descarga en progreso',
    );
    _started = result is ServiceRequestSuccess;
  }

  static Future<void> stop() async {
    if (!Platform.isAndroid) return;
    if (!_started) return;
    await FlutterForegroundTask.stopService();
    _started = false;
  }
}
