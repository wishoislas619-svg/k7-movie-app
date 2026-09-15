import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:movie_app/core/services/vip_promo_service.dart';
import 'package:movie_app/features/auth/presentation/providers/auth_provider.dart';
import 'package:movie_app/shared/widgets/energy_flow_border.dart';
import 'package:url_launcher/url_launcher.dart';

class VipStarButton extends StatefulWidget {
  final String role;

  const VipStarButton({super.key, required this.role});

  @override
  State<VipStarButton> createState() => _VipStarButtonState();
}

class _VipStarButtonState extends State<VipStarButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  bool get _isVip => widget.role.toLowerCase() == 'uservip';

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final colors = _isVip
            ? [
                HSVColor.fromAHSV(
                  1,
                  (_controller.value * 360) % 360,
                  .9,
                  1,
                ).toColor(),
                HSVColor.fromAHSV(
                  1,
                  ((_controller.value * 360) + 95) % 360,
                  .8,
                  1,
                ).toColor(),
              ]
            : [Colors.black, Colors.black];

        return GestureDetector(
          onTap: () => showVipPromoDialog(context),
          child: Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(colors: colors),
              border: Border.all(
                color: _isVip
                    ? Colors.white.withOpacity(.65)
                    : const Color(0xFF00A3FF),
                width: _isVip ? 1.4 : 1.2,
              ),
              boxShadow: _isVip
                  ? [
                      BoxShadow(
                        color: colors.first.withOpacity(.55),
                        blurRadius: 14,
                        spreadRadius: 1,
                      ),
                    ]
                  : null,
            ),
            child: Icon(
              _isVip ? Icons.star_rounded : Icons.star_border_rounded,
              color: _isVip ? Colors.white : const Color(0xFF00A3FF),
            ),
          ),
        );
      },
    );
  }
}

Future<void> showVipPromoDialog(BuildContext context) async {  final config = await VipPromoService.loadConfig();
  if (!context.mounted) return;

  await showDialog(
    context: context,
    builder: (_) => VipPromoDialog(config: config),
  );
}

class VipPromoDialog extends StatelessWidget {
  final VipPromoConfig config;
  final bool showNeverAgain;
  final ValueChanged<bool>? onNeverAgainChanged;
  final bool neverAgainValue;
  final VoidCallback? onLater;

  const VipPromoDialog({
    super.key,
    required this.config,
    this.showNeverAgain = false,
    this.onNeverAgainChanged,
    this.neverAgainValue = false,
    this.onLater,
  });

  @override
  Widget build(BuildContext context) {
    final phone = VipPromoService.normalizePhone(config.whatsappNumber);
    // En horizontal la altura disponible es pequeña: limitar y permitir
    // desplazamiento en vez de desbordar (RenderFlex overflow).
    final maxH = MediaQuery.of(context).size.height * 0.85;
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      child: EnergyFlowBorder(
        borderRadius: 18,
        borderWidth: 1.6,
        backgroundColor: const Color(0xFF101010),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: 430, maxHeight: maxH),
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(22, 22, 22, 18),
              child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  config.modalTitle,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 20,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  config.modalBody,
                  style: const TextStyle(color: Colors.white70, height: 1.35),
                ),
                const SizedBox(height: 16),
                if (phone.isNotEmpty)
                  Row(
                    children: [
                      Expanded(
                        child: SelectableText(
                          config.whatsappNumber,
                          style: const TextStyle(color: Color(0xFF00A3FF)),
                        ),
                      ),
                      IconButton(
                        onPressed: () {
                          Clipboard.setData(
                            ClipboardData(text: config.whatsappNumber),
                          );
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Número copiado')),
                          );
                        },
                        icon: const Icon(Icons.copy, color: Colors.white70),
                      ),
                    ],
                  ),
                if (showNeverAgain)
                  CheckboxListTile(
                    value: neverAgainValue,
                    onChanged: (v) => onNeverAgainChanged?.call(v ?? false),
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    activeColor: const Color(0xFF00A3FF),
                    title: const Text(
                      'No volver a mostrar',
                      style: TextStyle(color: Colors.white70, fontSize: 13),
                    ),
                  ),
                const SizedBox(height: 8),
                Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 10,
                  runSpacing: 8,
                  children: [
                    TextButton(
                      onPressed: onLater ?? () => Navigator.pop(context),
                      child: const Text('Recordar más tarde'),
                    ),
                    ElevatedButton(
                      onPressed: phone.isEmpty
                          ? null
                          : () async {
                              final uri = Uri.parse(
                                'https://wa.me/$phone?text=${Uri.encodeComponent(config.whatsappMessage)}',
                              );
                              await launchUrl(
                                uri,
                                mode: LaunchMode.externalApplication,
                              );
                            },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF00A3FF),
                        foregroundColor: Colors.white,
                      ),
                      child: const Text('¡Lo quiero!'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        ),
      ),
    );
  }
}

/// Título K7 compartido de las pantallas principales. Si el usuario es VIP,
/// las siglas llevan fondo negro con borde tornasol animado; si no,
/// degradado fijo.
class K7AppBarTitle extends ConsumerWidget {
  final String title;
  final List<Color> gradientColors;

  const K7AppBarTitle({
    super.key,
    required this.title,
    this.gradientColors = const [Color(0xFF00A3FF), Color(0xFFD400FF)],
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final role = ref.watch(authStateProvider)?.role ?? 'user';
    final isVip = role.toLowerCase() == 'uservip';
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (isVip)
          EnergyFlowBorder(
            borderRadius: 4,
            borderWidth: 1.4,
            backgroundColor: Colors.black,
            padding: const EdgeInsets.all(4),
            child: const Text(
              'K7',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 13,
                color: Colors.white,
              ),
            ),
          )
        else
          Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              gradient: LinearGradient(colors: gradientColors),
              borderRadius: BorderRadius.circular(4),
            ),
            child: const Text(
              'K7',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 13,
                color: Colors.white,
              ),
            ),
          ),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              letterSpacing: 2,
              fontWeight: FontWeight.normal,
              fontSize: 16,
              color: Colors.white,
            ),
          ),
        ),
      ],
    );
  }
}
