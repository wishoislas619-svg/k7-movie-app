import 'package:flutter/material.dart';
import 'dart:async';
import 'package:movie_app/core/services/update_service.dart';

class SplashPage extends StatefulWidget {
  final VoidCallback onFinished;
  const SplashPage({super.key, required this.onFinished});

  @override
  State<SplashPage> createState() => _SplashPageState();
}

class _SplashPageState extends State<SplashPage> {
  double _progress = 0.0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _startLoading();
  }

  void _startLoading() {
    // Total duration around 3 seconds
    const totalDuration = Duration(milliseconds: 1500);
    const interval = Duration(milliseconds: 30);
    final steps = totalDuration.inMilliseconds / interval.inMilliseconds;
    double increment = 1.0 / steps;

    _timer = Timer.periodic(interval, (timer) {
      if (mounted) {
        setState(() {
          _progress += increment;
          if (_progress >= 1.0) {
            _progress = 1.0;
            timer.cancel();
            
            // Finish splash and navigate to main flow
            if (mounted) {
              Future.delayed(const Duration(milliseconds: 800), widget.onFinished);
            }
          }
        });
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
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
            center: Alignment.center,
            radius: 1.2,
            colors: [
              Color(0xFF001F2B), // Deep Blueish highlight
              Colors.black,
            ],
          ),
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            bool isLandscape = constraints.maxWidth > constraints.maxHeight;
            
            return SafeArea(
              child: Column(
                children: [
                  // Spacer to push logo towards center
                   const Spacer(flex: 2),
                  
                  // 1. Logo Area
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          const Text(
                            'K',
                            style: TextStyle(
                              fontSize: 85,
                              fontWeight: FontWeight.w900,
                              color: Color(0xFF4A90FF),
                              letterSpacing: -2,
                            ),
                          ),
                          const SizedBox(width: 5),
                          CustomPaint(
                            size: const Size(60, 60),
                            painter: K7LogoPainter(),
                          ),
                          const SizedBox(width: 15),
                          const Text(
                            'MOVIE',
                            style: TextStyle(
                              fontSize: 48,
                              fontWeight: FontWeight.w300,
                              letterSpacing: 8,
                              color: Color(0xFF6DE8FF),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      const Text(
                        'CINEMATIC EXCELLENCE',
                        style: TextStyle(
                          color: Colors.white38,
                          fontSize: 14,
                          letterSpacing: 6,
                          fontWeight: FontWeight.w400,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Container(
                        width: 40,
                        height: 1,
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [Colors.transparent, Colors.cyan.withOpacity(0.5), Colors.transparent],
                          ),
                        ),
                      ),
                    ],
                  ),

                  // Spacer between logo and loading
                  const Spacer(),

                  // 2. Loading Section
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 30),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text(
                              'INITIALIZING SYSTEM',
                              style: TextStyle(
                                color: Colors.white54,
                                fontSize: 14,
                                letterSpacing: 2,
                              ),
                            ),
                            Text(
                              '${(_progress * 100).toInt()}%',
                              style: const TextStyle(
                                color: Color(0xFF00E5FF),
                                fontSize: 14,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Stack(
                          children: [
                            Container(
                              height: 3,
                              width: double.infinity,
                              decoration: BoxDecoration(
                                color: Colors.white10,
                                borderRadius: BorderRadius.circular(5),
                              ),
                            ),
                            FractionallySizedBox(
                              widthFactor: _progress,
                              child: Container(
                                height: 3,
                                decoration: BoxDecoration(
                                  gradient: const LinearGradient(
                                    colors: [Color(0xFF4A90FF), Color(0xFFBC00FF)],
                                  ),
                                  borderRadius: BorderRadius.circular(5),
                                  boxShadow: [
                                    BoxShadow(
                                      color: const Color(0xFF4A90FF).withOpacity(0.5),
                                      blurRadius: 4,
                                      spreadRadius: 1,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),

                  // Spacer before footer
                  const Spacer(),

                  // 3. Footer
                  const Padding(
                    padding: EdgeInsets.only(bottom: 10),
                    child: Text(
                      '© 2026 K7 Studios. All Rights Reserved.',
                      style: TextStyle(
                        color: Colors.white24,
                        fontSize: 12,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
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
    // Recreating the geometric arrow/ribbon shape from the image
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
