import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import '../../../../core/constants/app_constants.dart';
import '../../../../core/utils/sqlite_service.dart';
import '../../domain/entities/user.dart';
import '../../domain/repositories/auth_repository.dart';
import '../models/user_model.dart';

class AuthRepositorySqliteImpl implements AuthRepository {
  final SqliteService _sqliteService;
  final SharedPreferences _prefs;

  AuthRepositorySqliteImpl(this._sqliteService, this._prefs);

  @override
  Future<User?> login(String identifier, String password) async {
    // Check for hardcoded admin
    if (identifier == AppConstants.adminUser && password == AppConstants.adminPassword) {
      final admin = User(
        id: 'admin-id',
        firstName: 'Admin',
        lastName: 'User',
        email: AppConstants.adminUser,
        username: AppConstants.adminUser,
        role: AppConstants.roleAdmin,
      );
      await _saveSession(admin);
      return admin;
    }

    final db = await _sqliteService.database;
    final List<Map<String, dynamic>> maps = await db.query(
      'users',
      where: '(email = ? OR username = ?) AND password = ?',
      whereArgs: [identifier, identifier, password],
    );

    if (maps.isNotEmpty) {
      final user = UserModel.fromMap(maps.first);
      await _saveSession(user);
      return user;
    }
    return null;
  }

  @override
  Future<User?> register({
    required String firstName,
    required String lastName,
    required String email,
    required String username,
    required String password,
  }) async {
    // Check if email or username corresponds to admin (which cannot register)
    if (email == AppConstants.adminUser || username == AppConstants.adminUser) return null;

    final db = await _sqliteService.database;
    
    // Check if user already exists
    final List<Map<String, dynamic>> existing = await db.query(
      'users',
      where: 'email = ? OR username = ?',
      whereArgs: [email, username],
    );
    if (existing.isNotEmpty) return null;

    final id = const Uuid().v4();
    final userMap = {
      'id': id,
      'firstName': firstName,
      'lastName': lastName,
      'email': email,
      'username': username,
      'password': password,
      'role': AppConstants.roleUser,
    };

    await db.insert('users', userMap);
    
    final user = UserModel.fromMap(userMap);
    await _saveSession(user);
    return user;
  }

  @override
  Future<void> logout() async {
    await _prefs.remove(AppConstants.keyIsLoggedIn);
    await _prefs.remove(AppConstants.keyUserRole);
    await _prefs.remove(AppConstants.keyUserData);
  }

  @override
  Future<User?> getCurrentUser() async {
    final isLoggedIn = _prefs.getBool(AppConstants.keyIsLoggedIn) ?? false;
    if (!isLoggedIn) return null;

    final identifier = _prefs.getString(AppConstants.keyUserData);
    if (identifier != null) {
      final role = _prefs.getString(AppConstants.keyUserRole);
      
      if (role == AppConstants.roleAdmin) {
        return User(
          id: 'admin-id',
          firstName: 'Admin',
          lastName: 'User',
          email: AppConstants.adminUser,
          username: AppConstants.adminUser,
          role: AppConstants.roleAdmin,
        );
      }
      
      final db = await _sqliteService.database;
      final List<Map<String, dynamic>> maps = await db.query(
        'users',
        where: 'email = ? OR username = ?',
        whereArgs: [identifier, identifier],
      );
      
      if (maps.isNotEmpty) {
        return UserModel.fromMap(maps.first);
      }
    }
    return null;
  }

  Future<void> _saveSession(User user) async {
    await _prefs.setBool(AppConstants.keyIsLoggedIn, true);
    await _prefs.setString(AppConstants.keyUserRole, user.role);
    await _prefs.setString(AppConstants.keyUserData, user.email);
  }

  @override
  Future<List<User>> getUsers() async {
    final db = await _sqliteService.database;
    final List<Map<String, dynamic>> maps = await db.query('users');
    return maps.map((map) => UserModel.fromMap(map)).toList();
  }

  @override
  Future<void> updateUser(User user, {String? password}) async {
    final db = await _sqliteService.database;
    final map = {
      'firstName': user.firstName,
      'lastName': user.lastName,
      'email': user.email,
      'username': user.username,
      'role': user.role,
    };
    if (password != null && password.isNotEmpty) {
      map['password'] = password;
    }
    await db.update(
      'users',
      map,
      where: 'id = ?',
      whereArgs: [user.id],
    );
  }

  @override
  Future<void> deleteUser(String id) async {
    final db = await _sqliteService.database;
    await db.delete(
      'users',
      where: 'id = ?',
      whereArgs: [id],
    );
  }
}
