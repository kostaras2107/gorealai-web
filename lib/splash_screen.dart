import 'dart:async';
import 'package:flutter/material.dart';
import 'main.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with TickerProviderStateMixin {

  late AnimationController _mainCtrl;
  late AnimationController _shimmerCtrl;

  late Animation<double> _fade;
  late Animation<double> _scale;
  late Animation<double> _glow;
  late Animation<double> _shimmer;

  static const String _fullText = "GoReal";
  String _text = "";

  @override
  void initState() {
    super.initState();

    _mainCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    );

    _shimmerCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat();

    _fade = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _mainCtrl, curve: Curves.easeOut),
    );

    _scale = Tween<double>(begin: 0.85, end: 1.0).animate(
      CurvedAnimation(parent: _mainCtrl, curve: Curves.easeOut),
    );

    _glow = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _mainCtrl, curve: Curves.easeOut),
    );

    _shimmer = Tween<double>(begin: -1.0, end: 2.0).animate(
      CurvedAnimation(parent: _shimmerCtrl, curve: Curves.easeInOut),
    );

    _mainCtrl.forward();
    _runSequence();
  }

  Future<void> _runSequence() async {
    for (int i = 1; i <= _fullText.length; i++) {
      await Future.delayed(const Duration(milliseconds: 120));
      if (!mounted) return;
      setState(() => _text = _fullText.substring(0, i));
    }

    await Future.delayed(const Duration(milliseconds: 1000));
    if (!mounted) return;

    Navigator.pushReplacement(
      context,
      PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 800),
        pageBuilder: (_, __, ___) => const AuthGate(),
        transitionsBuilder: (_, anim, __, child) =>
            FadeTransition(opacity: anim, child: child),
      ),
    );
  }

  @override
  void dispose() {
    _mainCtrl.dispose();
    _shimmerCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // Ambient glow background
          Positioned.fill(
            child: AnimatedBuilder(
              animation: _glow,
              builder: (_, __) => DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: Alignment.center,
                    radius: 0.8,
                    colors: [
                      const Color(0xFFD4A843).withOpacity(0.12 * _glow.value),
                      Colors.transparent,
                    ],
                  ),
                ),
              ),
            ),
          ),

          // Main content
          Center(
            child: AnimatedBuilder(
              animation: Listenable.merge([_mainCtrl, _shimmerCtrl]),
              builder: (_, __) {
                return FadeTransition(
                  opacity: _fade,
                  child: Transform.scale(
                    scale: _scale.value,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [

                        // Shimmer text
                        ShaderMask(
                          shaderCallback: (bounds) {
                            return LinearGradient(
                              begin: Alignment.centerLeft,
                              end: Alignment.centerRight,
                              colors: const [
                                Color(0xFFD4A843),
                                Color(0xFFFFF0A0),
                                Color(0xFFD4A843),
                                Color(0xFF8A6010),
                                Color(0xFFD4A843),
                              ],
                              stops: [
                                0.0,
                                (_shimmer.value - 0.1).clamp(0.0, 1.0),
                                _shimmer.value.clamp(0.0, 1.0),
                                (_shimmer.value + 0.1).clamp(0.0, 1.0),
                                1.0,
                              ],
                            ).createShader(bounds);
                          },
                          child: Text(
                            _text,
                            style: const TextStyle(
                              fontSize: 46,
                              fontWeight: FontWeight.w700,
                              fontFamily: 'Georgia',
                              color: Colors.white,
                              letterSpacing: 1.5,
                            ),
                          ),
                        ),

                        const SizedBox(height: 10),

                        // Tagline fade in
                        Opacity(
                          opacity: _text == _fullText ? _glow.value : 0.0,
                          child: Text(
                            'The first app with Reverse Auction',
                            style: TextStyle(
                              fontSize: 13,
                              color: Colors.white.withOpacity(0.4),
                              fontWeight: FontWeight.w300,
                              letterSpacing: 0.3,
                            ),
                          ),
                        ),

                        const SizedBox(height: 40),

                        // Gold animated dots
                        _GoldDots(),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

// Animated loading dots
class _GoldDots extends StatefulWidget {
  @override
  State<_GoldDots> createState() => _GoldDotsState();
}

class _GoldDotsState extends State<_GoldDots>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (_, __) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: List.generate(3, (i) {
            final delay = i / 3;
            final value = ((_ctrl.value - delay) % 1.0).clamp(0.0, 1.0);
            final opacity = (value < 0.5 ? value * 2 : (1 - value) * 2)
                .clamp(0.2, 1.0);
            return Container(
              margin: const EdgeInsets.symmetric(horizontal: 4),
              width: 5, height: 5,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0xFFD4A843).withOpacity(opacity),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFFD4A843).withOpacity(opacity * 0.5),
                    blurRadius: 6,
                  ),
                ],
              ),
            );
          }),
        );
      },
    );
  }
}