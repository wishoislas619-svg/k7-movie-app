import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../cast/presentation/widgets/cast_button.dart';
import '../../../auth/presentation/providers/auth_provider.dart';
import '../../../../core/services/ad_service.dart';
import 'package:uuid/uuid.dart';
import 'dart:async';

/// Botón de Cast simplificado para usar fuera del reproductor (en details pages y downloads)
class CastButtonOverlay extends ConsumerStatefulWidget {
  final String videoUrl;
  final String? localFilePath;
  final String title;
  final String? imageUrl;
  final Map<String, String>? headers;
  final int algorithm;

  const CastButtonOverlay({
    super.key,
    required this.videoUrl,
    this.localFilePath,
    required this.title,
    this.imageUrl,
    this.headers,
    this.algorithm = 1,
  });

  @override
  ConsumerState<CastButtonOverlay> createState() => _CastButtonOverlayState();
}

class _CastButtonOverlayState extends ConsumerState<CastButtonOverlay> {
  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: _onCastPressed,
      icon: const Icon(Icons.cast, color: Colors.white70, size: 24),
      tooltip: 'Transmitir a TV',
    );
  }

  Future<void> _onCastPressed() async {
    // Verificar anuncio primero
    final appUser = ref.read(authStateProvider);
    final role = appUser?.role.toLowerCase() ?? 'user';
    final isAdminOrVip = role == 'admin' || role == 'uservip';

    if (!isAdminOrVip) {
      final adCompleter = Completer<bool>();
      
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => const Center(
          child: CircularProgressIndicator(color: Color(0xFF00A3FF)),
        ),
      );

      AdService.showRewardedAd(
        ticketId: const Uuid().v4(),
        onAdWatched: (_) => adCompleter.complete(true),
        onAdFailed: (_) => adCompleter.complete(false),
        onAdDismissedIncomplete: () => adCompleter.complete(false),
      );

      final result = await adCompleter.future;
      if (mounted && Navigator.of(context).canPop()) Navigator.of(context).pop();
      if (!result) return;
    }

    if (!mounted) return;

    // Abrir el selector de cast
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF141414),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (_) => CastButton(
        videoUrl: widget.videoUrl,
        localFilePath: widget.localFilePath,
        title: widget.title,
        imageUrl: widget.imageUrl,
        headers: widget.headers,
        algorithm: widget.algorithm,
        showImmediately: true,
      ),
    );
  }
}
