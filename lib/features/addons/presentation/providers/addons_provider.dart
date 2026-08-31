import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../providers.dart';
import '../../domain/entities/addon.dart';
import '../../domain/repositories/addon_repository.dart';

final addonsProvider =
    StateNotifierProvider<AddonsController, AsyncValue<List<InstalledAddon>>>(
  (ref) {
    final repo = ref.watch(addonRepositoryProvider);
    return AddonsController(repo);
  },
);

class AddonsController extends StateNotifier<AsyncValue<List<InstalledAddon>>> {
  final AddonRepository _repository;
  AddonsController(this._repository) : super(const AsyncValue.loading()) {
    load();
  }

  Future<void> load() async {
    state = const AsyncValue.loading();
    try {
      final addons = await _repository.getInstalledAddons();
      state = AsyncValue.data(addons);
    } catch (e, s) {
      state = AsyncValue.error(e, s);
    }
  }

  Future<void> install({
    required String name,
    required String manifestUrl,
  }) async {
    await _repository.installAddon(name: name, manifestUrl: manifestUrl);
    await load();
  }

  Future<void> remove(String id) async {
    await _repository.removeAddon(id);
    await load();
  }

  bool get hasAddons =>
      state.valueOrNull?.isNotEmpty ?? false;
}
