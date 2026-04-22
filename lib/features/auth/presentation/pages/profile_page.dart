import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/services/storage_service.dart';
import '../providers/auth_provider.dart';
import '../../domain/entities/user.dart';

class ProfilePage extends ConsumerStatefulWidget {
  const ProfilePage({super.key});

  @override
  ConsumerState<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends ConsumerState<ProfilePage> {
  final _formKey = GlobalKey<FormState>();
  late TextEditingController _firstNameController;
  late TextEditingController _lastNameController;
  late TextEditingController _emailController;
  late TextEditingController _usernameController;
  
  bool _isEditing = false;
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    final user = ref.read(authStateProvider);
    _firstNameController = TextEditingController(text: user?.firstName ?? '');
    _lastNameController = TextEditingController(text: user?.lastName ?? '');
    _emailController = TextEditingController(text: user?.email ?? '');
    _usernameController = TextEditingController(text: user?.username ?? '');
  }

  @override
  void dispose() {
    _firstNameController.dispose();
    _lastNameController.dispose();
    _emailController.dispose();
    _usernameController.dispose();
    super.dispose();
  }

  Future<void> _updateProfile() async {
    if (!_formKey.currentState!.validate()) return;
    
    setState(() => _isLoading = true);
    final success = await ref.read(authStateProvider.notifier).updateProfile(
      firstName: _firstNameController.text,
      lastName: _lastNameController.text,
      email: _emailController.text,
      username: _usernameController.text,
    );
    
    if (mounted) {
      setState(() {
        _isLoading = false;
        if (success) _isEditing = false;
      });
      
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(success ? 'Perfil actualizado correctamente' : 'Error al actualizar perfil'),
          backgroundColor: success ? Colors.green : Colors.red,
        ),
      );
    }
  }

  void _showChangePasswordDialog() {
    final currentPasswordController = TextEditingController();
    final newPasswordController = TextEditingController();
    final confirmPasswordController = TextEditingController();
    final dialogFormKey = GlobalKey<FormState>();

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          backgroundColor: const Color(0xFF121212),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: BorderSide(color: Colors.white.withOpacity(0.1)),
          ),
          title: const Text('Cambiar Contraseña', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          content: Form(
            key: dialogFormKey,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _buildTextField(
                    currentPasswordController,
                    'Contraseña Actual',
                    Icons.lock_outline,
                    isPassword: true,
                  ),
                  const SizedBox(height: 16),
                  _buildTextField(
                    newPasswordController,
                    'Nueva Contraseña',
                    Icons.vpn_key_outlined,
                    isPassword: true,
                  ),
                  const SizedBox(height: 16),
                  _buildTextField(
                    confirmPasswordController,
                    'Confirmar Nueva Contraseña',
                    Icons.vpn_key_outlined,
                    isPassword: true,
                    validator: (val) {
                      if (val != newPasswordController.text) return 'Las contraseñas no coinciden';
                      return null;
                    },
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('CANCELAR', style: TextStyle(color: Colors.white54)),
            ),
            Container(
              decoration: BoxDecoration(
                gradient: const LinearGradient(colors: [Color(0xFF00A3FF), Color(0xFFD400FF)]),
                borderRadius: BorderRadius.circular(8),
              ),
              child: ElevatedButton(
                onPressed: () async {
                  if (!dialogFormKey.currentState!.validate()) return;
                  
                  final success = await ref.read(authStateProvider.notifier).changePassword(
                    currentPasswordController.text,
                    newPasswordController.text,
                  );
                  
                  if (context.mounted) {
                    Navigator.pop(context);
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(success ? 'Contraseña cambiada correctamente' : 'Contraseña actual incorrecta'),
                        backgroundColor: success ? Colors.green : Colors.red,
                      ),
                    );
                  }
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.transparent,
                  shadowColor: Colors.transparent,
                ),
                child: const Text('CAMBIAR', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(authStateProvider);
    if (user == null) return const Scaffold(body: Center(child: CircularProgressIndicator()));

    return Scaffold(
      backgroundColor: Colors.black,
      body: CustomScrollView(
        slivers: [
          _buildSliverAppBar(user),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(20.0),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildSectionHeader('INFORMACIÓN PERSONAL'),
                    const SizedBox(height: 20),
                    _buildTextField(_firstNameController, 'Nombre', Icons.person_outline),
                    const SizedBox(height: 16),
                    _buildTextField(_lastNameController, 'Apellido', Icons.person_add_alt_1_outlined),
                    const SizedBox(height: 16),
                    _buildTextField(_usernameController, 'Nombre de Usuario', Icons.alternate_email),
                    const SizedBox(height: 16),
                    _buildTextField(_emailController, 'Correo Electrónico', Icons.email_outlined),
                    
                    const SizedBox(height: 35),
                    
                    _buildSectionHeader('SEGURIDAD'),
                    const SizedBox(height: 20),
                    _buildActionButton(
                      'CAMBIAR CONTRASEÑA',
                      Icons.password,
                      _showChangePasswordDialog,
                      isOutline: true,
                    ),

                    const SizedBox(height: 40),
                    
                    if (_isEditing)
                      Row(
                        children: [
                          Expanded(
                            child: _buildActionButton(
                              'CANCELAR',
                              Icons.close,
                              () => setState(() {
                                _isEditing = false;
                                // Reset values
                                _firstNameController.text = user.firstName;
                                _lastNameController.text = user.lastName;
                                _emailController.text = user.email;
                                _usernameController.text = user.username;
                              }),
                              isDanger: true,
                            ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: _buildActionButton(
                              'GUARDAR CAMBIOS',
                              Icons.save_outlined,
                              _isLoading ? null : _updateProfile,
                              isPrimary: true,
                            ),
                          ),
                        ],
                      )
                    else
                      _buildActionButton(
                        'EDITAR PERFIL',
                        Icons.edit_outlined,
                        () => setState(() => _isEditing = true),
                        isPrimary: true,
                      ),
                      
                    const SizedBox(height: 20),
                    _buildActionButton(
                      'CERRAR SESIÓN',
                      Icons.logout,
                      () => ref.read(authStateProvider.notifier).logout(),
                      isDanger: true,
                      isOutline: true,
                    ),
                    const SizedBox(height: 100), // Bottom padding for PageView/BottomNav
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSliverAppBar(User user) {
    return SliverAppBar(
      expandedHeight: 220,
      backgroundColor: Colors.black,
      flexibleSpace: FlexibleSpaceBar(
        background: Stack(
          alignment: Alignment.center,
          children: [
            // Background Gradient
            Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    const Color(0xFF00A3FF).withOpacity(0.3),
                    Colors.black,
                  ],
                ),
              ),
            ),
            // Avatar Circle
            Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  padding: const EdgeInsets.all(4),
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: LinearGradient(colors: [Color(0xFF00A3FF), Color(0xFFD400FF)]),
                  ),
                  child: CircleAvatar(
                    radius: 45,
                    backgroundColor: const Color(0xFF121212),
                    child: Text(
                      user.firstName.isNotEmpty ? user.firstName[0].toUpperCase() : '?',
                      style: const TextStyle(fontSize: 40, fontWeight: FontWeight.bold, color: Colors.white),
                    ),
                  ),
                ),
                const SizedBox(height: 15),
                Text(
                  '${user.firstName} ${user.lastName}',
                  style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold),
                ),
                Text(
                  '@${user.username}',
                  style: const TextStyle(color: Color(0xFF00A3FF), fontSize: 14, fontWeight: FontWeight.w500),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionHeader(String title) {
    return Row(
      children: [
        Container(
          width: 4,
          height: 16,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(2),
            gradient: const LinearGradient(colors: [Color(0xFF00A3FF), Color(0xFFD400FF)]),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          title,
          style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold, letterSpacing: 1.2),
        ),
      ],
    );
  }

  Widget _buildTextField(
    TextEditingController controller,
    String label,
    IconData icon, {
    bool isPassword = false,
    String? Function(String?)? validator,
  }) {
    return TextFormField(
      controller: controller,
      enabled: _isEditing || isPassword, // Password dialog always editable
      obscureText: isPassword,
      style: const TextStyle(color: Colors.white),
      validator: validator ?? (val) => val == null || val.isEmpty ? 'Campo requerido' : null,
      decoration: InputDecoration(
        labelText: label,
        labelStyle: TextStyle(color: Colors.white.withOpacity(0.5)),
        prefixIcon: Icon(icon, color: const Color(0xFF00A3FF), size: 20),
        filled: true,
        fillColor: Colors.white.withOpacity(0.05),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(15), borderSide: BorderSide.none),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(15),
          borderSide: BorderSide(color: Colors.white.withOpacity(0.05)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(15),
          borderSide: const BorderSide(color: Color(0xFF00A3FF), width: 1),
        ),
        disabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(15),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }

  Widget _buildActionButton(
    String label,
    IconData icon,
    VoidCallback? onPressed, {
    bool isPrimary = false,
    bool isDanger = false,
    bool isOutline = false,
  }) {
    final color = isDanger ? Colors.redAccent : const Color(0xFF00A3FF);
    
    return Container(
      width: double.infinity,
      height: 54,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(15),
        gradient: isPrimary && !isOutline ? const LinearGradient(colors: [Color(0xFF00A3FF), Color(0xFFD400FF)]) : null,
        border: isOutline ? Border.all(color: color.withOpacity(0.5), width: 1.5) : null,
        boxShadow: isPrimary ? [
          BoxShadow(color: const Color(0xFF00A3FF).withOpacity(0.3), blurRadius: 10, offset: const Offset(0, 4)),
        ] : null,
      ),
      child: ElevatedButton.icon(
        onPressed: onPressed,
        icon: Icon(icon, color: Colors.white, size: 20),
        label: Text(
          label,
          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, letterSpacing: 1.1),
        ),
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.transparent,
          shadowColor: Colors.transparent,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
        ),
      ),
    );
  }
}
