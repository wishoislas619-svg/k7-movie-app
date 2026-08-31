import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../shared/widgets/energy_flow_border.dart';
import '../../domain/entities/addon.dart';
import '../providers/addons_provider.dart';
import 'addon_config_page.dart';

class AddonsManagerPage extends ConsumerStatefulWidget {
  const AddonsManagerPage({super.key});

  @override
  ConsumerState<AddonsManagerPage> createState() => _AddonsManagerPageState();
}

class _AddonsManagerPageState extends ConsumerState<AddonsManagerPage> {
  final TextEditingController _urlController = TextEditingController();
  final TextEditingController _nameController = TextEditingController();
  bool _installing = false;
  String? _error;

  static const String _presetManifest =
      'https://torrentio.strem.fun/manifest.json';

  static const String _torrentioConfigureUrl =
      'https://torrentio.strem.fun/configure';

  void _openConfig(String url) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => AddonConfigPage(url: url)),
    );
  }

  /// Devuelve la mejor URL de configuración para un addon instalado.
  /// Torrentio usa su página de configuración; el resto intenta derivar
  /// un `/configure` a partir de su manifest (mejor esfuerzo).
  String _configUrlFor(InstalledAddon addon) {
    final manifest = addon.manifestUrl;
    if (manifest.contains('torrentio.strem.fun')) {
      return _torrentioConfigureUrl;
    }
    // https://host/{config}/manifest.json  ->  https://host/{config}/configure
    final manifestUri = Uri.tryParse(manifest);
    if (manifestUri != null &&
        (manifestUri.path.endsWith('manifest.json') ||
            manifestUri.path.endsWith('manifest.json/'))) {
      final base =
          manifestUri.path.replaceFirst(RegExp(r'/manifest\.json/?$'), '');
      return '${manifestUri.scheme}://${manifestUri.host}$base/configure';
    }
    return manifest.replaceFirst(RegExp(r'/manifest\.json/?$'), '/configure');
  }

  Future<void> _installManifest(String manifestUrl) async {
    if (manifestUrl.trim().isEmpty) return;
    setState(() {
      _installing = true;
      _error = null;
    });
    try {
      final name = _nameController.text.trim().isNotEmpty
          ? _nameController.text.trim()
          : 'Torrentio';
      await ref.read(addonsProvider.notifier).install(
            name: name,
            manifestUrl: manifestUrl.trim(),
          );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Addon instalado correctamente')),
        );
        _urlController.clear();
        _nameController.clear();
      }
    } catch (e) {
      setState(() => _error = 'Error al instalar: $e');
    } finally {
      if (mounted) setState(() => _installing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final addonsAsync = ref.watch(addonsProvider);
    final hasAddons = addonsAsync.valueOrNull?.isNotEmpty ?? false;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: const Text('Addons',
            style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 2)),
      ),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
          children: [
          _buildCard(
            title: '¿Qué es un addon?',
            body:
                'Los addons añaden fuentes de reproducción (como Torrentio). '
                'Torrentio busca torrents (también vía servicios debrid como Real-Debrid para enlaces directos).',
            accent: Colors.blueAccent,
          ),
          const SizedBox(height: 16),
          if (!hasAddons)
            _buildInstallTorrentioCard()
          else
            _buildAlreadyInstalledCard(),
          const SizedBox(height: 16),
          _buildManualInstallCard(),
          const SizedBox(height: 24),
          Text('Addons instalados',
              style: TextStyle(
                  color: Colors.white70,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.5)),
          const SizedBox(height: 8),
          addonsAsync.when(
            data: (addons) =>
                addons.isEmpty ? _empty() : _addonList(addons),
            loading: () => const Center(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: CircularProgressIndicator(color: Color(0xFF00A3FF)),
              ),
            ),
            error: (e, _) => Padding(
              padding: const EdgeInsets.all(16),
              child: Text('Error: $e', style: const TextStyle(color: Colors.redAccent)),
            ),
          ),
        ],
        ),
      ),
    );
  }

  Widget _empty() {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 16),
      child: Text('No tienes addons instalados.',
          style: TextStyle(color: Colors.white38)),
    );
  }

  Widget _buildCard({
    required String title,
    required String body,
    required Color accent,
  }) {
    return EnergyFlowBorder(
      borderRadius: 14,
      borderWidth: 1,
      duration: const Duration(seconds: 6),
      backgroundColor: const Color(0xFF141414),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title,
                style: TextStyle(
                    color: accent,
                    fontWeight: FontWeight.bold,
                    fontSize: 16)),
            const SizedBox(height: 8),
            Text(body, style: const TextStyle(color: Colors.white70, height: 1.4)),
          ],
        ),
      ),
    );
  }

  Widget _buildInstallTorrentioCard() {
    return EnergyFlowBorder(
      borderRadius: 14,
      borderWidth: 1.2,
      duration: const Duration(seconds: 5),
      backgroundColor: const Color(0xFF0E1B2A),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Instalar Torrentio',
                style: TextStyle(
                    color: Color(0xFF00A3FF),
                    fontWeight: FontWeight.bold,
                    fontSize: 17)),
            const SizedBox(height: 8),
            const Text(
              'Torrentio agrega fuentes de torrents para tus películas. '
              'Para obtener enlaces directos (rápidos y con tu IP protegida), '
              'configúralo con un servicio debrid como Real-Debrid.',
              style: TextStyle(color: Colors.white70, height: 1.4),
            ),
            const SizedBox(height: 12),
            const Text(
              'Consejo: Configura Torrentio con tu servicio debrid en:',
              style: TextStyle(color: Colors.white54, fontSize: 13),
            ),
            const SizedBox(height: 4),
            SelectableText('https://torrentio.strem.fun',
                style: const TextStyle(color: Color(0xFF00A3FF))),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF00A3FF),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                onPressed: () => _openConfig(_torrentioConfigureUrl),
                icon: const Icon(Icons.tune),
                label: const Text('Configurar Torrentio',
                    style: TextStyle(fontWeight: FontWeight.bold)),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: Color(0xFF00A3FF)),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
                onPressed: _installing
                    ? null
                    : () => _installManifest(_presetManifest),
                icon: _installing
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white),
                      )
                    : const Icon(Icons.download_done),
                label: const Text('Instalar rápido (por defecto)',
                    style: TextStyle(color: Color(0xFF00A3FF))),
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(_error!,
                    style: const TextStyle(color: Colors.redAccent, fontSize: 12)),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildAlreadyInstalledCard() {
    return _buildCard(
      title: 'Torrentio instalado',
      body:
          'Ya tienes Torrentio. Puedes añadir más addons o quitar los existentes '
          'desde la lista inferior.',
      accent: const Color(0xFF00FF87),
    );
  }

  Widget _buildManualInstallCard() {
    return EnergyFlowBorder(
      borderRadius: 14,
      borderWidth: 1,
      duration: const Duration(seconds: 7),
      backgroundColor: const Color(0xFF141414),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Instalar addon manualmente',
                style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 16)),
            const SizedBox(height: 8),
            TextField(
              controller: _nameController,
              style: const TextStyle(color: Colors.white),
              decoration: _inputDecoration('Nombre (opcional)'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _urlController,
              style: const TextStyle(color: Colors.white),
              decoration:
                  _inputDecoration('URL del manifest (termina en manifest.json)'),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: Color(0xFF00A3FF)),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                onPressed: _installing
                    ? null
                    : () => _installManifest(_urlController.text),
                child: const Text('Añadir addon',
                    style: TextStyle(color: Color(0xFF00A3FF))),
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(_error!,
                    style: const TextStyle(color: Colors.redAccent, fontSize: 12)),
              ),
          ],
        ),
      ),
    );
  }

  Widget _addonList(List<InstalledAddon> addons) {
    return Column(
      children: addons.map((addon) {
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: EnergyFlowBorder(
            borderRadius: 12,
            borderWidth: 1,
            duration: const Duration(seconds: 8),
            backgroundColor: const Color(0xFF141414),
            child: ListTile(
              leading: const Icon(Icons.extension, color: Color(0xFF00A3FF)),
              title: Text(addon.name,
                  style: const TextStyle(color: Colors.white)),
              subtitle: SelectableText(addon.manifestUrl,
                  style: const TextStyle(color: Colors.white38, fontSize: 11)),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: 'Configurar addon',
                    icon: const Icon(Icons.settings, color: Color(0xFF00A3FF)),
                    onPressed: () => _openConfig(_configUrlFor(addon)),
                  ),
                  IconButton(
                    tooltip: 'Quitar addon',
                    icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
                    onPressed: () =>
                        ref.read(addonsProvider.notifier).remove(addon.id),
                  ),
                ],
              ),
            ),
          ),
        );
      }).toList(),
    );
  }

  InputDecoration _inputDecoration(String hint) {
    return InputDecoration(
      hintText: hint,
      hintStyle: const TextStyle(color: Colors.white38),
      filled: true,
      fillColor: const Color(0xFF1A1A1A),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide.none,
      ),
    );
  }
}
