class AppConstants {
  // UI Sizes
  static const double movieImageWidth = 100.0;
  static const double movieImageHeight = 120.0;
  static const double serverImageSize = 40.0;
  static const double optionRowHeight = 40.0;

  // Roles del sistema (deben coincidir con el enum en Supabase)
  static const String roleAdmin    = 'admin';
  static const String roleUser     = 'user';
  static const String roleUserVip  = 'uservip';
  static const String roleSecurity = 'security';

  // Configuración de almacenamiento (Decidido por el programador)
  static const bool secureSave = false;
}

/// Bandera maestra de presentación (requiere recompilar al cambiarla).
/// - true: modo simplificado → oculta las categorías manuales de la base,
///   oculta la pantalla de TV en vivo (quedan 4 tabs), oculta el botón de
///   instalación rápida de Torrentio, y los pósters de tendencia/carrusel
///   buscan el título en el buscador inteligente en vez de ir a detalles.
/// - false: funcionamiento actual completo. Nada se borra, solo se oculta.
class AppConfig {
  static const bool liteMode = false;
}
