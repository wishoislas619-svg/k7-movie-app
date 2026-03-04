import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../domain/repositories/auth_repository.dart';
import '../../domain/entities/user.dart';
import '../../../../providers.dart';

final authStateProvider = StateNotifierProvider<AuthController, User?>((ref) {
  final repo = ref.watch(authRepositoryProvider);
  return AuthController(repo);
});

class AuthController extends StateNotifier<User?> {
  final AuthRepository _repository;

  AuthController(this._repository) : super(null) {
    checkStatus();
  }

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
}
