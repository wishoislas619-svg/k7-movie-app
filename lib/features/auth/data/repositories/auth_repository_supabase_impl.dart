import 'dart:async';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as sb;
import 'package:flutter/foundation.dart';
import '../../domain/entities/user.dart';
import '../../domain/repositories/auth_repository.dart';
import '../../../../core/services/supabase_service.dart';

class AuthRepositorySupabaseImpl implements AuthRepository {
  final _client = SupabaseService.client;

  // Obtiene un ID único del dispositivo actual
  Future<String> _getDeviceId() async {
    final deviceInfo = DeviceInfoPlugin();
    try {
      if (defaultTargetPlatform == TargetPlatform.android) {
        final info = await deviceInfo.androidInfo;
        return info.id;
      } else if (defaultTargetPlatform == TargetPlatform.iOS) {
        final info = await deviceInfo.iosInfo;
        return info.identifierForVendor ?? 'ios-unknown';
      }
    } catch (_) {}
    return 'unknown-device';
  }

  // Convierte un usuario de Supabase a nuestra entidad User
  Future<User?> _toUser(sb.User? sbUser) async {
    if (sbUser == null) return null;

    // Leemos el perfil extendido de nuestra tabla profiles
    final profile = await _client
        .from('profiles')
        .select()
        .eq('id', sbUser.id)
        .maybeSingle();

    return User(
      id: sbUser.id,
      email: sbUser.email ?? '',
      username: profile?['username'] ?? sbUser.email?.split('@').first ?? '',
      firstName: profile?['first_name'] ?? '',
      lastName: profile?['last_name'] ?? '',
      role: profile?['role'] ?? 'user',
    );
  }

  @override
  Future<User?> login(String identifier, String password) async {
    try {
      String emailToUse = identifier.trim().toLowerCase();

      // Si no tiene '@', es un username — usamos RPC para bypasear el RLS pre-auth
      if (!emailToUse.contains('@')) {
        final result = await _client.rpc(
          'get_email_by_username',
          params: {'p_username': emailToUse},
        );
        // result es un String directo (TEXT en Postgres)
        if (result == null || result.toString().trim().isEmpty) return null;
        emailToUse = result.toString().trim();
      }

      final res = await _client.auth.signInWithPassword(
        email: emailToUse,
        password: password,
      );

      if (res.user == null) return null;

      // Registrar el dispositivo actual como la sesión activa (single-session)
      final deviceId = await _getDeviceId();
      await _client.from('profiles').update({
        'active_device_id': deviceId,
        'last_active_at': DateTime.now().toIso8601String(),
        'email': res.user!.email, // Sincronizar email por si no se guardó en el trigger
      }).eq('id', res.user!.id);

      return _toUser(res.user);
    } on sb.AuthException {
      return null;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<User?> register({
    required String firstName,
    required String lastName,
    required String email,
    required String username,
    required String password,
  }) async {
    try {
      // Verificar duplicados via RPC (bypasea RLS pre-auth)
      final usernameTaken = await _client.rpc(
        'check_username_exists',
        params: {'p_username': username.trim()},
      );
      if (usernameTaken == true) return null;

      final emailTaken = await _client.rpc(
        'check_email_exists',
        params: {'p_email': email.trim().toLowerCase()},
      );
      if (emailTaken == true) return null;

      final res = await _client.auth.signUp(
        email: email.trim().toLowerCase(),
        password: password,
        data: {
          'first_name': firstName.trim(),
          'last_name': lastName.trim(),
          'username': username.trim(),
        },
      );
      if (res.user == null) return null;

      // Esperar al trigger y luego completar el perfil
      await Future.delayed(const Duration(milliseconds: 800));
      final deviceId = await _getDeviceId();
      await _client.from('profiles').update({
        'first_name': firstName.trim(),
        'last_name': lastName.trim(),
        'username': username.trim(),
        'email': email.trim().toLowerCase(),
        'active_device_id': deviceId,
        'last_active_at': DateTime.now().toIso8601String(),
      }).eq('id', res.user!.id);

      return _toUser(res.user);
    } on sb.AuthException {
      return null;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> logout() async {
    await _client.auth.signOut();
  }

  @override
  Future<User?> getCurrentUser() async {
    final sbUser = _client.auth.currentUser;
    if (sbUser == null) return null;

    // Verificar que la sesión no haya expirado por inactividad o por otro dispositivo
    final profile = await _client
        .from('profiles')
        .select('active_device_id, last_active_at, role')
        .eq('id', sbUser.id)
        .maybeSingle();

    if (profile == null) return null;

    // 1. Verificar sesión de un solo dispositivo
    final deviceId = await _getDeviceId();
    final activeDevice = profile['active_device_id'] as String?;
    if (activeDevice != null && activeDevice != deviceId) {
      // Otro dispositivo inició sesión — cerrar esta sesión
      await _client.auth.signOut();
      return null;
    }

    // 2. Verificar inactividad (2 horas)
    final lastActiveStr = profile['last_active_at'] as String?;
    if (lastActiveStr != null) {
      final lastActive = DateTime.parse(lastActiveStr);
      final diff = DateTime.now().difference(lastActive);
      if (diff.inHours >= 2) {
        await _client.auth.signOut();
        return null;
      }
    }

    // Sesión válida — actualizar timestamp de última actividad
    await _client.from('profiles').update({
      'last_active_at': DateTime.now().toIso8601String(),
    }).eq('id', sbUser.id);

    return _toUser(sbUser);
  }

  // Llamar cada vez que el usuario interactúa con la app
  Future<void> refreshActivity() async {
    final user = _client.auth.currentUser;
    if (user == null) return;
    await _client.from('profiles').update({
      'last_active_at': DateTime.now().toIso8601String(),
    }).eq('id', user.id);
  }

  @override
  Future<List<User>> getUsers() async {
    final data = await _client.from('profiles').select();
    final users = <User>[];
    for (final row in (data as List)) {
      users.add(User(
        id: row['id'],
        email: row['email'] ?? '',
        username: row['username'] ?? '',
        firstName: row['first_name'] ?? '',
        lastName: row['last_name'] ?? '',
        role: row['role'] ?? 'user',
      ));
    }
    return users;
  }

  @override
  Future<void> updateUser(User user, {String? password}) async {
    // Actualizar datos en el perfil
    await _client.from('profiles').update({
      'first_name': user.firstName,
      'last_name': user.lastName,
      'username': user.username,
      'email': user.email,
    }).eq('id', user.id);

    // Si se cambia la contraseña, actualizarla en Supabase Auth
    if (password != null && password.isNotEmpty) {
      await _client.auth.updateUser(sb.UserAttributes(password: password));
    }
  }

  @override
  Future<void> deleteUser(String id) async {
    // Sólo admins pueden borrar usuarios. Usamos una Function de Supabase.
    await _client.from('profiles').delete().eq('id', id);
  }
}
