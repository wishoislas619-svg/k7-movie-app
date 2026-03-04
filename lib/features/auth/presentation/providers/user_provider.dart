import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:state_notifier/state_notifier.dart';
import '../../domain/entities/user.dart';
import '../../domain/repositories/auth_repository.dart';
import '../../../../providers.dart';

final usersProvider = StateNotifierProvider<UserController, AsyncValue<List<User>>>((ref) {
  final repository = ref.watch(authRepositoryProvider);
  return UserController(repository);
});

class UserController extends StateNotifier<AsyncValue<List<User>>> {
  final AuthRepository _repository;

  UserController(this._repository) : super(const AsyncValue.loading()) {
    loadUsers();
  }

  Future<void> loadUsers() async {
    state = const AsyncValue.loading();
    try {
      final users = await _repository.getUsers();
      state = AsyncValue.data(users);
    } catch (e, s) {
      state = AsyncValue.error(e, s);
    }
  }

  Future<void> updateUser(User user, {String? password}) async {
    try {
      await _repository.updateUser(user, password: password);
      await loadUsers();
    } catch (e, s) {
      state = AsyncValue.error(e, s);
    }
  }

  Future<void> deleteUser(String id) async {
    try {
      await _repository.deleteUser(id);
      await loadUsers();
    } catch (e, s) {
      state = AsyncValue.error(e, s);
    }
  }
}
