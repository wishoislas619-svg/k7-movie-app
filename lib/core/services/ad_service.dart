import 'dart:io';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:uuid/uuid.dart';

class AdService {
  // ATENCIÓN: Estos son los IDs de prueba oficiales de Google.
  // Cuando lances la app a producción, debes cambiarlos por tus bloques de AdMob reales.
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

    RewardedAd.load(
      adUnitId: rewardedAdUnitId,
      request: const AdRequest(),
      rewardedAdLoadCallback: RewardedAdLoadCallback(
        onAdLoaded: (RewardedAd ad) {
          // ------ EL BLINDAJE SSV DE GOOGLE ADMOB ------
          // Esto le dice a Google que, cuando termine el anuncio, 
          // debe llamar a tu Edge Function y enviarle este 'ticketId' en secreto.
          ad.setServerSideOptions(ServerSideVerificationOptions(customData: ticketId));

          bool userEarnedReward = false;

          ad.fullScreenContentCallback = FullScreenContentCallback(
            onAdShowedFullScreenContent: (RewardedAd ad) {},
            onAdDismissedFullScreenContent: (RewardedAd ad) {
              ad.dispose();
              if (userEarnedReward) {
                onAdWatched(ticketId); // Notificamos que terminó de verlo
              } else {
                onAdDismissedIncomplete(); // Lo cerró a la mitad
              }
            },
            onAdFailedToShowFullScreenContent: (RewardedAd ad, AdError error) {
              ad.dispose();
              onAdFailed(error.message);
            },
          );

          ad.show(onUserEarnedReward: (AdWithoutView ad, RewardItem reward) {
             // Este flag se vuelve 'true' solo si agota el timer del Rewarded Video
             userEarnedReward = true; 
          });
        },
        onAdFailedToLoad: (LoadAdError error) {
          // Si el código es 3, es que AdMob todavía no tiene anuncios para tus nuevos IDs
          if (error.code == 3) {
            onAdFailed('AdMob aún está procesando tus nuevos IDs (Error 3: No Fill). Esto puede tardar unas horas en activarse.');
          } else {
            onAdFailed('Error al cargar anuncio: ${error.message} (Código: ${error.code})');
          }
        },
      ),
    );
  }
}
