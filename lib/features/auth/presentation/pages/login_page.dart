import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/auth_provider.dart';
import 'register_page.dart';
import '../../../../core/services/storage_service.dart';
import '../../../../shared/widgets/energy_flow_border.dart';

class LoginPage extends ConsumerStatefulWidget {
  const LoginPage({super.key});

  @override
  ConsumerState<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends ConsumerState<LoginPage> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _isLoading = false;
  bool _obscurePassword = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkAutoLogin());
  }

  Future<void> _checkAutoLogin() async {
    final isEnabled = await StorageService.isAutoLoginEnabled();
    if (!isEnabled) return;

    final email = await StorageService.getStoredEmail();
    final password = await StorageService.getStoredPassword();

    if (email != null && password != null) {
      if (mounted) {
        setState(() {
          _emailController.text = email;
          _passwordController.text = password;
        });
        _login();
      }
    }
  }

  void _login() async {
    // Hide keyboard
    FocusScope.of(context).unfocus();

    final password = _passwordController.text;
    if (password.length < 6) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('La contraseña debe tener al menos 6 caracteres', style: TextStyle(color: Colors.white)),
            backgroundColor: Colors.redAccent.withOpacity(0.8),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return;
    }

    setState(() => _isLoading = true);
    final success = await ref.read(authStateProvider.notifier).login(
      _emailController.text.trim(),
      _passwordController.text,
    );
    setState(() => _isLoading = false);

    if (!success) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
           SnackBar(
            content: const Text('Credenciales incorrectas', style: TextStyle(color: Colors.white)),
            backgroundColor: Colors.redAccent.withOpacity(0.8),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  void _loginWithGoogle() async {
    FocusScope.of(context).unfocus();
    setState(() => _isLoading = true);
    try {
      await ref.read(authStateProvider.notifier).signInWithGoogle();
    } catch (e) {
       // Log info useful for debugging
       debugPrint('Error en login con Google: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error al iniciar con Google: $e', style: const TextStyle(color: Colors.white)),
            backgroundColor: Colors.redAccent.withOpacity(0.8),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
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
            colors: [
              Color(0xFF0D031A), // Subtle deep dark purple at top
              Colors.black,
            ],
          ),
        ),
        child: SafeArea(
          child: SingleChildScrollView(
            physics: const BouncingScrollPhysics(),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  const SizedBox(height: 10),
                  // App Logo
                  _buildLogo(),
                  const SizedBox(height: 10),
                  
                  // Login Card
                  _buildLoginCard(),
                  
                  const SizedBox(height: 40),
                  
                  // Bottom Icons
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _buildBottomIcon(Icons.language),
                      const SizedBox(width: 24),
                      _buildBottomIcon(Icons.help_outline),
                      const SizedBox(width: 24),
                      _buildBottomIcon(Icons.info_outline),
                    ],
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

  Widget _buildLogo() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        const Text(
          'K',
          style: TextStyle(
            fontSize: 60,
            fontWeight: FontWeight.w900,
            color: Color(0xFF4A90FF),
            letterSpacing: -2,
          ),
        ),
        const SizedBox(width: 2),
        CustomPaint(
          size: const Size(45, 45),
          painter: K7LogoPainter(),
        ),
        const SizedBox(width: 12),
        const Text(
          'MOVIE',
          style: TextStyle(
            fontSize: 34,
            fontWeight: FontWeight.w300,
            letterSpacing: 6,
            color: Color(0xFF6DE8FF),
          ),
        ),
      ],
    );
  }

  Widget _buildLoginCard() {
    return EnergyFlowBorder(
      borderRadius: 24,
      borderWidth: 1.5,
      backgroundColor: const Color(0xFF08080B),
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 25),
        child: Column(
          children: [
            // Title
            const Text(
              'BIENVENIDO',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white,
                fontSize: 26,
                fontWeight: FontWeight.w900,
                letterSpacing: 2,
                height: 1.2,
              ),
            ),
            const SizedBox(height: 16),
            
            // Username/Email Field
            TextField(
              controller: _emailController,
              keyboardType: TextInputType.emailAddress,
              style: const TextStyle(color: Colors.white),
              decoration: _buildInputDecoration('NOMBRE DE USUARIO O CORREO', Icons.person_outline),
            ),
            const SizedBox(height: 16),
            
            // Password Field
            TextField(
              controller: _passwordController,
              obscureText: _obscurePassword,
              style: const TextStyle(color: Colors.white),
              decoration: _buildInputDecoration('CONTRASEÑA', Icons.lock_outline).copyWith(
                suffixIcon: IconButton(
                  icon: Icon(_obscurePassword ? Icons.visibility_off_outlined : Icons.visibility_outlined, color: Colors.white24, size: 20),
                  onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
                ),
              ),
            ),
            const SizedBox(height: 24),
            
            // Entrar Button
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
                  BoxShadow(
                    color: const Color(0xFF00A3FF).withOpacity(0.3),
                    blurRadius: 15,
                    offset: const Offset(-5, 0),
                  ),
                  BoxShadow(
                    color: const Color(0xFFD400FF).withOpacity(0.3),
                    blurRadius: 15,
                    offset: const Offset(5, 0),
                  )
                ],
              ),
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: _isLoading ? null : _login,
                  borderRadius: BorderRadius.circular(12),
                  child: Center(
                    child: _isLoading
                      ? const CircularProgressIndicator(color: Colors.white)
                      : const Text(
                          'ENTRAR',
                          style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold, letterSpacing: 2),
                        ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            
            // Crear Cuenta Button
            Container(
              width: double.infinity,
              height: 55,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                color: Colors.white.withOpacity(0.03),
                border: Border.all(color: Colors.white.withOpacity(0.1)),
              ),
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: () {
                    Navigator.push(context, MaterialPageRoute(builder: (_) => const RegisterPage()));
                  },
                  borderRadius: BorderRadius.circular(12),
                  child: const Center(
                    child: Text(
                      'CREAR CUENTA',
                      style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold, letterSpacing: 2),
                    ),
                  ),
                ),
              ),
            ),

            const SizedBox(height: 12),

            // Iniciar Sesión con Google
            Container(
              width: double.infinity,
              height: 55,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                color: Colors.white,
              ),
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: _isLoading ? null : _loginWithGoogle,
                  borderRadius: BorderRadius.circular(12),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Text(
                        'CONTINUAR CON GOOGLE',
                        style: TextStyle(color: Colors.black, fontSize: 13, fontWeight: FontWeight.bold, letterSpacing: 1),
                      ),
                      const SizedBox(width: 12),
                      Image.network(
                        'https://static.vecteezy.com/system/resources/previews/022/613/027/non_2x/google-icon-logo-symbol-free-png.png',
                        height: 24,
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 20),
            
            // Forgot Password
            TextButton(
              onPressed: () => _showForgotPasswordDialog(),
              child: const Text('¿OLVIDASTE TU CONTRASEÑA?', style: TextStyle(color: Colors.white38, fontSize: 10, letterSpacing: 1.5, fontWeight: FontWeight.bold)),
            ),
            
            const SizedBox(height: 10),
            
            // Perdiste tu dispositivo
            TextButton(
              onPressed: () => _showRecoveryDialog(),
              child: const Text('¿PERDISTE TU DISPOSITIVO?', style: TextStyle(color: Color(0xFF00A3FF), fontSize: 10, letterSpacing: 1.5, fontWeight: FontWeight.bold)),
            )
          ],
        ),
      );
    }

  void _showForgotPasswordDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        final emailController = TextEditingController(text: _emailController.text.contains('@') ? _emailController.text.trim() : '');
        final codeController = TextEditingController();
        final passController = TextEditingController();
        final confirmPassController = TextEditingController();
        
        int step = 1; // 1: Email, 2: OTP, 3: New Password
        bool isLoading = false;

        return StatefulBuilder(
          builder: (context, setModalState) {
            return AlertDialog(
              backgroundColor: const Color(0xFF08080B),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20), side: const BorderSide(color: Color(0xFF00A3FF), width: 0.5)),
              title: Text(
                step == 1 ? 'RECUPERAR CONTRASEÑA' : (step == 2 ? 'VERIFICAR CÓDIGO' : 'NUEVA CONTRASEÑA'),
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
              ),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (step == 1) ...[
                      const Text('Ingresa tu correo para recibir un código de recuperación:', style: TextStyle(color: Colors.white70, fontSize: 13)),
                      const SizedBox(height: 12),
                      TextField(
                        controller: emailController,
                        keyboardType: TextInputType.emailAddress,
                        style: const TextStyle(color: Colors.white),
                        decoration: _dialogInputDecoration('CORREO ELECTRÓNICO', Icons.email),
                      ),
                    ] else if (step == 2) ...[
                      Text('Ingresa el código de 6 dígitos enviado a ${emailController.text}:', style: const TextStyle(color: Colors.white70, fontSize: 13)),
                      const SizedBox(height: 12),
                      TextField(
                        controller: codeController,
                        keyboardType: TextInputType.number,
                        maxLength: 6,
                        style: const TextStyle(color: Colors.white, fontSize: 24, letterSpacing: 8),
                        textAlign: TextAlign.center,
                        decoration: _dialogInputDecoration('CÓDIGO (000000)', null).copyWith(counterText: ''),
                      ),
                    ] else ...[
                      const Text('Ingresa tu nueva contraseña para completar el proceso:', style: TextStyle(color: Colors.white70, fontSize: 13)),
                      const SizedBox(height: 12),
                      TextField(
                        controller: passController,
                        obscureText: true,
                        style: const TextStyle(color: Colors.white),
                        decoration: _dialogInputDecoration('NUEVA CONTRASEÑA', Icons.lock),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: confirmPassController,
                        obscureText: true,
                        style: const TextStyle(color: Colors.white),
                        decoration: _dialogInputDecoration('CONFIRMAR CONTRASEÑA', Icons.lock_outline),
                      ),
                    ],
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('CANCELAR', style: TextStyle(color: Colors.white38)),
                ),
                ElevatedButton(
                  onPressed: isLoading ? null : () async {
                    if (step == 1) {
                      if (!emailController.text.contains('@')) return;
                      setModalState(() => isLoading = true);
                      final ok = await ref.read(authStateProvider.notifier).sendRecoveryOtp(emailController.text.trim());
                      setModalState(() { isLoading = false; if (ok) step = 2; });
                    } else if (step == 2) {
                      if (codeController.text.length < 6) return;
                      setModalState(() => isLoading = true);
                      final ok = await ref.read(authStateProvider.notifier).verifyRecoveryOtp(emailController.text.trim(), codeController.text.trim());
                      setModalState(() { isLoading = false; if (ok) step = 3; });
                      if (!ok && mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Código inválido")));
                    } else {
                      if (passController.text.isEmpty || passController.text != confirmPassController.text) {
                         ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Las contraseñas no coinciden")));
                         return;
                      }
                      setModalState(() => isLoading = true);
                      final ok = await ref.read(authStateProvider.notifier).resetPassword(passController.text.trim());
                      setModalState(() => isLoading = false);
                      
                      if (ok && mounted) {
                        Navigator.pop(context);
                        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("¡Contraseña actualizada correctamente!")));
                      } else {
                        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Error al actualizar contraseña")));
                      }
                    }
                  },
                  style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00A3FF)),
                  child: Text(isLoading ? '...' : (step == 3 ? 'ACTUALIZAR' : 'CONTINUAR')),
                ),
              ],
            );
          },
        );
      },
    );
  }

  InputDecoration _buildInputDecoration(String hint, IconData icon) {
    return InputDecoration(
      hintText: hint,
      prefixIcon: Icon(icon, color: const Color(0xFF00A3FF).withOpacity(0.6), size: 20),
      hintStyle: const TextStyle(color: Colors.white24, fontSize: 12, letterSpacing: 1.2, fontWeight: FontWeight.bold),
      filled: true,
      fillColor: Colors.white.withOpacity(0.03),
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: Colors.white.withOpacity(0.06)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: Colors.white.withOpacity(0.06)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: const BorderSide(color: Color(0xFF00A3FF), width: 1.5),
      ),
    );
  }

  InputDecoration _dialogInputDecoration(String hint, IconData? icon) {
    return _buildInputDecoration(hint, icon ?? Icons.code).copyWith(
      fillColor: Colors.white.withOpacity(0.04),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
    );
  }

  void _showRecoveryDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        final emailController = TextEditingController(text: _emailController.text.contains('@') ? _emailController.text.trim() : '');
        final codeController = TextEditingController();
        bool isSending = false;

        return StatefulBuilder(
          builder: (context, setModalState) {
            return AlertDialog(
              backgroundColor: const Color(0xFF08080B),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20), side: const BorderSide(color: Color(0xFF00A3FF), width: 0.5)),
              title: const Text('RECUPERAR ACCESO', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Correo del dispositivo perdido:', style: TextStyle(color: Colors.white70, fontSize: 13)),
                    const SizedBox(height: 12),
                    TextField(
                      controller: emailController,
                      keyboardType: TextInputType.emailAddress,
                      style: const TextStyle(color: Colors.white, fontSize: 14),
                      decoration: _dialogInputDecoration('CORREO ELECTRÓNICO', Icons.email),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: codeController,
                      keyboardType: TextInputType.number,
                      maxLength: 6,
                      style: const TextStyle(color: Colors.white, fontSize: 24, letterSpacing: 8),
                      textAlign: TextAlign.center,
                      decoration: _dialogInputDecoration('CÓDIGO', null).copyWith(counterText: ''),
                    ),
                    const SizedBox(height: 16),
                    const Text('¿No tienes acceso al correo? Contáctanos:', style: TextStyle(color: Colors.white38, fontSize: 11)),
                    TextButton(
                      onPressed: () {}, // WhatsApp link
                      child: const Text('WhatsApp: 7792282959', style: TextStyle(color: Colors.greenAccent, fontSize: 12)),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('CANCELAR', style: TextStyle(color: Colors.white38)),
                ),
                ElevatedButton(
                  onPressed: isSending ? null : () async {
                    if (codeController.text.length < 6) {
                      setModalState(() => isSending = true);
                      await ref.read(authStateProvider.notifier).sendRecoveryOtp(emailController.text.trim());
                      setModalState(() => isSending = false);
                    } else {
                      setModalState(() => isSending = true);
                      final ok = await ref.read(authStateProvider.notifier).verifyRecoveryOtp(emailController.text.trim(), codeController.text.trim());
                      setModalState(() => isSending = false);
                      if (ok && mounted) Navigator.pop(context);
                    }
                  },
                  style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00A3FF)),
                  child: Text(isSending ? '...' : (codeController.text.length < 6 ? 'ENVIAR CÓDIGO' : 'VERIFICAR')),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildBottomIcon(IconData icon) {
    return Container(
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.05),
        shape: BoxShape.circle,
      ),
      child: Icon(icon, color: Colors.white38, size: 20),
    );
  }
}

class K7LogoPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.bottomLeft,
        end: Alignment.topRight,
        colors: [Color(0xFF4A90FF), Color(0xFFBC00FF)],
      ).createShader(Rect.fromLTWH(0, 0, size.width, size.height));

    final path = Path();
    path.moveTo(size.width * 0.1, size.height * 0.1);
    path.lineTo(size.width * 0.9, size.height * 0.1);
    path.lineTo(size.width * 0.9, size.height * 0.9);
    path.lineTo(size.width * 0.5, size.height * 0.9);
    path.lineTo(size.width * 0.5, size.height * 0.5);
    path.lineTo(size.width * 0.1, size.height * 0.9);
    path.close();

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
