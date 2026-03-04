import '../entities/user.dart';

abstract class AuthRepository {
  Future<User?> login(String identifier, String password);
  Future<User?> register({
    required String firstName,
    required String lastName,
    required String email,
    required String username,
    required String password,
  });
  Future<void> logout();
  Future<User?> getCurrentUser();
  Future<List<User>> getUsers();
  Future<void> updateUser(User user, {String? password});
  Future<void> deleteUser(String id);
}
