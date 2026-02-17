import 'dart:async';
import 'package:flutter/material.dart';
import 'package:shoppilot/main.dart';
import 'main.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController controller;
  late Animation<double> glow;
  late Animation<double> scale;

  String text = "Go";

  @override
  void initState() {
    super.initState();

    controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    );

    glow = Tween<double>(begin: 0.2, end: 1).animate(
      CurvedAnimation(parent: controller, curve: Curves.easeOut),
    );

    scale = Tween<double>(begin: 0.9, end: 1.05).animate(
      CurvedAnimation(parent: controller, curve: Curves.easeOut),
    );

    controller.forward();

    _runSequence();
  }

  Future<void> _runSequence() async {
    await Future.delayed(const Duration(milliseconds: 700));
    setState(() => text = "GoReal");

    await Future.delayed(const Duration(milliseconds: 700));
    setState(() => text = "GoRealAI");

    await Future.delayed(const Duration(milliseconds: 900));

    if (!mounted) return;

    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (_) => const AuthGate()),
    );
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Center(
        child: AnimatedBuilder(
          animation: controller,
          builder: (_, __) {
            return Transform.scale(
              scale: scale.value,
              child: Text(
                text,
                style: TextStyle(
                  fontSize: 42,
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                  letterSpacing: 1.2,
                  shadows: [
                    BoxShadow(
                      color: Colors.orange.withOpacity(glow.value),
                      blurRadius: 25 * glow.value,
                      spreadRadius: 5 * glow.value,
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}