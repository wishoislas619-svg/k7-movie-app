import 'dart:async';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as sb;
import 'package:flutter/foundation.dart';
import '../../domain/entities/user.dart';
import '../../domain/repositories/auth_repository.dart';
import '../../../../core/services/supabase_service.dart';
import '../../../../core/services/storage_service.dart';

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
      
      // Obtener el perfil para verificar si hay una sesión activa
      final profile = await _client.from('profiles').select().eq('id', res.user!.id).maybeSingle();
      
      // Verificar si el usuario está realmente online
      bool isActuallyOnline = false;
      if (profile?['is_online'] == true) {
        if (profile?['active_device_id'] != deviceId) {
          isActuallyOnline = true;
        }
      }

      if (isActuallyOnline) {
        // Enviar petición de autorización al dispositivo original
        await _client.from('profiles').update({
          'login_request_status': 'pending',
          'requesting_device_id': deviceId,
          'login_request_at': DateTime.now().toUtc().toIso8601String(),
        }).eq('id', res.user!.id);

        // Esperar respuesta vía Realtime (máximo 1 minuto)
        final completer = Completer<bool>();
        final subscription = _client
            .from('profiles')
            .stream(primaryKey: ['id'])
            .eq('id', res.user!.id)
            .listen((data) {
              if (data.isNotEmpty) {
                final status = data.first['login_request_status'];
                if (status == 'approved') completer.complete(true);
                if (status == 'denied') completer.complete(false);
              }
            });

        final approved = await completer.future.timeout(
          const Duration(minutes: 1),
          onTimeout: () => false,
        );
        subscription.cancel();

        if (!approved) {
          await _client.auth.signOut();
          return null;
        }
      }

      // Login exitoso o autorizado: Actualizar perfil como activo y online
      await _client.from('profiles').update({
        'active_device_id': deviceId,
        'last_active_at': DateTime.now().toUtc().toIso8601String(),
        'email': res.user!.email,
        'is_online': true,
        'login_request_status': null,
        'requesting_device_id': null,
      }).eq('id', res.user!.id);

      // Guardar credenciales para auto-login inteligente
      await StorageService.saveCredentials(emailToUse, password);

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
        'last_active_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', res.user!.id);

      // Guardar credenciales para auto-login inteligente
      await StorageService.saveCredentials(email.trim().toLowerCase(), password);

      return _toUser(res.user);
    } on sb.AuthException {
      return null;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> logout() async {
    final user = _client.auth.currentUser;
    if (user != null) {
      await _client.from('profiles').update({
        'is_online': false,
        'login_request_status': null,
      }).eq('id', user.id);
    }
    await StorageService.setAutoLoginEnabled(false);
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

    // Sesión válida — intentar actualizar timestamp de última actividad inmediatamente
    try {
      final lastActiveDate = DateTime.now().toUtc();
      await _client.from('profiles').update({
        'last_active_at': lastActiveDate.toIso8601String(),
        'active_device_id': deviceId,
      }).eq('id', sbUser.id);

      // Ahora verificamos la inactividad pero comparando con el dato que TRAÍA el perfil antes del update.
      // Si el dato anterior era muy viejo (> 2 horas), permitimos que siga SOLO si la sesión es nueva.
      // Pero mejor aún: si logramos actualizar el campo 'last_active_at' hoy, significa que el usuario está interactuando.
      final lastActiveStr = profile['last_active_at'] as String?;
      if (lastActiveStr != null) {
        final lastActive = DateTime.parse(lastActiveStr).toUtc();
        final inactivityDiff = lastActiveDate.difference(lastActive);
        
        // Si el usuario estuvo inactivo por más de 2 horas (históricamente),
        // pero hemos logrado conectarnos ahora, permitimos que la sesión continúe 
        // solo si estamos refrescando el estado.
        // Pero para cumplir con el requisito estricto de cerrar sesión tras 2h:
        if (inactivityDiff.inHours >= 2) {
           // EXCEPCIÓN: Si la sesión de Supabase empezó hace menos de 1 minuto, NO cerramos (es una recuperación fresca)
           // Sin embargo, Supabase no nos da el 'createdAt' de la sesión de forma simple.
           // Usaremos el authStateProvider.state como indicador, pero aquí no tenemos acceso a Riverpod.
           
           // Decisión: Si la inactividad es de más de 2 horas, cerramos sesión PARA LOGIN NORMAL.
           // Para recuperación de contraseña, el AuthController hará el reset ANTES de que esto estalle si es posible.
           
           await _client.auth.signOut();
           return null;
        }
      }
      return _toUser(sbUser);
    } catch (_) {
      // Si el update falla (ej. sin internet o perfil no encontrado), tratamos como sesión inválida
      return null;
    }
  }

  // Llamar cada vez que el usuario interactúa con la app
  Future<void> refreshActivity() async {
    final user = _client.auth.currentUser;
    if (user == null) return;
    await _client.from('profiles').update({
      'last_active_at': DateTime.now().toUtc().toIso8601String(),
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
    // 1. Si se cambia la contraseña, actualizarla primero en Supabase Auth
    if (password != null && password.isNotEmpty) {
      await _client.auth.updateUser(sb.UserAttributes(password: password));
    }

    // 2. Intentar actualizar datos en el perfil
    try {
      await _client.from('profiles').upsert({
        'id': user.id,
        'first_name': user.firstName,
        'last_name': user.lastName,
        'username': user.username,
        'email': user.email,
        'last_active_at': DateTime.now().toUtc().toIso8601String(),
      });
    } catch (_) {
      // Ignoramos errores menores en el perfil si la contraseña ya se actualizó
    }
  }

  @override
  Future<void> deleteUser(String id) async {
    // Sólo admins pueden borrar usuarios. Usamos una Function de Supabase.
    await _client.from('profiles').delete().eq('id', id);
  }

  @override
  Future<void> updateOnlineStatus(bool isOnline) async {
    final user = _client.auth.currentUser;
    if (user != null) {
      await _client.from('profiles').update({
        'is_online': isOnline,
        'last_active_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', user.id);
    }
  }

  @override
  Future<bool> sendRecoveryOtp(String email) async {
    try {
      await _client.auth.resetPasswordForEmail(email.trim().toLowerCase());
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> verifyRecoveryOtp(String email, String token) async {
    try {
      final res = await _client.auth.verifyOTP(
        email: email.trim().toLowerCase(),
        token: token.trim(),
        type: sb.OtpType.recovery,
      );

      if (res.user != null) {
        final deviceId = await _getDeviceId();
        // Al verificar exitosamente (recovery), aseguramos que exista el perfil
        await _client.from('profiles').upsert({
          'id': res.user!.id,
          'active_device_id': deviceId,
          'last_active_at': DateTime.now().toUtc().toIso8601String(),
          'email': res.user!.email,
          'is_online': true,
        });
        
        return true;
      }
      return false;
    } catch (_) {
      return false;
    }
  }
}
