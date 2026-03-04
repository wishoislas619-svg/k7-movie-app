import 'package:google_fonts/google_fonts.dart';
import 'package:flutter/material.dart';

class AppTheme {
  static ThemeData get darkTheme {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF6750A4),
        brightness: Brightness.dark,
        surface: const Color(0xFF1C1B1F),
      ),
      textTheme: GoogleFonts.outfitTextTheme(
        ThemeData.dark().textTheme.copyWith(
          displayLarge: const TextStyle(fontSize: 40.0),
          displayMedium: const TextStyle(fontSize: 34.0),
          displaySmall: const TextStyle(fontSize: 28.0),
          headlineMedium: const TextStyle(fontSize: 26.0),
          titleLarge: const TextStyle(fontSize: 26.0),
          titleMedium: const TextStyle(fontSize: 22.0),
          titleSmall: const TextStyle(fontSize: 20.0),
          bodyLarge: const TextStyle(fontSize: 22.0),
          bodyMedium: const TextStyle(fontSize: 20.0),
          labelLarge: const TextStyle(fontSize: 20.0),
          bodySmall: const TextStyle(fontSize: 18.0),
        ),
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
      ),
    );
  }
}
