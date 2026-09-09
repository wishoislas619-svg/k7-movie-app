import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:url_launcher/url_launcher.dart';

import '../providers/addons_provider.dart';

/// Pantalla estilo Stremio para configurar un addon (p.ej. Torrentio).
///
/// Abre el CSS de configuración en un webview integrado. Al terminar de
/// configurar, Torrentio muestra un enlace de instalación (un `manifest.json`
/// con la configuración embebida). La página captura ese enlace
/// automáticamente y permite instalarlo, o copiarlo para pegarlo.
class AddonConfigPage extends ConsumerStatefulWidget {
  const AddonConfigPage({super.key, required this.url});

  final String url;

  @override
  ConsumerState<AddonConfigPage> createState() => _AddonConfigPageState();
}

class _AddonConfigPageState extends ConsumerState<AddonConfigPage> {
  final TextEditingController _manualController = TextEditingController();
  bool _isLoading = true;
  String? _installUrl;
  bool _installing = false;

  @override
  void dispose() {
    _manualController.dispose();
    super.dispose();
  }

  bool _isManifest(String url) => url.contains('manifest.json');

  void _captureInstallUrl(String url) {
    if (url.isEmpty || !_isManifest(url)) return;
    if (_installUrl == url) return;
    setState(() => _installUrl = url);
  }

  Future<void> _install(String manifestUrl) async {
    final trimmed = manifestUrl.trim();
    if (trimmed.isEmpty) return;
    setState(() => _installing = true);
    try {
      await ref.read(addonsProvider.notifier).install(
            name: 'Torrentio',
            manifestUrl: trimmed,
          );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Addon configurado e instalado.')),
        );
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (mounted) {
        setState(() => _installing = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error al instalar: $e')),
        );
      }
    }
  }

  Future<void> _openInBrowser() async {
    final uri = Uri.tryParse(widget.url);
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: const Text('Configurar addon',
            style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1.5)),
        actions: [
          IconButton(
            icon: const Icon(Icons.open_in_new),
            tooltip: 'Abrir en navegador',
            onPressed: _openInBrowser,
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: InAppWebView(
              initialUrlRequest: URLRequest(url: WebUri(widget.url)),
              initialSettings: InAppWebViewSettings(
                javaScriptEnabled: true,
                useShouldOverrideUrlLoading: true,
                mediaPlaybackRequiresUserGesture: false,
              ),
              shouldOverrideUrlLoading: (controller, navigationAction) async {
                final url = navigationAction.request.url.toString();
                _captureInstallUrl(url);
                // Si es un manifest (enlace de instalación), no navegamos:
                // bloqueamos y mostramos el enlace para instalar.
                if (_isManifest(url)) {
                  return NavigationActionPolicy.CANCEL;
                }
                return NavigationActionPolicy.ALLOW;
              },
              onLoadStart: (controller, url) {
                if (url != null) _captureInstallUrl(url.toString());
              },
              onLoadStop: (controller, url) {
                setState(() => _isLoading = false);
              },
              onProgressChanged: (controller, progress) {
                if (progress == 100) setState(() => _isLoading = false);
                controller.getUrl().then((u) {
                  if (u != null) _captureInstallUrl(u.toString());
                });
              },
              onRenderProcessGone: (controller, detail) {
                if (mounted) setState(() => _isLoading = false);
              },
            ),
          ),
          if (_isLoading)
            const LinearProgressIndicator(
              minHeight: 2,
              color: Color(0xFF00A3FF),
            ),
          if (_installUrl != null)
            _buildInstallBanner()
          else
            _buildManualHint(),
        ],
      ),
    );
  }

  Widget _buildInstallBanner() {
    final bottomInset = MediaQuery.of(context).viewPadding.bottom;
    return Container(
      width: double.infinity,
      padding: EdgeInsets.fromLTRB(12, 12, 12, 12 + bottomInset),
      color: const Color(0xFF00FF87).withValues(alpha: 0.08),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Configuración detectada. Instala el addon:',
            style: TextStyle(
                color: Color(0xFF00FF87),
                fontWeight: FontWeight.bold,
                fontSize: 13),
          ),
          const SizedBox(height: 6),
          Text(
            _installUrl!,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white70, fontSize: 11),
          ),
          const SizedBox(height: 10),
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF00A3FF),
              padding: const EdgeInsets.symmetric(vertical: 12),
            ),
            onPressed: _installing
                ? null
                : () => _install(_installUrl!),
            icon: _installing
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white),
                  )
                : const Icon(Icons.download_done),
            label: Text(_installing ? 'Instalando...' : 'Instalar addon',
                style: const TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  Widget _buildManualHint() {
    final bottomInset = MediaQuery.of(context).viewPadding.bottom;
    return Container(
      width: double.infinity,
      padding: EdgeInsets.fromLTRB(12, 12, 12, 12 + bottomInset),
      color: const Color(0xFF1A1A1A),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Configura las opciones y al final copia el enlace de instalación '
            '(termina en manifest.json). Puedes pegarlo aquí:',
            style: TextStyle(color: Colors.white54, fontSize: 12, height: 1.4),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _manualController,
            style: const TextStyle(color: Colors.white, fontSize: 12),
            decoration: InputDecoration(
              hintText: 'https://torrentio.strem.fun/.../manifest.json',
              hintStyle: const TextStyle(color: Colors.white38, fontSize: 12),
              filled: true,
              fillColor: const Color(0xFF0E0E0E),
              isDense: true,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide.none,
              ),
            ),
            onChanged: (v) {
              final t = v.trim();
              if (t.isNotEmpty && _isManifest(t)) {
                setState(() => _installUrl = t);
              }
            },
          ),
        ],
      ),
    );
  }
}
