import 'package:flutter/material.dart';
import '../../../../shared/widgets/energy_flow_border.dart';
import '../../../../shared/widgets/marquee_text.dart';
import '../../../../core/services/supabase_service.dart';
import 'tv_player_page.dart';

// Modelo temporal para la vista
class TempTvChannel {
  final String id;
  final String name;
  final String logoUrl;
  final String currentProgram;

  TempTvChannel({
    required this.id,
    required this.name,
    required this.logoUrl,
    required this.currentProgram,
  });
}

class TvChannelsPage extends StatefulWidget {
  const TvChannelsPage({super.key});

  @override
  State<TvChannelsPage> createState() => _TvChannelsPageState();
}

class _TvChannelsPageState extends State<TvChannelsPage> {
  List<Map<String, dynamic>> _channels = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadChannels();
  }

  Future<void> _loadChannels() async {
    try {
      final response = await SupabaseService.client.from('tv_channels').select().order('name', ascending: true);
      if (mounted) {
        setState(() {
          _channels = List<Map<String, dynamic>>.from(response);
          _isLoading = false;
        });
      }
    } catch (e) {
      debugPrint('Error loading tv channels: \$e');
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            backgroundColor: Colors.black.withOpacity(0.8),
            floating: true,
            elevation: 0,
            title: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(colors: [Color(0xFFD400FF), Color(0xFF00A3FF)]),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: const Text('K7', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Colors.white)),
                ),
                const SizedBox(width: 8),
                const Text('TV VIVO', style: TextStyle(letterSpacing: 2, fontWeight: FontWeight.normal, fontSize: 16, color: Colors.white)),
              ],
            ),
            actions: [
              IconButton(
                icon: const Icon(Icons.search, color: Colors.white70),
                onPressed: () {},
              ),
            ],
          ),
          if (_isLoading)
            const SliverFillRemaining(
              child: Center(child: CircularProgressIndicator(color: Color(0xFF00A3FF))),
            )
          else if (_channels.isEmpty)
            const SliverFillRemaining(
               child: Center(child: Text("Aún no has importado canales a la Base de Datos.", style: TextStyle(color: Colors.white54))),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              sliver: SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, index) {
                    final channel = _channels[index];
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 16.0),
                      child: _buildChannelCard(channel),
                    );
                  },
                  childCount: _channels.length,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildChannelCard(Map<String, dynamic> channel) {
    final String name = channel['name'] ?? 'Canal Desconocido';
    final String logoUrl = channel['logo_url'] ?? '';
    final String streamUrl = channel['stream_url'] ?? '';
    final String groupName = channel['group_name'] ?? 'General';
    // Por ahora la programacion dinámica de API externa requeriría EPG. Mostraremos el estado o la categoría.
    final String currentProgram = "Categoría: \$groupName";
    return GestureDetector(
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => TvPlayerPage(
              channels: _channels,
              initialIndex: _channels.indexOf(channel),
            ),
          ),
        );
      },
      child: Container(
        height: 90,
        decoration: BoxDecoration(
          color: const Color(0xFF141414),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white10),
        ),
        child: Row(
          children: [
            // Logo Section
            Container(
              width: 100,
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.04),
                borderRadius: const BorderRadius.only(topLeft: Radius.circular(16), bottomLeft: Radius.circular(16)),
              ),
              padding: const EdgeInsets.all(12),
              child: Center(
                 child: logoUrl.isNotEmpty
                    ? Image.network(
                       logoUrl,
                       fit: BoxFit.contain,
                       errorBuilder: (_, __, ___) => const Icon(Icons.tv, color: Colors.white38, size: 40),
                     )
                    : const Icon(Icons.tv, color: Colors.white38, size: 40),
              )
            ),
            // Details Section
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      name.toUpperCase(),
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Colors.white),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Container(
                          width: 6,
                          height: 6,
                          decoration: const BoxDecoration(
                            shape: BoxShape.circle,
                            color: Colors.redAccent,
                            boxShadow: [BoxShadow(color: Colors.redAccent, blurRadius: 8)]
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: currentProgram != 'Programación no disponible' && currentProgram.length > 25
                              ? MarqueeText(text: currentProgram, style: TextStyle(color: Colors.white.withOpacity(0.6), fontSize: 12), width: 180)
                              : Text(
                                  currentProgram,
                                  style: TextStyle(color: Colors.white.withOpacity(0.6), fontSize: 12),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            // Play Button Section
            Padding(
              padding: const EdgeInsets.only(right: 16),
              child: Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(colors: [Color(0xFF00A3FF), Color(0xFFD400FF)]),
                  shape: BoxShape.circle,
                  boxShadow: [BoxShadow(color: const Color(0xFF00A3FF).withOpacity(0.3), blurRadius: 10)]
                ),
                child: const Icon(Icons.play_arrow_rounded, color: Colors.white, size: 24),
              ),
            )
          ],
        ),
      ),
    );
  }
}
