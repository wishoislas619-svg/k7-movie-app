import 'dart:async';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class VirtualCursorOverlay extends StatefulWidget {
  final Widget child;
  const VirtualCursorOverlay({super.key, required this.child});

  @override
  State<VirtualCursorOverlay> createState() => _VirtualCursorOverlayState();
}

class _VirtualCursorOverlayState extends State<VirtualCursorOverlay> {
  Offset _position = const Offset(500, 300);
  bool _isVisible = false;
  Timer? _hideTimer;
  final double _moveStep = 15.0;
  final double _cursorSize = 30.0;

  // Track pressed keys for continuous movement
  final Set<LogicalKeyboardKey> _pressedKeys = {};
  Timer? _movementTimer;

  @override
  void dispose() {
    _hideTimer?.cancel();
    _movementTimer?.cancel();
    super.dispose();
  }

  void _showCursor() {
    if (!_isVisible) {
      setState(() => _isVisible = true);
    }
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 5), () {
      if (mounted) setState(() => _isVisible = false);
    });
  }

  void _updatePosition() {
    if (_pressedKeys.isEmpty) {
      _movementTimer?.cancel();
      _movementTimer = null;
      return;
    }

    if (_movementTimer == null) {
      _movementTimer = Timer.periodic(const Duration(milliseconds: 16), (timer) {
        double dx = 0;
        double dy = 0;

        if (_pressedKeys.contains(LogicalKeyboardKey.arrowUp)) dy -= _moveStep;
        if (_pressedKeys.contains(LogicalKeyboardKey.arrowDown)) dy += _moveStep;
        if (_pressedKeys.contains(LogicalKeyboardKey.arrowLeft)) dx -= _moveStep;
        if (_pressedKeys.contains(LogicalKeyboardKey.arrowRight)) dx += _moveStep;

        if (dx != 0 || dy != 0) {
          final size = MediaQuery.of(context).size;
          setState(() {
            _position = Offset(
              (_position.dx + dx).clamp(0.0, size.width),
              (_position.dy + dy).clamp(0.0, size.height),
            );
          });
          _showCursor();
        }
      });
    }
  }

  void _simulateTap() {
    _showCursor();
    const int pointerId = 0; 
    
    // Convert global position to local if needed, but here we use global
    final position = _position;

    // Dispatch PointerDown
    GestureBinding.instance.handlePointerEvent(PointerDownEvent(
      pointer: pointerId,
      position: position,
      kind: PointerDeviceKind.mouse,
    ));

    // Dispatch PointerUp after a small delay
    Future.delayed(const Duration(milliseconds: 50), () {
      GestureBinding.instance.handlePointerEvent(PointerUpEvent(
        pointer: pointerId,
        position: position,
        kind: PointerDeviceKind.mouse,
      ));
    });
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      autofocus: true,
      onKey: (node, event) {
        final isDown = event is RawKeyDownEvent;
        final key = event.logicalKey;

        // DPAD / Arrows for movement
        if (key == LogicalKeyboardKey.arrowUp || 
            key == LogicalKeyboardKey.arrowDown || 
            key == LogicalKeyboardKey.arrowLeft || 
            key == LogicalKeyboardKey.arrowRight) {
          
          if (isDown) {
            _pressedKeys.add(key);
          } else {
            _pressedKeys.remove(key);
          }
          _updatePosition();
          _showCursor();
          return KeyEventResult.handled;
        }

        // DPAD Center / Enter for click
        if (key == LogicalKeyboardKey.select || key == LogicalKeyboardKey.enter) {
          if (isDown) {
            _simulateTap();
          }
          return KeyEventResult.handled;
        }

        return KeyEventResult.ignored;
      },
      child: Stack(
        children: [
          widget.child,
          if (_isVisible)
            Positioned(
              left: _position.dx - (_cursorSize / 4),
              top: _position.dy - (_cursorSize / 4),
              child: IgnorePointer(
                child: Container(
                  width: _cursorSize,
                  height: _cursorSize,
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.5),
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 2),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.5),
                        blurRadius: 10,
                        spreadRadius: 2,
                      ),
                    ],
                  ),
                  child: const Center(
                    child: Icon(
                      Icons.mouse,
                      color: Colors.black,
                      size: 16,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// Extension to get a stable pointer ID
extension PointerEventWidgetsBinding on WidgetsBinding {
  int get pointerId => 0; // We can use a fixed ID for simple virtual cursor
}
