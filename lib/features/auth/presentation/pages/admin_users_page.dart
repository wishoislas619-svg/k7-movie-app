import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/user_provider.dart';
import '../../domain/entities/user.dart';
import '../providers/auth_provider.dart';

class AdminUsersPage extends ConsumerWidget {
  const AdminUsersPage({super.key});

  Widget _buildDialogTextField(TextEditingController controller, String label, {bool obscureText = false}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: TextField(
        controller: controller,
        obscureText: obscureText,
        style: const TextStyle(color: Colors.white),
        decoration: InputDecoration(
          labelText: label,
          labelStyle: const TextStyle(color: Color(0xFF00A3FF), fontSize: 13, fontWeight: FontWeight.bold),
          filled: true,
          fillColor: Colors.white.withOpacity(0.04),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: Colors.white.withOpacity(0.1))),
          enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: Colors.white.withOpacity(0.1))),
          focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Color(0xFF00A3FF))),
        ),
      ),
    );
  }

  void _showEditUserDialog(BuildContext context, WidgetRef ref, User user) {
    final firstNameController = TextEditingController(text: user.firstName);
    final lastNameController = TextEditingController(text: user.lastName);
    final emailController = TextEditingController(text: user.email);
    final usernameController = TextEditingController(text: user.username);
    final passwordController = TextEditingController(); // Empty to only update if changed

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: BorderSide(color: Colors.white.withOpacity(0.1))),
        title: const Text('EDITAR USUARIO', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, letterSpacing: 1.5)),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildDialogTextField(firstNameController, 'Nombre'),
              _buildDialogTextField(lastNameController, 'Apellido'),
              _buildDialogTextField(emailController, 'Correo'),
              _buildDialogTextField(usernameController, 'Usuario'),
              _buildDialogTextField(passwordController, 'Nueva Contraseña (vacío para omitir)', obscureText: true),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('CANCELAR', style: TextStyle(color: Colors.white54))),
          ElevatedButton(
            onPressed: () {
              final updatedUser = User(
                id: user.id,
                firstName: firstNameController.text,
                lastName: lastNameController.text,
                email: emailController.text,
                username: usernameController.text,
                role: user.role,
              );
              ref.read(usersProvider.notifier).updateUser(
                updatedUser, 
                password: passwordController.text.isEmpty ? null : passwordController.text
              );
              Navigator.pop(context);
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF00A3FF),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            child: const Text('GUARDAR', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final usersAsync = ref.watch(usersProvider);

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: const Color(0xFF0A0A0A),
        elevation: 0,
        title: const Text(
          'USUARIOS',
          style: TextStyle(color: Color(0xFF00A3FF), fontWeight: FontWeight.bold, letterSpacing: 2, fontSize: 16),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.logout, color: Colors.white70),
            onPressed: () => ref.read(authStateProvider.notifier).logout(),
          ),
        ],
      ),
      body: usersAsync.when(
        data: (users) => ListView.builder(
          padding: const EdgeInsets.only(bottom: 120),
          itemCount: users.length,
          itemBuilder: (context, index) {
            final user = users[index];
            return Container(
              margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.03),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.white.withOpacity(0.05)),
              ),
              child: ListTile(
                title: Text('${user.firstName} ${user.lastName}', style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
                subtitle: Text('${user.email} | @${user.username}', style: const TextStyle(color: Color(0xFF00A3FF), fontSize: 12)),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      decoration: BoxDecoration(color: Colors.white.withOpacity(0.1), shape: BoxShape.circle),
                      child: IconButton(
                        icon: const Icon(Icons.edit, color: Colors.blueAccent, size: 20),
                        onPressed: () => _showEditUserDialog(context, ref, user),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      decoration: BoxDecoration(color: Colors.red.withOpacity(0.1), shape: BoxShape.circle),
                      child: IconButton(
                        icon: const Icon(Icons.delete, color: Colors.redAccent, size: 20),
                        onPressed: () {
                          showDialog(
                            context: context,
                            builder: (context) => AlertDialog(
                              backgroundColor: const Color(0xFF1E1E1E),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: BorderSide(color: Colors.white.withOpacity(0.1))),
                              title: const Text('ELIMINAR USUARIO', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                              content: const Text('¿Estás seguro de que deseas eliminar este usuario?', style: TextStyle(color: Colors.white70)),
                              actions: [
                                TextButton(onPressed: () => Navigator.pop(context), child: const Text('CANCELAR', style: TextStyle(color: Colors.white54))),
                                ElevatedButton(
                                  onPressed: () {
                                    ref.read(usersProvider.notifier).deleteUser(user.id);
                                    Navigator.pop(context);
                                  },
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: Colors.redAccent,
                                    foregroundColor: Colors.white,
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                  ),
                                  child: const Text('ELIMINAR', style: TextStyle(fontWeight: FontWeight.bold)),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, s) => Center(child: Text('Error: $e')),
      ),
    );
  }
}
