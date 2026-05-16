import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../../../shared/widgets/energy_flow_border.dart';
import '../../../../shared/widgets/marquee_text.dart';
import '../../../../core/services/supabase_service.dart';
import '../../../../shared/widgets/tv_focus_wrapper.dart';
import 'package:video_player/video_player.dart';
import 'tv_player_page.dart';
import '../../../../core/services/ad_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../auth/presentation/providers/auth_provider.dart';
import '../../../../core/constants/app_constants.dart';
import '../../../../shared/utils/responsive_layout.dart';

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

class TvChannelsPage extends ConsumerStatefulWidget {
  const TvChannelsPage({super.key});

  @override
  ConsumerState<TvChannelsPage> createState() => _TvChannelsPageState();
}

class _TvChannelsPageState extends ConsumerState<TvChannelsPage> {
  bool _isNavigating = false;
  List<Map<String, dynamic>> _allChannels = [];
  List<Map<String, dynamic>> _filteredChannels = [];
  Map<String, List<Map<String, dynamic>>> _groupedChannels = {};
  List<String> _categories = [];
  String _selectedCategory = 'TODOS';
  List<Map<String, dynamic>> _favoriteChannels = [];
  
  bool _isLoading = true;
  bool _isSearching = false;
  final TextEditingController _searchController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _loadInitialData();
  }

  Future<void> _loadInitialData() async {
    await _loadFavorites();
    await _loadChannels();
  }

  Future<void> _loadFavorites() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final List<String>? favoritesJson = prefs.getStringList('tv_favorites');
      if (favoritesJson != null) {
        setState(() {
          _favoriteChannels = favoritesJson
              .map((item) => jsonDecode(item) as Map<String, dynamic>)
              .toList();
        });
      }
    } catch (e) {
      debugPrint('Error loading favorites: $e');
    }
  }

  Future<void> _saveAsFavorite(Map<String, dynamic> channel) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      List<String> favoritesJson = prefs.getStringList('tv_favorites') ?? [];
      
      // Prevent duplicates, move to top
      favoritesJson.removeWhere((item) {
        final Map<String, dynamic> c = jsonDecode(item);
        return c['id'] == channel['id'];
      });
      
      favoritesJson.insert(0, jsonEncode(channel));
      
      if (favoritesJson.length > 50) {
        favoritesJson = favoritesJson.sublist(0, 50);
      }
      
      await prefs.setStringList('tv_favorites', favoritesJson);
      _loadFavorites(); // Refresh local list
    } catch (e) {
      debugPrint('Error saving favorite: $e');
    }
  }

  Future<void> _loadChannels() async {
    try {
      final response = await SupabaseService.client
          .from('tv_channels')
          .select()
          .order('name', ascending: true)
          .limit(5000);
          
      if (mounted) {
        final List<Map<String, dynamic>> channels = List<Map<String, dynamic>>.from(response);
        
        // Grouping logic
        Map<String, List<Map<String, dynamic>>> groups = {
          'TODOS': channels,
        };
        
        for (var channel in channels) {
          String group = channel['group_name'] ?? '';
          if (group.trim().isEmpty || group.toLowerCase() == 'undefined') {
            group = 'TV para todos';
          }
          
          if (!groups.containsKey(group)) {
            groups[group] = [];
          }
          groups[group]!.add(channel);
        }
        
        final List<String> catNames = groups.keys.toList()..sort((a, b) {
           if (a == 'TODOS') return -1;
           if (b == 'TODOS') return 1;
           return a.compareTo(b);
        });

        setState(() {
          _allChannels = channels;
          _groupedChannels = groups;
          _categories = catNames;
          _filteredChannels = _allChannels; // Default view: Todos
          _isLoading = false;
        });
      }
    } catch (e) {
      debugPrint('Error loading tv channels: $e');
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _selectCategory(String category) {
    setState(() {
      _selectedCategory = category;
      _isSearching = false;
      _searchController.clear();
      
      if (category == 'Mis favoritos') {
        _filteredChannels = _favoriteChannels;
      } else {
        _filteredChannels = _groupedChannels[category] ?? [];
      }
    });
  }

  void _filterChannels(String query) {
    if (query.isEmpty) {
      setState(() {
        _filteredChannels = _allChannels;
      });
      return;
    }
    
    final lowercaseQuery = query.toLowerCase();
    setState(() {
      _filteredChannels = _allChannels.where((channel) {
        final name = (channel['name'] ?? '').toString().toLowerCase();
        final group = (channel['group_name'] ?? '').toString().toLowerCase();
        return name.contains(lowercaseQuery) || group.contains(lowercaseQuery);
      }).toList();
    });
  }

  void _scrollToChannel(String channelId) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final index = _filteredChannels.indexWhere((c) => c['id'] == channelId);
      if (index != -1 && _scrollController.hasClients) {
        // card height 90 + padding bottom 16 = 106
        final offset = index * 106.0;
        _scrollController.animateTo(
          offset,
          duration: const Duration(milliseconds: 800),
          curve: Curves.easeOutCubic,
        );
      }
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    _scrollController.dispose();
    super.dispose();
  }
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: CustomScrollView(
        controller: _scrollController,
        slivers: [
          SliverAppBar(
            backgroundColor: Colors.black.withOpacity(0.8),
            floating: true,
            elevation: 0,
            title: _isSearching 
              ? TextField(
                  controller: _searchController,
                  autofocus: true,
                  style: const TextStyle(color: Colors.white),
                  decoration: const InputDecoration(
                    hintText: 'Buscar canal...',
                    hintStyle: TextStyle(color: Colors.white54),
                    border: InputBorder.none,
                  ),
                  onChanged: _filterChannels,
                )
              : Row(
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
                icon: Icon(_isSearching ? Icons.close : Icons.search, color: Colors.white70),
                onPressed: () {
                  setState(() {
                    if (_isSearching) {
                      _isSearching = false;
                      _searchController.clear();
                      _selectCategory(_selectedCategory);
                    } else {
                      _isSearching = true;
                    }
                  });
                },
              ),
            ],
          ),
          if (!_isSearching && !_isLoading)
            SliverToBoxAdapter(
              child: Container(
                height: 50,
                margin: const EdgeInsets.symmetric(vertical: 8),
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  children: [
                    _buildCategoryChip('Mis favoritos', Icons.star_rounded),
                    ..._categories.map((cat) => _buildCategoryChip(cat, _getIconForCategory(cat))),
                  ],
                ),
              ),
            ),
          if (_isLoading)
            const SliverFillRemaining(
              child: Center(child: CircularProgressIndicator(color: Color(0xFF00A3FF))),
            )
          else if (_filteredChannels.isEmpty)
            const SliverFillRemaining(
               child: Center(child: Text("No se encontraron canales.", style: TextStyle(color: Colors.white54))),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              sliver: SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, index) {
                    final channel = _filteredChannels[index];
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 16.0),
                      child: _buildChannelCard(channel),
                    );
                  },
                  childCount: _filteredChannels.length,
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
    final String groupName = channel['group_name'] ?? 'General';
    final String currentProgram = "Categoría: $groupName";
    
    return Container(
      margin: const EdgeInsets.only(bottom: 4), 
      child: TvFocusWrapper(
        onTap: () async {
            if (_isNavigating) return;
            
            final user = ref.read(authStateProvider);
            final role = user?.role.toLowerCase() ?? 'user';
            final bool isFree = role == AppConstants.roleAdmin || role == AppConstants.roleUserVip;

            Future<void> openPlayer() async {
              if (_isNavigating) return;
              setState(() => _isNavigating = true);
              _saveAsFavorite(channel);
              await Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => TvPlayerPage(
                    channels: _filteredChannels,
                    initialIndex: _filteredChannels.indexOf(channel),
                  ),
                ),
              );
              if (mounted) {
                setState(() => _isNavigating = false);
                _scrollToChannel(channel['id']);
              }
            }

            if (isFree) {
              await openPlayer();
            } else {
              // Show rewarded ad before playing
              AdService.showRewardedAd(
                ticketId: "tv_reward",
                onAdWatched: (_) async {
                  await openPlayer();
                },
                onAdFailed: (error) async {
                   // If ad fails (no fill), we still let them in
                   await openPlayer();
                },
                onAdDismissedIncomplete: () {
                   ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Debes ver el anuncio para acceder al canal")));
                }
              );
            }
        },
        borderRadius: 16,
        child: EnergyFlowBorder(
          borderRadius: 16,
          borderWidth: 1.2,
          backgroundColor: const Color(0xFF0A0A0A),
          padding: EdgeInsets.zero,
          child: Material(
            color: Colors.transparent,
            child: ListTile(
               contentPadding: EdgeInsets.symmetric(
                 horizontal: 16, 
                 vertical: ResponsiveLayout.isLandscape(context) ? 4 : 8
               ),
               onTap: null, // Lo maneja TvFocusWrapper
               shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
               leading: Container(
                 width: 50,
                 height: 50,
                 padding: const EdgeInsets.all(8),
                 decoration: BoxDecoration(
                   color: Colors.white.withOpacity(0.05),
                   borderRadius: BorderRadius.circular(12),
                   border: Border.all(color: Colors.white10),
                 ),
                 child: logoUrl.isNotEmpty
                    ? Image.network(
                        logoUrl,
                        fit: BoxFit.contain,
                        errorBuilder: (_, __, ___) => Icon(Icons.tv, color: Colors.white38, size: ResponsiveLayout.isLandscape(context) ? 18 : 24),
                      )
                    : Icon(Icons.tv, color: Colors.white38, size: ResponsiveLayout.isLandscape(context) ? 18 : 24),
               ),
               title: Text(
                 name.toUpperCase(), 
                 style: TextStyle(
                   color: Colors.white, 
                   fontWeight: FontWeight.bold, 
                   fontSize: ResponsiveLayout.isLandscape(context) ? 12 : 14, 
                   letterSpacing: 0.5
                 ), 
                 maxLines: 1, 
                 overflow: TextOverflow.ellipsis,
               ),
               subtitle: Padding(
                 padding: const EdgeInsets.only(top: 4.0),
                 child: Row(
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
                       child: Text(
                         currentProgram,
                         style: TextStyle(color: Colors.white.withOpacity(0.6), fontSize: 11),
                         maxLines: 1,
                         overflow: TextOverflow.ellipsis,
                       ),
                     ),
                   ],
                 ),
               ),
               trailing: Container(
                 padding: const EdgeInsets.all(8),
                 decoration: BoxDecoration(
                   color: Colors.white.withOpacity(0.05),
                   shape: BoxShape.circle,
                 ),
                 child: const Icon(Icons.play_arrow_rounded, color: Color(0xFF00A3FF), size: 20),
               ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCategoryChip(String label, IconData icon) {
    final bool isSelected = _selectedCategory == label;
    return Padding(
      padding: const EdgeInsets.only(right: 8.0),
      child: FilterChip(
        label: Text(label, style: TextStyle(color: isSelected ? Colors.white : Colors.white60, fontSize: 13, fontWeight: isSelected ? FontWeight.bold : FontWeight.normal)),
        selected: isSelected,
        onSelected: (_) => _selectCategory(label),
        backgroundColor: Colors.white.withOpacity(0.05),
        selectedColor: const Color(0xFF00A3FF).withOpacity(0.3),
        checkmarkColor: Colors.white,
        avatar: Icon(icon, size: 16, color: isSelected ? Colors.white : Colors.white60),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20), side: BorderSide(color: isSelected ? const Color(0xFF00A3FF) : Colors.white10)),
      ),
    );
  }

  IconData _getIconForCategory(String category) {
    category = category.toLowerCase();
    if (category == 'todos') return Icons.grid_view_rounded;
    if (category.contains('cine') || category.contains('peli')) return Icons.movie_filter_rounded;
    if (category.contains('deporte') || category.contains('sport')) return Icons.sports_soccer_rounded;
    if (category.contains('noticia')) return Icons.newspaper_rounded;
    if (category.contains('niño') || category.contains('kid')) return Icons.child_care_rounded;
    if (category.contains('música') || category.contains('music')) return Icons.music_note_rounded;
    if (category.contains('cultura') || category.contains('docu')) return Icons.auto_awesome_motion_rounded;
    return Icons.tv_rounded;
  }
}
