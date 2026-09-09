import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../../../features/auth/presentation/providers/auth_provider.dart';
import 'ad_service.dart';

/// Gate de anuncio recompensado para acciones de torrent (play, descargar o
/// transmitir). Los usuarios VIP/admin (`admin`/`uservip`) pasan sin anuncio;
/// los usuarios normales deben ver un anuncio recompensado completo antes de
/// que se ejecute la acción. Devuelve `true` si se puede continuar.
Future<bool> requireRewardedAdForTorrent(
  BuildContext context,
  WidgetRef ref, {
  required String mediaId,
  required String mediaType,
}) async {
  final appUser = ref.read(authStateProvider);
  final role = appUser?.role.toLowerCase() ?? 'user';
  final isAdminOrVip = role == 'admin' || role == 'uservip';
  if (isAdminOrVip) return true;

  final supabaseUser = Supabase.instance.client.auth.currentUser;
  if (supabaseUser == null) return true;

  // Diálogo de carga del anuncio.
  final loadingDialogContext = Completer<BuildContext>();
  showDialog(
    context: context,
    barrierDismissible: false,
    builder: (ctx) {
      if (!loadingDialogContext.isCompleted) {
        loadingDialogContext.complete(ctx);
      }
      return Center(
        child: Container(
          padding: const EdgeInsets.all(24),
          decoration: const BoxDecoration(
            color: Color(0xFF1A1A1A),
            borderRadius: BorderRadius.all(Radius.circular(16)),
          ),
          child: const Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(color: Color(0xFF00A3FF)),
              SizedBox(height: 16),
              Text(
                'Cargando anuncio...',
                style: TextStyle(color: Colors.white, fontSize: 14),
              ),
            ],
          ),
        ),
      );
    },
  ).then((_) {
    if (!loadingDialogContext.isCompleted) {
      loadingDialogContext.completeError("Dialog dismissed or failed");
    }
  });

  // Timeout de seguridad para el contexto del diálogo.
  Timer(const Duration(seconds: 2), () {
    if (!loadingDialogContext.isCompleted) {
      loadingDialogContext.completeError("Dialog timeout");
    }
  });

  final ticketId = const Uuid().v4();
  bool adWatched = false;
  final adCompleter = Completer<bool>();

  try {
    // media_id debe ser UUID válido; si no lo es (p. ej. un tmdbId), generar uno
    // determinístico basado en el original, igual que hace VideoPlayerPage.
    String mediaIdForTicket = mediaId;
    final uuidRegex = RegExp(
      r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
      caseSensitive: false,
    );
    if (!uuidRegex.hasMatch(mediaIdForTicket)) {
      mediaIdForTicket = const Uuid().v5(const Uuid().v4(), mediaIdForTicket);
    }

    await Supabase.instance.client.from('ad_tickets').insert({
      'id': ticketId,
      'user_id': supabaseUser.id,
      'media_type': mediaType,
      'media_id': mediaIdForTicket,
    });

    AdService.showRewardedAd(
      ticketId: ticketId,
      onAdWatched: (String tid) {
        adWatched = true;
        if (!adCompleter.isCompleted) adCompleter.complete(true);
      },
      onAdFailed: (String err) {
        if (!adCompleter.isCompleted) adCompleter.complete(false);
      },
      onAdDismissedIncomplete: () {
        if (!adCompleter.isCompleted) adCompleter.complete(false);
      },
    );
  } catch (e) {
    if (!adCompleter.isCompleted) adCompleter.complete(false);
  }

  final result = await adCompleter.future;

  // Cerrar el diálogo de carga usando su propio context.
  try {
    final ctxToClose = await loadingDialogContext.future;
    if (ctxToClose.mounted && Navigator.canPop(ctxToClose)) {
      Navigator.pop(ctxToClose);
    }
  } catch (e) {
    debugPrint(
      "No se pudo cerrar el diálogo de anuncio (posiblemente no se mostró): $e",
    );
  }

  if (result && adWatched) return true;

  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
            'Debes ver el anuncio completo para reproducir o descargar.'),
        backgroundColor: Colors.redAccent,
      ),
    );
  }
  return false;
}