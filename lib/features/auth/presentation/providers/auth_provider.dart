import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide User;
import '../../domain/repositories/auth_repository.dart';
import '../../domain/entities/user.dart';
import '../../../../providers.dart';
import '../../data/repositories/auth_repository_supabase_impl.dart';

final authStateProvider = StateNotifierProvider<AuthController, User?>((ref) {
  final repo = ref.watch(authRepositoryProvider);
  return AuthController(repo);
});

class AuthController extends StateNotifier<User?> {
  final AuthRepository _repository;

  AuthController(this._repository) : super(null);

  Future<void> checkStatus() async {
    state = await _repository.getCurrentUser();
  }

  Future<bool> login(String identifier, String password) async {
    final user = await _repository.login(identifier, password);
    if (user != null) {
      state = user;
      return true;
    }
    return false;
  }

  Future<bool> register({
    required String firstName,
    required String lastName,
    required String email,
    required String username,
    required String password,
  }) async {
    final user = await _repository.register(
      firstName: firstName,
      lastName: lastName,
      email: email,
      username: username,
      password: password,
    );
    if (user != null) {
      state = user;
      return true;
    }
    return false;
  }

  Future<void> logout() async {
    await _repository.logout();
    state = null;
  }

  // Llama esto cuando el usuario interactúa con la app para resetear inactividad
  Future<void> refreshActivity() async {
    if (state == null) return;
    final repo = _repository;
    if (repo is AuthRepositorySupabaseImpl) {
      await repo.refreshActivity();
    }
  }

  Future<bool> updateProfile({
    required String firstName,
    required String lastName,
    required String email,
    required String username,
  }) async {
    if (state == null) return false;
    
    final updatedUser = User(
      id: state!.id,
      firstName: firstName,
      lastName: lastName,
      email: email,
      username: username,
      role: state!.role,
    );

    try {
      await _repository.updateUser(updatedUser);
      state = updatedUser;
      return true;
    } catch (e) {
      return false;
    }
  }

  Future<bool> changePassword(String currentPassword, String newPassword) async {
    if (state == null) return false;

    // Validar contraseña actual re-logueando
    final user = await _repository.login(state!.email, currentPassword);
    if (user == null) return false;

    try {
      await _repository.updateUser(state!, password: newPassword);
      return true;
    } catch (e) {
      return false;
    }
  }

  Future<void> updateOnlineStatus(bool isOnline) async {
    await _repository.updateOnlineStatus(isOnline);
  }

  Future<bool> sendRecoveryOtp(String email) async {
    return await _repository.sendRecoveryOtp(email);
  }

  Future<bool> verifyRecoveryOtp(String email, String token) async {
    final success = await _repository.verifyRecoveryOtp(email, token);
    // No actualizamos el state aquí para evitar que el AuthWrapper redirija al Home
    // antes de que el usuario pueda escribir su nueva contraseña.
    return success;
  }

  Future<bool> resetPassword(String newPassword) async {
    // Si no hay perfil cargado (state es null), pero Supabase dice que hay un usuario autenticado,
    // intentamos resetear la contraseña directamente vía repository.
    final currentUserData = state ?? await _repository.getCurrentUser();
    
    // Si sigue siendo null, intentamos crear un usuario básico solo para el reset
    User? tempUser = currentUserData;
    if (tempUser == null) {
       // Intento de último recurso: ¿Hay sesión activa en el cliente?
       if (_repository is AuthRepositorySupabaseImpl) {
          final sbUser = Supabase.instance.client.auth.currentUser;
          if (sbUser != null) {
            tempUser = User(
              id: sbUser.id,
              firstName: '',
              lastName: '',
              email: sbUser.email ?? '',
              username: '',
              role: 'user',
            );
          }
       }
    }

    if (tempUser == null) return false;

    try {
      await _repository.updateUser(tempUser, password: newPassword);
      // Tras el reset, intentamos recargar el estado real
      state = await _repository.getCurrentUser();
      return true;
    } catch (_) {
      return false;
    }
  }
}
