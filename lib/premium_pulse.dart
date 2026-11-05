import 'dart:math' as math;
import 'package:flutter/material.dart';

/// Χρυσό κουμπί-χάπι που «αναπνέει»: η λάμψη και το περίγραμμα δυναμώνουν και
/// σβήνουν απαλά, ενώ ένα φως περνά πάνω από το περιεχόμενο.
class PremiumPulse extends StatefulWidget {
  final Widget child;
  final Color color;
  final EdgeInsetsGeometry padding;
  const PremiumPulse({
    super.key,
    required this.child,
    required this.color,
    this.padding = const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
  });

  @override
  State<PremiumPulse> createState() => _PremiumPulseState();
}

class _PremiumPulseState extends State<PremiumPulse> with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 2600))..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.color;
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _ctrl,
        child: Padding(padding: widget.padding, child: widget.child),
        builder: (_, child) {
          final t = _ctrl.value;
          final glow = 0.5 - 0.5 * math.cos(2 * math.pi * t);
          // Το φως περνά στο πρώτο 60% του κύκλου και μετά το κουμπί ησυχάζει.
          final shine = -0.3 + 1.6 * (t / 0.6).clamp(0.0, 1.0);
          return Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              color: c.withValues(alpha: 0.12 + 0.14 * glow),
              border: Border.all(color: c.withValues(alpha: 0.4 + 0.6 * glow), width: 1.2),
              boxShadow: [
                BoxShadow(
                  color: c.withValues(alpha: 0.12 + 0.5 * glow),
                  blurRadius: 5 + 13 * glow,
                  spreadRadius: 0.6 * glow,
                ),
              ],
            ),
            child: ShaderMask(
              blendMode: BlendMode.srcATop,
              shaderCallback: (rect) => LinearGradient(
                colors: [
                  Colors.white.withValues(alpha: 0),
                  Colors.white.withValues(alpha: 0.9),
                  Colors.white.withValues(alpha: 0),
                ],
                stops: [
                  (shine - 0.18).clamp(0.0, 1.0),
                  shine.clamp(0.0, 1.0),
                  (shine + 0.18).clamp(0.0, 1.0),
                ],
              ).createShader(rect),
              child: child,
            ),
          );
        },
      ),
    );
  }
}
