import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_media_kit/video_player_media_kit.dart';
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
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:unity_ads_plugin/unity_ads_plugin.dart';
import 'dart:io';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'features/cast/presentation/pages/cast_remote_page.dart';
import 'features/cast/services/cast_service.dart';
import 'core/services/notification_service.dart';
import 'core/services/foreground_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'features/auth/domain/entities/user.dart';
import 'shared/widgets/virtual_cursor_overlay.dart';

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  try {
    VideoPlayerMediaKit.ensureInitialized(
      android: true,
      iOS: false,
      macOS: false,
      windows: false,
      linux: false,
    );
  } catch (e) {
    debugPrint("Error inicializando media_kit backend: $e");
  }

  WakelockPlus.enable();

  SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);

  try {
    await dotenv.load(fileName: ".env");
    await SupabaseService.initialize();
  } catch (e) {
    debugPrint("Error crítico en arranque: $e");
  }

  unawaited(NotificationService.init().catchError((e) => debugPrint("Error Notify: $e")));
  unawaited(ForegroundService.init().catchError((e) => debugPrint("Error Foreground: $e")));
  unawaited(_requestBatteryOptimizationPermission());
  unawaited(Permission.notification.request().catchError((e) => debugPrint("Error notif: $e")));

  // Nota: UMP + MobileAds + Unity se inicializan en AuthWrapper (post-runApp),
  // porque el formulario nativo de consentimiento necesita el engine listo.
  runApp(
    const ProviderScope(
      child: MyApp(),
    ),
  );
}

/// Muestra el diálogo de consentimiento UMP solo si es necesario (una sola vez).
/// El SDK de UMP guarda la decisión (aceptar/rechazar) entre sesiones:
/// después de requestConsentInfoUpdate, si getConsentStatus() != required,
/// ya hubo decisión y NO se vuelve a mostrar el formulario.
/// Retorna canRequestAds() para decidir inicialización de ads.
Future<bool> _initializeUMPConsent() async {
  debugPrint('[UMPCOMPONENT] Inicializando UMP...');
  const decidedKey = 'ump_consent_decided_v1';
  const canRequestKey = 'ump_can_request_ads_v1';
  try {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(decidedKey) == true) {
      final bool stored = prefs.getBool(canRequestKey) ?? true;
      debugPrint('[UMPCOMPONENT] Decisión local previa, no se muestra diálogo. canRequest=$stored');
      return stored;
    }

    Future<void> remember(bool canRequest) async {
      await prefs.setBool(decidedKey, true);
      await prefs.setBool(canRequestKey, canRequest);
    }

    final consentInfo = ConsentInformation.instance;

    // Paso 1: requestConsentInfoUpdate (void + callbacks).
    // En debug se fuerza geografía EEA + test device para probar el diálogo;
    // en release se usa la región real del dispositivo.
    FormError? updateError;
    final completer1 = Completer<void>();
    consentInfo.requestConsentInfoUpdate(
      ConsentRequestParameters(
        consentDebugSettings: kDebugMode
            ? ConsentDebugSettings(
                debugGeography: DebugGeography.debugGeographyEea,
                testIdentifiers: ['D4401ED3C883864E683E2DD7DD51098B'],
              )
            : null,
      ),
      () => completer1.complete(),
      (FormError error) {
        updateError = error;
        completer1.complete();
      },
    );
    await completer1.future;
    if (updateError != null) {
      debugPrint('[UMPCOMPONENT] Error code=${updateError!.errorCode}, msg=${updateError!.message}');
      return false;
    }
    debugPrint('[UMPCOMPONENT] requestConsentInfoUpdate success');

    // Paso 1b: si el usuario ya decidió (aceptó o rechazó), no mostrar de nuevo.
    final ConsentStatus status = await consentInfo.getConsentStatus();
    debugPrint('[UMPCOMPONENT] consentStatus=$status');
    if (status != ConsentStatus.required) {
      final bool canRequest = await consentInfo.canRequestAds();
      debugPrint('[UMPCOMPONENT] Ya había decisión previa, no se muestra diálogo. canRequestAds=$canRequest');
      await remember(canRequest);
      return canRequest;
    }

    // Paso 2: isConsentFormAvailable (async normal)
    final bool available = await consentInfo.isConsentFormAvailable();
    debugPrint('[UMPCOMPONENT] isConsentFormAvailable: $available');
    if (!available) {
      final bool canRequest = await consentInfo.canRequestAds();
      await remember(canRequest);
      return canRequest;
    }

    // Paso 3: loadConsentForm (void + callbacks)
    late ConsentForm form;
    final completer3 = Completer<void>();
    ConsentForm.loadConsentForm(
      (f) {
        form = f;
        completer3.complete();
      },
      (FormError error) {
        debugPrint('[UMPCOMPONENT] loadConsentForm error: ${error.message}');
        completer3.completeError(error);
      },
    );
    await completer3.future;
    debugPrint('[UMPCOMPONENT] loadConsentForm success');

    // Paso 4: show (void + callbacks). Al cerrar, el SDK persiste la decisión.
    final completer4 = Completer<void>();
    form.show((FormError? error) {
      if (error != null) {
        debugPrint('[UMPCOMPONENT] show error: code=${error.errorCode}, msg=${error.message}');
      } else {
        debugPrint('[UMPCOMPONENT] Formulario cerrado ✓');
      }
      completer4.complete();
    });
    await completer4.future;

    // Paso 5: releer estado persistido y decidir ads según decisión recordada.
    final ConsentStatus afterStatus = await consentInfo.getConsentStatus();
    final bool canRequestAfter = await consentInfo.canRequestAds();
    debugPrint('[UMPCOMPONENT] afterStatus=$afterStatus canRequestAds=$canRequestAfter');
    await remember(canRequestAfter);

    return canRequestAfter;
  } catch (e, stack) {
    debugPrint('[UMPCOMPONENT] Excepción UMP: $e\n$stack');
    return false;
  }
}

/// Solicita al usuario que desactive la optimización de batería para la app.
Future<void> _requestBatteryOptimizationPermission() async {
  if (!Platform.isAndroid) return;
  try {
    final androidInfo = await DeviceInfoPlugin().androidInfo;
    if (androidInfo.version.sdkInt >= 23) {
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
  void didChangeAppLifecycleState(AppLifecycleState state) {}

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
        return VirtualCursorOverlay(
          child: Stack(
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
                    ref.read(floatingPlayerProvider.notifier).state = FloatingPlayerState(isActive: false);
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
                        ),
                      ),
                      (route) => route.isFirst,
                    );
                  },
                ),
              _CastBubble(),
            ],
          ),
        );
      },
    );
  }
}

class _ActivityDetector extends ConsumerWidget {
  final Widget child;
  const _ActivityDetector({required this.child});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) {
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
  bool _consentDone = false;
  StreamSubscription? _statusSubscription;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await ref.read(authStateProvider.notifier).checkStatus();
      if (mounted) {
        setState(() => _initialized = true);
        _checkUpdates();
      }
    });
    // UMP + Ads post-runApp: el diálogo nativo necesita el engine listo.
    // Con timeout para no dejar la app en negro si UMP no responde.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      bool consentGiven = false;
      try {
        consentGiven = await _initializeUMPConsent()
            .timeout(const Duration(seconds: 20), onTimeout: () {
          debugPrint('[UMPCOMPONENT] Timeout, se continúa sin consentimiento');
          return false;
        });
      } catch (e) {
        debugPrint('[UMPCOMPONENT] Error en AuthWrapper: $e');
      }
      await _initAds(consentGiven);
      if (mounted) setState(() => _consentDone = true);
    });
  }

  Future<void> _initAds(bool consentGiven) async {
    try {
      await MobileAds.instance.initialize();
      MobileAds.instance.updateRequestConfiguration(
        RequestConfiguration(
          testDeviceIds: [
            "D4401ED3C883864E683E2DD7DD51098B",
            "52ed6a0e-d948-41d1-b035-3ed4dbd701cf"
          ],
          tagForUnderAgeOfConsent: consentGiven ? 0 : 1,
        ),
      );
    } catch (e) {
      debugPrint("Error Ads: $e");
    }
    const bool hasUnityAds = bool.fromEnvironment('HAS_UNITY_ADS', defaultValue: true);
    if (consentGiven && hasUnityAds) {
      unawaited(UnityAds.init(
        gameId: Platform.isAndroid ? '6074470' : '6074471',
        testMode: false,
        onComplete: () => debugPrint('Unity Ads Init Complete'),
        onFailed: (error, message) => debugPrint('Unity Ads Init Failed: $error $message'),
      ));
    }
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
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, letterSpacing: 1.5)),
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

    // El diálogo UMP aparece sobre el splash/contenido; se espera a que
    // termine consentimiento + init de ads antes de entrar (con timeout).
    if (!_consentDone || !_initialized) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(child: CircularProgressIndicator(color: Color(0xFF00A3FF))),
      );
    }

    if (user == null) {
      return const LoginPage();
    }

    if (user.role == AppConstants.roleAdmin) {
      return _ActivityDetector(child: const AdminDashboard());
    }

    return _ActivityDetector(child: const MovieGridPage());
  }
}

class _CastBubble extends StatefulWidget {
  @override
  State<_CastBubble> createState() => _CastBubbleState();
}

class _CastBubbleState extends State<_CastBubble> with TickerProviderStateMixin {
  final _castService = CastService();
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;
  late AnimationController _gradientController;
  double _bubbleX = 0;
  double _bubbleY = 0;
  bool _bubblePositioned = false;

  static const _tornasolPairs = [
    [Color(0xFF0022FF), Color(0xFF00A3FF)],
    [Color(0xFF4A00E0), Color(0xFFCC33FF)],
    [Color(0xFF6600CC), Color(0xFFE040FB)],
    [Color(0xFF0022FF), Color(0xFF8E2DE2)],
    [Color(0xFF006064), Color(0xFF00E5FF)],
    [Color(0xFF4A00E0), Color(0xFF00FF87)],
  ];

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(vsync: this, duration: const Duration(milliseconds: 1500))..repeat(reverse: true);
    _pulseAnimation = Tween<double>(begin: 0.9, end: 1.0).animate(CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut));
    _gradientController = AnimationController(vsync: this, duration: const Duration(seconds: 8))..repeat();
    _castService.addListener(_onCastChanged);
  }

  @override
  void dispose() {
    _castService.removeListener(_onCastChanged);
    _pulseController.dispose();
    _gradientController.dispose();
    super.dispose();
  }

  Color _lerpColor(Color a, Color b, double t) {
    return Color.fromARGB(
      a.alpha,
      (a.red + (b.red - a.red) * t).round(),
      (a.green + (b.green - a.green) * t).round(),
      (a.blue + (b.blue - a.blue) * t).round(),
    );
  }

  List<Color> _currentGradient() {
    final t = _gradientController.value * _tornasolPairs.length;
    final index = t.floor() % _tornasolPairs.length;
    final frac = t - t.floor();
    final a = _tornasolPairs[index];
    final b = _tornasolPairs[(index + 1) % _tornasolPairs.length];
    return [_lerpColor(a[0], b[0], frac), _lerpColor(a[1], b[1], frac)];
  }

  Color _currentShadowColor() {
    final colors = _currentGradient();
    return colors.last.withValues(alpha: 0.4);
  }

  void _onCastChanged() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_castService.isConnected || _castService.isRemotePageOpen) return const SizedBox.shrink();

    if (!_bubblePositioned) {
      final size = MediaQuery.of(context).size;
      _bubbleX = size.width - 16 - 56;
      _bubbleY = size.height - MediaQuery.of(context).padding.bottom - 90 - 56;
      _bubblePositioned = true;
    }

    return Positioned(
      left: _bubbleX,
      top: _bubbleY,
      child: AnimatedBuilder(
        animation: Listenable.merge([_pulseAnimation, _gradientController]),
        builder: (context, child) {
          final gradientColors = _currentGradient();
          return GestureDetector(
            onTap: () {
              navigatorKey.currentState?.push(
                MaterialPageRoute(
                  settings: const RouteSettings(name: '/cast_remote'),
                  builder: (_) => const CastRemotePage(),
                ),
              );
            },
            onPanUpdate: (details) {
              setState(() {
                _bubbleX += details.delta.dx;
                _bubbleY += details.delta.dy;
              });
            },
            child: Transform.scale(
              scale: _pulseAnimation.value,
              child: Container(
                width: 56, height: 56,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    colors: gradientColors,
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: _currentShadowColor(),
                      blurRadius: 16,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: const Icon(Icons.cast_rounded, color: Colors.white, size: 28),
              ),
            ),
          );
        },
      ),
    );
  }
}
