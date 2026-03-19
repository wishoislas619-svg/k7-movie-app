import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/auth_provider.dart';

class RegisterPage extends ConsumerStatefulWidget {
  const RegisterPage({super.key});

  @override
  ConsumerState<RegisterPage> createState() => _RegisterPageState();
}

class _RegisterPageState extends ConsumerState<RegisterPage> {
  final _formKey = GlobalKey<FormState>();
  final _firstNameController = TextEditingController();
  final _lastNameController  = TextEditingController();
  final _emailController     = TextEditingController();
  final _usernameController  = TextEditingController();
  final _passwordController  = TextEditingController();
  final _confirmController   = TextEditingController();

  bool _isLoading = false;
  bool _obscurePassword = true;
  bool _obscureConfirm  = true;

  // Expresión regular para validar email
  final _emailRegex = RegExp(r'^[a-zA-Z0-9._%+\-]+@[a-zA-Z0-9.\-]+\.[a-zA-Z]{2,}$');

  @override
  void dispose() {
    _firstNameController.dispose();
    _lastNameController.dispose();
    _emailController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  Future<void> _register() async {
    FocusScope.of(context).unfocus();
    if (!_formKey.currentState!.validate()) return;

    setState(() => _isLoading = true);

    final success = await ref.read(authStateProvider.notifier).register(
      firstName: _firstNameController.text.trim(),
      lastName:  _lastNameController.text.trim(),
      email:     _emailController.text.trim().toLowerCase(),
      username:  _usernameController.text.trim(),
      password:  _passwordController.text,
    );

    if (mounted) setState(() => _isLoading = false);

    if (!mounted) return;

    if (success) {
      Navigator.pop(context);
    } else {
      _showError(
        'No se pudo crear la cuenta.\nEl correo o nombre de usuario ya están registrados.',
      );
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message, style: const TextStyle(color: Colors.white)),
        backgroundColor: Colors.redAccent.withOpacity(0.9),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Container(
        width: double.infinity,
        height: double.infinity,
        decoration: const BoxDecoration(
          gradient: RadialGradient(
            center: Alignment.topCenter,
            radius: 1.5,
            colors: [Color(0xFF0D031A), Colors.black],
          ),
        ),
        child: SafeArea(
          child: SingleChildScrollView(
            physics: const BouncingScrollPhysics(),
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  const SizedBox(height: 10),

                  // Header
                  _buildHeader(),
                  const SizedBox(height: 32),

                  // Form Card
                  _buildFormCard(),
                  const SizedBox(height: 24),

                  // Ya tengo cuenta
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text(
                      '¿YA TIENES CUENTA? INICIA SESIÓN',
                      style: TextStyle(
                        color: Colors.white38,
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1.2,
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.all(4),
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            gradient: LinearGradient(colors: [Color(0xFF00A3FF), Color(0xFFD400FF)]),
          ),
          child: const CircleAvatar(
            radius: 30,
            backgroundColor: Color(0xFF08080B),
            child: Icon(Icons.person_add_alt_1, color: Colors.white, size: 28),
          ),
        ),
        const SizedBox(height: 16),
        const Text(
          'CREAR CUENTA',
          style: TextStyle(
            color: Colors.white,
            fontSize: 24,
            fontWeight: FontWeight.w900,
            letterSpacing: 3,
          ),
        ),
        const SizedBox(height: 6),
        const Text(
          'Únete al universo K7',
          style: TextStyle(color: Colors.white38, fontSize: 14),
        ),
      ],
    );
  }

  Widget _buildFormCard() {
    return Container(
      padding: const EdgeInsets.all(1.5),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        gradient: LinearGradient(
          colors: [
            Colors.blue.withOpacity(0.5),
            Colors.purple.withOpacity(0.5),
            Colors.blue.withOpacity(0.5),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFF08080B),
          borderRadius: BorderRadius.circular(23),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
        child: Column(
          children: [
            // Nombre y Apellido en fila
            Row(
              children: [
                Expanded(child: _buildField(
                  controller: _firstNameController,
                  label: 'NOMBRE',
                  icon: Icons.badge_outlined,
                  validator: (v) => v == null || v.trim().isEmpty ? 'Requerido' : null,
                )),
                const SizedBox(width: 12),
                Expanded(child: _buildField(
                  controller: _lastNameController,
                  label: 'APELLIDO',
                  icon: Icons.badge_outlined,
                  validator: (v) => v == null || v.trim().isEmpty ? 'Requerido' : null,
                )),
              ],
            ),
            const SizedBox(height: 20),

            // Correo
            _buildField(
              controller: _emailController,
              label: 'CORREO ELECTRÓNICO',
              icon: Icons.email_outlined,
              keyboardType: TextInputType.emailAddress,
              validator: (v) {
                if (v == null || v.trim().isEmpty) return 'El correo es requerido';
                if (!_emailRegex.hasMatch(v.trim())) {
                  return 'Escribe un correo válido (ej: nombre@dominio.com)';
                }
                return null;
              },
            ),
            const SizedBox(height: 20),

            // Nombre de Usuario
            _buildField(
              controller: _usernameController,
              label: 'NOMBRE DE USUARIO',
              icon: Icons.alternate_email,
              validator: (v) {
                if (v == null || v.trim().isEmpty) return 'El usuario es requerido';
                if (v.trim().length < 4) return 'Mínimo 4 caracteres';
                if (v.trim().contains(' ')) return 'Sin espacios en el usuario';
                return null;
              },
            ),
            const SizedBox(height: 20),

            // Contraseña
            _buildField(
              controller: _passwordController,
              label: 'CONTRASEÑA',
              icon: Icons.lock_outline,
              isPassword: true,
              obscureText: _obscurePassword,
              onToggleObscure: () => setState(() => _obscurePassword = !_obscurePassword),
              validator: (v) {
                if (v == null || v.isEmpty) return 'La contraseña es requerida';
                if (v.length < 6) return 'Mínimo 6 caracteres';
                return null;
              },
            ),
            const SizedBox(height: 20),

            // Confirmar Contraseña
            _buildField(
              controller: _confirmController,
              label: 'CONFIRMAR CONTRASEÑA',
              icon: Icons.lock_person_outlined,
              isPassword: true,
              obscureText: _obscureConfirm,
              onToggleObscure: () => setState(() => _obscureConfirm = !_obscureConfirm),
              validator: (v) {
                if (v != _passwordController.text) return 'Las contraseñas no coinciden';
                return null;
              },
            ),
            const SizedBox(height: 32),

            // Botón Registrar
            Container(
              width: double.infinity,
              height: 55,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                gradient: const LinearGradient(
                  colors: [Color(0xFF00A3FF), Color(0xFFD400FF)],
                  begin: Alignment.centerLeft,
                  end: Alignment.centerRight,
                ),
                boxShadow: [
                  BoxShadow(color: const Color(0xFF00A3FF).withOpacity(0.3), blurRadius: 15, offset: const Offset(-5, 0)),
                  BoxShadow(color: const Color(0xFFD400FF).withOpacity(0.3), blurRadius: 15, offset: const Offset(5, 0)),
                ],
              ),
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: _isLoading ? null : _register,
                  borderRadius: BorderRadius.circular(12),
                  child: Center(
                    child: _isLoading
                        ? const CircularProgressIndicator(color: Colors.white, strokeWidth: 2)
                        : const Text(
                            'CREAR MI CUENTA',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 15,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 2,
                            ),
                          ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildField({
    required TextEditingController controller,
    required String label,
    required IconData icon,
    String? Function(String?)? validator,
    TextInputType keyboardType = TextInputType.text,
    bool isPassword = false,
    bool obscureText = false,
    VoidCallback? onToggleObscure,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            color: Color(0xFF00A3FF),
            fontSize: 10,
            fontWeight: FontWeight.bold,
            letterSpacing: 1.5,
          ),
        ),
        const SizedBox(height: 8),
        TextFormField(
          controller: controller,
          keyboardType: keyboardType,
          obscureText: isPassword ? obscureText : false,
          style: const TextStyle(color: Colors.white),
          validator: validator,
          autovalidateMode: AutovalidateMode.onUserInteraction,
          decoration: InputDecoration(
            prefixIcon: Icon(icon, color: const Color(0xFF00A3FF), size: 18),
            suffixIcon: isPassword
                ? IconButton(
                    icon: Icon(
                      obscureText ? Icons.visibility : Icons.visibility_off,
                      color: Colors.white38,
                      size: 18,
                    ),
                    onPressed: onToggleObscure,
                  )
                : null,
            filled: true,
            fillColor: Colors.white.withOpacity(0.04),
            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: Colors.white.withOpacity(0.1)),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: Colors.white.withOpacity(0.1)),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: Color(0xFF00A3FF)),
            ),
            errorBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: Colors.redAccent),
            ),
            focusedErrorBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: Colors.redAccent),
            ),
            errorStyle: const TextStyle(color: Colors.redAccent, fontSize: 11),
          ),
        ),
      ],
    );
  }
}
