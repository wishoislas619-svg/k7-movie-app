// DEPRECATED: Este repositorio ya no se usa.
// La autenticación ahora es gestionada por AuthRepositorySupabaseImpl.
// Se conserva este archivo como stub para evitar errores de compilación.

import '../../../../core/utils/sqlite_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../domain/entities/user.dart';
import '../../domain/repositories/auth_repository.dart';

@Deprecated('Usa AuthRepositorySupabaseImpl')
class AuthRepositorySqliteImpl implements AuthRepository {
  final SqliteService _sqliteService;
  final SharedPreferences _prefs;

  AuthRepositorySqliteImpl(this._sqliteService, this._prefs);

  @override
  Future<User?> login(String identifier, String password) async => null;

  @override
  Future<User?> register({
    required String firstName,
    required String lastName,
    required String email,
    required String username,
    required String password,
  }) async => null;

  @override
  Future<void> logout() async {}

  @override
  Future<User?> getCurrentUser() async => null;

  @override
  Future<List<User>> getUsers() async => [];

  @override
  Future<void> updateUser(User user, {String? password}) async {}

  @override
  Future<void> deleteUser(String id) async {}
}
