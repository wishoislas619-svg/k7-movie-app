import 'package:flutter/material.dart';

class TvFocusWrapper extends StatefulWidget {
  final Widget child;
  final VoidCallback onTap;
  final double borderRadius;
  final Color focusColor;
  final double scaleFactor;

  const TvFocusWrapper({
    super.key,
    required this.child,
    required this.onTap,
    this.borderRadius = 16,
    this.focusColor = const Color(0xFF00A3FF),
    this.scaleFactor = 1.08,
  });

  @override
  State<TvFocusWrapper> createState() => _TvFocusWrapperState();
}

class _TvFocusWrapperState extends State<TvFocusWrapper> {
  bool _isFocused = false;

  @override
  Widget build(BuildContext context) {
    return Focus(
      onFocusChange: (focused) {
        setState(() {
          _isFocused = focused;
        });
      },
      child: InkWell(
        onTap: widget.onTap,
        borderRadius: BorderRadius.circular(widget.borderRadius),
        focusColor: Colors.transparent, // Lo manejamos nosotros visualmente
        hoverColor: Colors.transparent,
        splashColor: widget.focusColor.withOpacity(0.3),
        highlightColor: Colors.transparent,
        child: AnimatedScale(
          scale: _isFocused ? widget.scaleFactor : 1.0,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(widget.borderRadius),
              border: Border.all(
                color: _isFocused ? widget.focusColor : Colors.transparent,
                width: 2.5,
              ),
              boxShadow: _isFocused
                  ? [
                      BoxShadow(
                        color: widget.focusColor.withOpacity(0.5),
                        blurRadius: 15,
                        spreadRadius: 2,
                      )
                    ]
                  : [],
            ),
            child: widget.child,
          ),
        ),
      ),
    );
  }
}
