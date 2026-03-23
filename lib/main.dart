import 'package:flutter/material.dart';
import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'core/theme/app_theme.dart';
import 'core/constants/app_constants.dart';
import 'core/services/supabase_service.dart';
import 'providers.dart';
import 'features/auth/presentation/pages/login_page.dart';
import 'features/auth/presentation/providers/auth_provider.dart';
import 'features/auth/presentation/pages/admin_dashboard.dart';
import 'features/movies/presentation/pages/movie_grid_page.dart';
import 'features/movies/presentation/pages/splash_page.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'core/services/notification_service.dart';
import 'core/services/foreground_service.dart';
import 'features/auth/domain/entities/user.dart';
import 'package:google_sign_in/google_sign_in.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await dotenv.load(fileName: ".env");
  await NotificationService.init();
  await ForegroundService.init();

  // Inicializar Supabase (reemplaza SQLite + SharedPreferences para auth)
  await SupabaseService.initialize();

  runApp(
    const ProviderScope(
      child: MyApp(),
    ),
  );
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'K7 Movie App',
      theme: AppTheme.darkTheme,
      debugShowCheckedModeBanner: false,
      home: const AuthWrapper(),
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
      if (mounted) setState(() => _initialized = true);
    });
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
