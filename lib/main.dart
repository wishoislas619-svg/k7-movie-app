import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';
import 'features/movies/domain/entities/movie.dart';
import 'core/theme/app_theme.dart';
import 'core/constants/app_constants.dart';
import 'core/services/supabase_service.dart';
import 'providers.dart';
import 'features/auth/presentation/pages/login_page.dart';
import 'features/auth/presentation/providers/auth_provider.dart';
import 'features/auth/presentation/pages/admin_dashboard.dart';
import 'features/movies/presentation/pages/movie_grid_page.dart';
import 'features/player/presentation/widgets/floating_player_overlay.dart';
import 'features/player/presentation/pages/video_player_page.dart';
import 'features/movies/presentation/pages/splash_page.dart';
import 'core/services/update_service.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'core/services/notification_service.dart';
import 'core/services/foreground_service.dart';
import 'features/auth/domain/entities/user.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:unity_ads_plugin/unity_ads_plugin.dart';
import 'dart:io';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:device_info_plus/device_info_plus.dart';


final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  WakelockPlus.enable();
  
  // Habilitar todas las orientaciones por defecto en toda la app
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);
  
  // Cargamos Solo lo CRÍTICO para ver la primera pantalla
  try {
    await dotenv.load(fileName: ".env");
    await SupabaseService.initialize();
  } catch (e) {
    debugPrint("Error crítico en arranque: $e");
  }

  // Servicios secundarios: Se lanzan "en paralelo" sin bloquear el dibujo de la App
  unawaited(NotificationService.init().catchError((e) => debugPrint("Error Notify: $e")));
  unawaited(ForegroundService.init().catchError((e) => debugPrint("Error Foreground: $e")));
  
  // Solicitar permisos de batería/optimización para que el proxy y cast
  // sigan funcionando en segundo plano o con pantalla apagada
  unawaited(_requestBatteryOptimizationPermission());
  unawaited(MobileAds.instance.initialize().then((_) {
    MobileAds.instance.updateRequestConfiguration(
      RequestConfiguration(testDeviceIds: [
        "D4401ED3C883864E683E2DD7DD51098B",
        "52ed6a0e-d948-41d1-b035-3ed4dbd701cf"
      ]),
    );
  }).catchError((e) => debugPrint("Error Ads: $e")));

  unawaited(UnityAds.init(
    gameId: Platform.isAndroid ? '6074470' : '6074471',
    testMode: false,
    onComplete: () => debugPrint('Unity Ads Init Complete'),
    onFailed: (error, message) => debugPrint('Unity Ads Init Failed: $error $message'),
  ));

  // ✅ ESCANEAR Y SOLICITAR PERMISOS DE AHORRO DE BATERÍA
  // Esto permite que el proxy local y el cast sigan funcionando incluso
  // si la pantalla está apagada o la app está en segundo plano
    // Verificación de estado de batería (el aviso se mostrará mediante el diálogo en MyApp)
    try {
      await Permission.ignoreBatteryOptimizations.status;
    } catch (e) {
      debugPrint("Error verificando estado batería: $e");
    }
    
    
    // Solicitar acceso a notificaciones (Android 13+)
    try {
      if (await Permission.notification.isDenied) {
        await Permission.notification.request();
      }
    } catch (e) {
      debugPrint("Error solicitando permiso notificaciones: $e");
    }

    runApp(
      const ProviderScope(
        child: MyApp(),
      ),
    );
}

/// Solicita al usuario que desactive la optimización de batería para la app.
/// En Android, esto requiere un intent especial y el usuario debe aprobarlo manualmente.
Future<void> _requestBatteryOptimizationPermission() async {
  if (!Platform.isAndroid) return;
  try {
    final androidInfo = await DeviceInfoPlugin().androidInfo;
    if (androidInfo.version.sdkInt >= 23) {
      // Solo verificamos el estado, el diálogo se encargará de la solicitud
      await Permission.ignoreBatteryOptimizations.status;
    }
  } catch (e) {
    debugPrint("Error en permiso batería: $e");
  }
}

class MyApp extends ConsumerStatefulWidget {
  const MyApp({super.key});
  @override
  ConsumerState<MyApp> createState() => _MyAppState();
}

class _MyAppState extends ConsumerState<MyApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Native PiP mode handles backgrounding automatically
  }

  @override
  Widget build(BuildContext context) {
    final floatingState = ref.watch(floatingPlayerProvider);

    return MaterialApp(
      navigatorKey: navigatorKey,
      title: 'K7 MOVIE',
      theme: AppTheme.darkTheme,
      debugShowCheckedModeBanner: false,
      home: const AuthWrapper(),
      builder: (context, child) {
        return Stack(
          children: [
            if (child != null) child,
            if (floatingState.isActive && floatingState.controller != null)
              FloatingPlayerOverlay(
                controller: floatingState.controller!,
                title: floatingState.title ?? '',
                onClose: () {
                  ref.read(floatingPlayerProvider.notifier).state = FloatingPlayerState(isActive: false);
                },
                onReturn: () async {
                  final state = ref.read(floatingPlayerProvider.notifier).state;
                  // Cerrar el overlay de sistema si está activo

                  // Limpiar el estado flotante
                  ref.read(floatingPlayerProvider.notifier).state = FloatingPlayerState(isActive: false);
                  
                  // Navegar de vuelta REINICIANDO la reproducción desde el timestamp
                  // Usamos pushAndRemoveUntil para limpiar el stack de navegación
                  navigatorKey.currentState?.pushAndRemoveUntil(
                    MaterialPageRoute(
                      builder: (_) => VideoPlayerPage(
                        movieName: state.title ?? '',
                        videoOptions: state.videoOptions ?? [],
                        mediaId: state.mediaId ?? '',
                        mediaType: state.mediaType ?? 'movie',
                        imagePath: state.imagePath ?? '',
                        episodeId: state.episodeId,
                        startPosition: state.currentPosition,
                        // NO pasamos initialController -> reinicia scraping limpio
                      ),
                    ),
                    (route) => route.isFirst,
                  );
                },
              ),
            // Zona de eliminación (X) al fondo cuando se arrastra (lógica simplificada aquí, el overlay la maneja)
          ],
        );
      },
    );
  }
}

// Listener que detecta cualquier toque del usuario para resetear el timer de inactividad
class _ActivityDetector extends ConsumerWidget {
  final Widget child;
  const _ActivityDetector({required this.child});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) {
        // Cada toque reinicia el contador de inactividad en Supabase
        ref.read(authStateProvider.notifier).refreshActivity();
      },
      child: child,
    );
  }
}

class AuthWrapper extends ConsumerStatefulWidget {
  const AuthWrapper({super.key});

  @override
  ConsumerState<AuthWrapper> createState() => _AuthWrapperState();
}

class _AuthWrapperState extends ConsumerState<AuthWrapper> with WidgetsBindingObserver {
  bool _initialized = false;
  StreamSubscription? _statusSubscription;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Auto-login: intenta restaurar la sesión del usuario anterior al abrir la app
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await ref.read(authStateProvider.notifier).checkStatus();
      if (mounted) {
        setState(() => _initialized = true);
        // Verificar actualizaciones en GitHub de forma asíncrona
        _checkUpdates();
      }
    });
  }

  Future<void> _checkUpdates() async {
    final info = await UpdateService.checkForUpdates();
    if (info != null && info.hasUpdate && mounted) {
      UpdateService.showUpdateDialog(context, info);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _statusSubscription?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      ref.read(authStateProvider.notifier).updateOnlineStatus(true);
    }
  }

  void _setupPresenceListener(User user) {
    _statusSubscription?.cancel();
    _statusSubscription = SupabaseService.client
        .from('profiles')
        .stream(primaryKey: ['id'])
        .eq('id', user.id)
        .listen((data) {
      if (data.isNotEmpty && mounted) {
        final profile = data.first;
        if (profile['login_request_status'] == 'pending') {
          _showAuthorizationDialog(profile['requesting_device_id'] ?? 'Otro dispositivo');
        }
      }
    });

    ref.read(authStateProvider.notifier).updateOnlineStatus(true);
  }

  void _showAuthorizationDialog(String deviceId) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF08080B),
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: const BorderSide(color: Color(0xFF00A3FF), width: 0.5)),
        title: const Text('ALERTA DE SESIÓN',
            style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                letterSpacing: 1.5)),
        content: Text(
          'Otro dispositivo ($deviceId) está intentando iniciar sesión con tu cuenta.\n\n¿Autorizas el acceso? Tu sesión actual se cerrará.',
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => _respondToRequest(false),
            child: const Text('DENEGAR', style: TextStyle(color: Colors.redAccent)),
          ),
          ElevatedButton(
            onPressed: () => _respondToRequest(true),
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00A3FF)),
            child: const Text('AUTORIZAR', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  Future<void> _respondToRequest(bool approved) async {
    final user = ref.read(authStateProvider);
    if (user == null) return;

    await SupabaseService.client.from('profiles').update({
      'login_request_status': approved ? 'approved' : 'denied',
    }).eq('id', user.id);

    if (mounted) Navigator.of(context).pop();

    if (approved) {
      await ref.read(authStateProvider.notifier).logout();
    }
  }

  @override
  Widget build(BuildContext context) {
    final splashDone = ref.watch(splashDoneProvider);
    final user = ref.watch(authStateProvider);

    // Activar el listener reactivamente
    ref.listen<User?>(authStateProvider, (previous, next) {
      if (next != null && previous == null) {
        _setupPresenceListener(next);
      } else if (next == null) {
        _statusSubscription?.cancel();
      }
    });

    if (!splashDone) {
      return SplashPage(
        onFinished: () => ref.read(splashDoneProvider.notifier).state = true,
      );
    }

    if (!_initialized) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(child: CircularProgressIndicator(color: Color(0xFF00A3FF))),
      );
    }

    if (user == null) {
      return const LoginPage();
    }

    // Envolver con el detector de actividad
    if (user.role == AppConstants.roleAdmin) {
      return _ActivityDetector(child: const AdminDashboard());
    }

    return _ActivityDetector(child: const MovieGridPage());
  }
}

