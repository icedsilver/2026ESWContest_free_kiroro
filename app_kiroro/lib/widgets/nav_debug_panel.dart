import 'dart:math';
import 'dart:ui' show FontFeature;

import 'package:flutter/material.dart';

import '../controllers/navigation_controller.dart';

/// 개발용 디버그 오버레이.
///
/// 큰 화살표 UI 대신 "지금 내 방향 기준으로 목적지가 어느 쪽에 있는지"를
/// 각도와 숫자로 직접 보여준다. 도착 판정이 왜 안 걸리는지 현장에서
/// 바로 눈으로 확인하려고 만든 것이므로, 시연 전에는 [enabled]를 false로.
///
/// 사용법: MainScreen._buildNavigatingView()의 Stack children 맨 뒤에
///   NavDebugPanel(nav: _nav)
/// 를 추가하면 된다.
class NavDebugPanel extends StatelessWidget {
  const NavDebugPanel({
    super.key,
    required this.nav,
    this.enabled = true,
  });

  final NavigationController nav;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    if (!enabled) return const SizedBox.shrink();

    final heading = nav.debugHeading;          // 내가 보고 있는 방향
    final bearing = nav.debugBearingToDest;    // 목적지의 절대 방위
    // 상대각: 0 = 정면, 90 = 오른쪽 직각, 270 = 왼쪽 직각
    final rel = (heading == null || bearing == null)
        ? null
        : (bearing - heading + 360) % 360;

    return Positioned(
      top: 8,
      right: 8,
      child: Container(
        width: 180,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.78),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _compass(rel),
            const SizedBox(height: 8),
            _row('목적지', '${nav.distToDestination.toStringAsFixed(1)} m',
                warn: nav.distToDestination > 15),
            _row('상대각', rel == null ? '- (방향 없음)' : _relLabel(rel)),
            _row('방위/헤딩',
                '${bearing?.toStringAsFixed(0) ?? '-'}° / ${heading?.toStringAsFixed(0) ?? '-'}°'),
            _row('GPS 오차', '±${nav.debugAccuracy.toStringAsFixed(0)} m',
                warn: nav.debugAccuracy > 25),
            _row('도착 카운트', '${nav.debugArrivalFix} / 3',
                warn: nav.debugArrivalFix > 0),
            _row('경유지', '${nav.routeIndex} / ${nav.waypoints.length}'),
            _row('다음까지', '${nav.distToNext.toStringAsFixed(0)} m'),
          ],
        ),
      ),
    );
  }

  /// 상대각만큼 회전하는 화살표. 위쪽이 내가 보는 방향이다.
  Widget _compass(double? rel) {
    return Center(
      child: Container(
        width: 84,
        height: 84,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white24, width: 2),
        ),
        child: rel == null
            ? const Center(
            child: Text('방향\n없음',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white38, fontSize: 11)))
            : Transform.rotate(
          angle: rel * pi / 180,
          child: Icon(
            Icons.navigation,
            size: 52,
            // 정면 ±30도면 초록 (그 방향으로 걸으면 됨)
            color: (rel < 30 || rel > 330)
                ? Colors.greenAccent
                : Colors.orangeAccent,
          ),
        ),
      ),
    );
  }

  String _relLabel(double rel) {
    if (rel < 15 || rel > 345) return '정면 (${rel.toStringAsFixed(0)}°)';
    if (rel <= 180) return '오른쪽 ${rel.toStringAsFixed(0)}°';
    return '왼쪽 ${(360 - rel).toStringAsFixed(0)}°';
  }

  Widget _row(String label, String value, {bool warn = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label,
              style: const TextStyle(color: Colors.white54, fontSize: 11)),
          Text(value,
              style: TextStyle(
                color: warn ? Colors.orangeAccent : Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w600,
                fontFeatures: const [FontFeature.tabularFigures()],
              )),
        ],
      ),
    );
  }
}