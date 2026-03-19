import 'package:flutter/material.dart';
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

class _AuthWrapperState extends ConsumerState<AuthWrapper> {
  bool _initialized = false;

  @override
  void initState() {
    super.initState();
    // Auto-login: intenta restaurar la sesión del usuario anterior al abrir la app
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await ref.read(authStateProvider.notifier).checkStatus();
      if (mounted) setState(() => _initialized = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    final splashDone = ref.watch(splashDoneProvider);

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

    final user = ref.watch(authStateProvider);

    if (user == null) {
      return const LoginPage();
    }

    // Envolver con el detector de actividad para manejar el timeout de inactividad
    if (user.role == AppConstants.roleAdmin) {
      return const _ActivityDetector(child: AdminDashboard());
    }

    return const _ActivityDetector(child: MovieGridPage());
  }
}

