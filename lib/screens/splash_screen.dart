import 'dart:async';
import 'package:flutter/material.dart';
import '../main.dart'; // MainScreen 경로에 맞게 수정해주세요

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> with SingleTickerProviderStateMixin {
  late AnimationController _animationController;
  late Animation<Offset> _slideAnimation; // 위치 이동 애니메이션

  @override
  void initState() {
    super.initState();

    // 1. 애니메이션 진행 시간 설정 (1.5초가 가장 자연스럽습니다)
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    );

    // 2. 화면 위(-2.5 위치)에서 중앙(0.0 위치)으로 떨어지는 애니메이션 설정
    _slideAnimation = Tween<Offset>(
      begin: const Offset(0, -2.5), // Y축 기준 화면 상단 바깥쪽
      end: Offset.zero,             // 화면 중앙 정위치
    ).animate(
      CurvedAnimation(
        parent: _animationController,
        curve: Curves.bounceOut, // 바닥/중앙에 착지하며 통통 튀는 바운스 효과
      ),
    );

    // 애니메이션 시작
    _animationController.forward();

    // 3. 2.5초 후 메인 화면으로 이동
    Timer(const Duration(milliseconds: 2500), () {
      if (mounted) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const MainScreen()),
        );
      }
    });
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: Center(
        // SlideTransition으로 위치 변환 적용
        child: SlideTransition(
          position: _slideAnimation,
          child: Image.asset(
            'assets/eye2.png',
            width: 150,
            height: 150,
          ),
        ),
      ),
    );
  }
}