import 'package:flutter/material.dart';

class EnergyFlowBorder extends StatefulWidget {
  final Widget child;
  final double borderRadius;
  final double borderWidth;
  final Duration duration;
  final List<Color>? colors;
  final EdgeInsets padding;
  final Color backgroundColor;

  const EnergyFlowBorder({
    super.key,
    required this.child,
    this.borderRadius = 16,
    this.borderWidth = 1.5,
    this.duration = const Duration(seconds: 6),
    this.colors,
    this.padding = const EdgeInsets.all(0),
    this.backgroundColor = const Color(0xFF161616),
  });

  @override
  State<EnergyFlowBorder> createState() => _EnergyFlowBorderState();
}

class _EnergyFlowBorderState extends State<EnergyFlowBorder> with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: widget.duration,
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = widget.colors ?? const [
      Color(0xFF00A3FF),
      Color(0xFFD400FF),
      Color(0xFF00FFD1),
      Color(0xFF4A90FF),
      Color(0xFFBC00FF),
      Color(0xFF00FFD1),
      Color(0xFF00A3FF),
    ];

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(widget.borderRadius),
          ),
          child: Stack(
            children: [
              // Rotating Iridescent Border
              Positioned.fill(
                child: Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(widget.borderRadius),
                    gradient: SweepGradient(
                      center: Alignment.center,
                      transform: GradientRotation(_controller.value * 2 * 3.14159),
                      colors: colors,
                    ),
                  ),
                ),
              ),
              // Inner background
              Positioned.fill(
                child: Container(
                  margin: EdgeInsets.all(widget.borderWidth),
                  decoration: BoxDecoration(
                    color: widget.backgroundColor,
                    borderRadius: BorderRadius.circular(widget.borderRadius - widget.borderWidth),
                  ),
                ),
              ),
              // Content
              Padding(
                padding: EdgeInsets.all(widget.borderWidth).add(widget.padding),
                child: widget.child,
              ),
            ],
          ),
        );
      },
    );
  }
}
