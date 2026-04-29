import 'dart:io';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:unity_ads_plugin/unity_ads_plugin.dart';
import 'package:flutter/services.dart';

class AdService {
  static String get rewardedAdUnitId {
    if (Platform.isAndroid) {
      return 'ca-app-pub-3088460333344148/9605033713';
    } else if (Platform.isIOS) {
      return 'ca-app-pub-3940256099942544/1712485313';
    }
    throw UnsupportedError('Platform no soportada');
  }

  static Future<void> showRewardedAd({
    required String ticketId,
    required Function(String ticketId) onAdWatched, 
    required Function(String error) onAdFailed, 
    required Function() onAdDismissedIncomplete, 
  }) async {

    // 1. INTENTO PRIMARIO: Google AdMob
    RewardedAd.load(
      adUnitId: rewardedAdUnitId,
      request: const AdRequest(),
      rewardedAdLoadCallback: RewardedAdLoadCallback(
        onAdLoaded: (RewardedAd ad) {
          ad.setServerSideOptions(ServerSideVerificationOptions(customData: ticketId));
          bool userEarnedReward = false;

          ad.fullScreenContentCallback = FullScreenContentCallback(
            onAdDismissedFullScreenContent: (RewardedAd ad) {
              ad.dispose();
              // Restaurar modo normal después del anuncio
              SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
              if (userEarnedReward) {
                onAdWatched(ticketId); 
              } else {
                onAdDismissedIncomplete(); 
              }
            },
            onAdFailedToShowFullScreenContent: (RewardedAd ad, AdError error) {
              ad.dispose();
              // Restaurar modo normal si falla el anuncio
              SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
              print('AdMob FullScreen Falló (${error.message}). -> Fallback a Unity Ads');
              _showUnityFallback(ticketId, onAdWatched, onAdFailed, onAdDismissedIncomplete);
            },
          );

          // Asegurar pantalla completa total durante el anuncio (ocultar botones de gestos)
          SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
          ad.show(onUserEarnedReward: (AdWithoutView ad, RewardItem reward) {
             userEarnedReward = true; 
          });
        },
        onAdFailedToLoad: (LoadAdError error) {
          print('AdMob Falló al Cargar (Código: ${error.code}). -> Fallback a Unity Ads');
          // 2. INTENTO SECUNDARIO (FALLBACK): Unity Ads
          _showUnityFallback(ticketId, onAdWatched, onAdFailed, onAdDismissedIncomplete);
        },
      ),
    );
  }

  static void _showUnityFallback(
    String ticketId,
    Function(String ticketId) onAdWatched, 
    Function(String error) onAdFailed, 
    Function() onAdDismissedIncomplete,
  ) {
    print('Intentando mostrar Unity Ads...');
    // Asegurar pantalla completa total durante el anuncio (ocultar botones de gestos)
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    UnityAds.showVideoAd(
      placementId: Platform.isAndroid ? 'Rewarded_Android' : 'Rewarded_iOS',
      onComplete: (placementId) {
        print('Unity Ads Completado ($placementId)');
        // Restaurar modo normal después del anuncio
        SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
        onAdWatched(ticketId); // Recompensa otorgada
      },
      onFailed: (placementId, error, message) {
        print('Unity Ads Falló: $message ($error)');
        // Restaurar modo normal si falla el anuncio
        SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
        onAdFailed('No hay anuncios de AdMob ni de Unity disponibles en este momento. Intenta más tarde.');
      },
      onStart: (placementId) => print('Unity Ads Iniciado ($placementId)'),
      onClick: (placementId) => print('Unity Ads Clic ($placementId)'),
      onSkipped: (placementId) {
        print('Unity Ads Saltado ($placementId)');
        // Restaurar modo normal si se salta el anuncio
        SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
        onAdDismissedIncomplete();
      },
    );
  }
}
