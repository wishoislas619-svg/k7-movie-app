import 'package:supabase_flutter/supabase_flutter.dart';

class SupabaseService {
  static const String projectUrl = 'https://mvhfczknbhpwwwusrytt.supabase.co';
  static const String anonKey = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im12aGZjemtuYmhwd3d3dXNyeXR0Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzM4NTU2NTcsImV4cCI6MjA4OTQzMTY1N30.rGp5B4Rd8WlV81ZVIfS2Sf2LUDteRvusPLk392141kI';

  static Future<void> initialize() async {
    await Supabase.initialize(
      url: projectUrl,
      anonKey: anonKey,
      authOptions: const FlutterAuthClientOptions(
        authFlowType: AuthFlowType.pkce,
        autoRefreshToken: true,
      ),
    );
  }

  static SupabaseClient get client => Supabase.instance.client;
}
