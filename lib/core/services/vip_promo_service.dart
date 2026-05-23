import 'package:movie_app/core/services/supabase_service.dart';

class VipPromoConfig {
  final String whatsappNumber;
  final String whatsappMessage;
  final String modalTitle;
  final String modalBody;

  const VipPromoConfig({
    required this.whatsappNumber,
    required this.whatsappMessage,
    required this.modalTitle,
    required this.modalBody,
  });

  static const fallback = VipPromoConfig(
    whatsappNumber: '',
    whatsappMessage: 'me interesa el plan sin anuncios de la app de streaming',
    modalTitle: 'Disfruta sin anuncios',
    modalBody:
        'Accede a todo el contenido y funciones sin interrupciones con el plan sin anuncios.',
  );

  factory VipPromoConfig.fromMap(Map<String, dynamic>? map) {
    if (map == null) return fallback;
    return VipPromoConfig(
      whatsappNumber: (map['whatsapp_number'] ?? '').toString(),
      whatsappMessage: (map['whatsapp_message'] ?? fallback.whatsappMessage)
          .toString(),
      modalTitle: (map['modal_title'] ?? fallback.modalTitle).toString(),
      modalBody: (map['modal_body'] ?? fallback.modalBody).toString(),
    );
  }
}

class VipPromoService {
  static const String configId = 'global';

  static Future<VipPromoConfig> loadConfig() async {
    try {
      final data = await SupabaseService.client
          .from('vip_promo_config')
          .select()
          .eq('id', configId)
          .maybeSingle();
      return VipPromoConfig.fromMap(data);
    } catch (_) {
      return VipPromoConfig.fallback;
    }
  }

  static Future<void> saveConfig(VipPromoConfig config) async {
    await SupabaseService.client.from('vip_promo_config').upsert({
      'id': configId,
      'whatsapp_number': config.whatsappNumber,
      'whatsapp_message': config.whatsappMessage,
      'modal_title': config.modalTitle,
      'modal_body': config.modalBody,
      'updated_at': DateTime.now().toIso8601String(),
    });
  }

  static String normalizePhone(String value) {
    return value.replaceAll(RegExp(r'[^0-9]'), '');
  }
}
