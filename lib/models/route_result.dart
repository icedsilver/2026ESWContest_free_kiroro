import 'waypoint.dart';

/// 서버로부터 받은 경로 응답을 표현하는 모델.
///
/// UI/내비게이션 로직은 이 모델만 바라본다. 서버가 텍스트 프로토콜에서
/// JSON으로 바뀌더라도 이 모델의 필드는 그대로 유지되므로, 영향 범위는
/// [RouteService] 내부 파싱 로직 하나로 국한된다.
///
/// v2 변경사항 (서버 트래킹 연동):
/// 1. [sessionId] 필드 추가. 서버가 INFO 세그먼트 7번째 필드로 내려주는
///    세션 ID를 담아, 이후 /api/navigation/track 호출 시 그대로 실어보낸다.
///    구버전 서버 응답(필드가 6개뿐인 경우)과의 하위호환을 위해
///    기본값은 빈 문자열('')로 두고, 필수(required)로 강제하지 않는다.
class RouteResult {
  final int totalDistance; // meters
  final int totalTime; // seconds
  final String destinationName;
  final double destinationLat;
  final double destinationLon;
  final List<Waypoint> waypoints;
  final String sessionId; // NEW: /api/navigation/track 트래킹용 세션 ID

  const RouteResult({
    required this.totalDistance,
    required this.totalTime,
    required this.destinationName,
    required this.destinationLat,
    required this.destinationLon,
    required this.waypoints,
    this.sessionId = '',
  });

  bool get hasDestinationCoordinate => destinationLat != 0 || destinationLon != 0;

  /// 서버 트래킹(/api/navigation/track)을 호출할 수 있는 상태인지.
  /// sessionId가 없으면 NavigationController가 트래킹 전송 자체를 건너뛴다.
  bool get canTrack => sessionId.isNotEmpty;
}

/// 경로 응답 파싱 실패 시 던지는 예외.
/// 원본 코드처럼 `int.tryParse(...) ?? 0`으로 조용히 넘어가지 않고,
/// 호출자가 반드시 처리하도록 강제한다. (도착 오판정 등 안전 문제 방지)
class RouteParseException implements Exception {
  final String message;
  final String? rawSegment;
  RouteParseException(this.message, [this.rawSegment]);

  @override
  String toString() =>
      'RouteParseException: $message${rawSegment != null ? ' (segment: "$rawSegment")' : ''}';
}

/// /api/navigation/track 응답 결과.
///
/// 서버가 GPS 좌표를 도로망에 스냅하고, 세션 시작 이후 누적 도보거리를
/// 계산해 돌려준다. NavigationController의 로컬 안내 로직(웨이포인트
/// 통과/도착 판정)과는 완전히 별개 — 화면에 "지금까지 걸은 거리"를
/// 보여주는 용도로만 쓰인다.
class TrackResult {
  final double totalDistanceWalked; // meters, 세션 시작 이후 누적
  const TrackResult({required this.totalDistanceWalked});
}