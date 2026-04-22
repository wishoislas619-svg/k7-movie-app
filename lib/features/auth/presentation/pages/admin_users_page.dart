import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/user_provider.dart';
import '../../domain/entities/user.dart';
import '../providers/auth_provider.dart';

class AdminUsersPage extends ConsumerStatefulWidget {
  const AdminUsersPage({super.key});

  @override
  ConsumerState<AdminUsersPage> createState() => _AdminUsersPageState();
}

class _AdminUsersPageState extends ConsumerState<AdminUsersPage> {
  final TextEditingController _searchController = TextEditingController();
  final TextEditingController _daysController = TextEditingController(text: '30');
  String _roleFilter = 'Todos';
  String _selectedRole = 'uservip';
  User? _selectedUser;

  @override
  void dispose() {
    _searchController.dispose();
    _daysController.dispose();
    super.dispose();
  }

  void _applyRoleUpdate() async {
    if (_selectedUser == null) return;
    
    // 1. Validación de Seguridad Crítica (Admin Check)
    final adminUser = ref.read(authStateProvider);
    if (adminUser == null || adminUser.role.toLowerCase() != 'admin') {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('ERROR: No tienes permisos de administrador para realizar esta acción.'), backgroundColor: Colors.redAccent)
      );
      return;
    }

    final int days = int.tryParse(_daysController.text) ?? 0;
    if (days <= 0 && _selectedRole == 'uservip') {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Por favor ingresa un número válido de días.'))
      );
      return;
    }

    // 2. Ejecutar comando
    try {
      await ref.read(usersProvider.notifier).updateUserRole(
        _selectedUser!.email, 
        _selectedRole, 
        days
      );
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('¡ÉXITO! Se actualizó a ${_selectedUser!.email} a $_selectedRole por $days días.'),
            backgroundColor: const Color(0xFF00A3FF),
          )
        );
        setState(() {
          _selectedUser = null;
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.redAccent)
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final usersAsync = ref.watch(usersProvider);
    final adminUser = ref.watch(authStateProvider);

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: const Color(0xFF0A0A0A),
        elevation: 0,
        title: const Text(
          'GESTIÓN DE ROLES VIP',
          style: TextStyle(color: Color(0xFF00A3FF), fontWeight: FontWeight.bold, letterSpacing: 1.5, fontSize: 16),
        ),
      ),
      body: Column(
        children: [
          // PANEL DE CONTROL (FILTROS Y BÚSQUEDA)
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFF0A0A0A),
              border: Border(bottom: BorderSide(color: Colors.white.withOpacity(0.05))),
            ),
            child: Column(
              children: [
                // Buscador
                TextField(
                  controller: _searchController,
                  style: const TextStyle(color: Colors.white),
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    hintText: 'Buscar por email o usuario...',
                    hintStyle: const TextStyle(color: Colors.white24),
                    prefixIcon: const Icon(Icons.search, color: Color(0xFF00A3FF)),
                    filled: true,
                    fillColor: Colors.white.withOpacity(0.05),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    // Filtro de Rol
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        value: _roleFilter,
                        dropdownColor: const Color(0xFF1A1A1A),
                        style: const TextStyle(color: Colors.white, fontSize: 13),
                        decoration: InputDecoration(
                          labelText: 'Filtro de Rol',
                          labelStyle: const TextStyle(color: Colors.white38),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                        items: ['Todos', 'user', 'uservip', 'admin'].map((r) => DropdownMenuItem(value: r, child: Text(r.toUpperCase()))).toList(),
                        onChanged: (v) => setState(() => _roleFilter = v!),
                      ),
                    ),
                    const SizedBox(width: 12),
                    // Refrescar
                    IconButton(
                      icon: const Icon(Icons.refresh, color: Color(0xFF00A3FF)),
                      onPressed: () => ref.read(usersProvider.notifier).loadUsers(),
                    )
                  ],
                ),
              ],
            ),
          ),

          // LISTADO DE USUARIOS
          Expanded(
            child: usersAsync.when(
              data: (users) {
                final filteredUsers = users.where((u) {
                  final query = _searchController.text.toLowerCase();
                  final matchesSearch = u.email.toLowerCase().contains(query) || u.username.toLowerCase().contains(query);
                  final matchesRole = _roleFilter == 'Todos' || u.role.toLowerCase() == _roleFilter.toLowerCase();
                  return matchesSearch && matchesRole;
                }).toList();

                return ListView.builder(
                  itemCount: filteredUsers.length,
                  itemBuilder: (context, index) {
                    final user = filteredUsers[index];
                    final isSelected = _selectedUser?.id == user.id;

                    return GestureDetector(
                      onTap: () => setState(() => _selectedUser = user),
                      child: Container(
                        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: isSelected ? const Color(0xFF00A3FF).withOpacity(0.1) : Colors.white.withOpacity(0.02),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: isSelected ? const Color(0xFF00A3FF) : Colors.white.withOpacity(0.05)),
                        ),
                        child: Row(
                          children: [
                            CircleAvatar(
                              backgroundColor: user.role == 'uservip' ? Colors.amber.withOpacity(0.2) : (user.role == 'admin' ? Colors.red.withOpacity(0.2) : Colors.white.withOpacity(0.1)),
                              child: Icon(
                                user.role == 'uservip' ? Icons.star : (user.role == 'admin' ? Icons.security : Icons.person),
                                color: user.role == 'uservip' ? Colors.amber : (user.role == 'admin' ? Colors.redAccent : Colors.white70),
                                size: 20,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text('${user.firstName} ${user.lastName}', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14)),
                                  Text(user.email, style: const TextStyle(color: Colors.white54, fontSize: 12)),
                                  Text('@${user.username}', style: const TextStyle(color: Color(0xFF00A3FF), fontSize: 11, fontWeight: FontWeight.w600)),
                                ],
                              ),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                color: user.role == 'uservip' ? Colors.amber.withOpacity(0.1) : Colors.white.withOpacity(0.05),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text(user.role.toUpperCase(), style: TextStyle(color: user.role == 'uservip' ? Colors.amber : Colors.white38, fontSize: 10, fontWeight: FontWeight.bold)),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                );
              },
              loading: () => const Center(child: CircularProgressIndicator(color: Color(0xFF00A3FF))),
              error: (e, s) => Center(child: Text('Error: $e', style: const TextStyle(color: Colors.redAccent))),
            ),
          ),

          // PANEL INFERIOR DE ACCIÓN (SOLO SI HAY USUARIO SELECCIONADO)
          if (_selectedUser != null)
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: const Color(0xFF121212),
                borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
                boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.5), blurRadius: 10, spreadRadius: 5)],
              ),
              child: SafeArea(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.flash_on, color: Color(0xFF00A3FF), size: 18),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Modificando a: ${_selectedUser!.username}',
                            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close, color: Colors.white24, size: 20),
                          onPressed: () => setState(() => _selectedUser = null),
                        )
                      ],
                    ),
                    const Divider(color: Colors.white10),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        // Select de Rol
                        Expanded(
                          flex: 2,
                          child: DropdownButtonFormField<String>(
                            value: _selectedRole,
                            dropdownColor: const Color(0xFF1E1E1E),
                            style: const TextStyle(color: Colors.white),
                            decoration: InputDecoration(
                              labelText: 'Nuevo Rol',
                              labelStyle: const TextStyle(color: Colors.white38),
                              filled: true,
                              fillColor: Colors.white.withOpacity(0.03),
                              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                            ),
                            items: ['user', 'uservip'].map((r) => DropdownMenuItem(value: r, child: Text(r.toUpperCase()))).toList(),
                            onChanged: (v) => setState(() => _selectedRole = v!),
                          ),
                        ),
                        const SizedBox(width: 12),
                        // Input de Días
                        Expanded(
                          flex: 1,
                          child: TextField(
                            controller: _daysController,
                            keyboardType: TextInputType.number,
                            style: const TextStyle(color: Colors.white),
                            decoration: InputDecoration(
                              labelText: 'Días',
                              labelStyle: const TextStyle(color: Colors.white38),
                              filled: true,
                              fillColor: Colors.white.withOpacity(0.03),
                              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),
                    SizedBox(
                      width: double.infinity,
                      height: 50,
                      child: ElevatedButton(
                        onPressed: _applyRoleUpdate,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF00A3FF),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          elevation: 8,
                          shadowColor: const Color(0xFF00A3FF).withOpacity(0.4),
                        ),
                        child: const Text('APLICAR CAMBIO DE ROL', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, letterSpacing: 1)),
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
