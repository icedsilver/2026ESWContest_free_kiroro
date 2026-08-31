/// 경로 상의 한 지점(경유지 또는 안내 포인트)을 나타내는 불변 데이터 모델.
class Waypoint {
  final double lat;
  final double lon;
  final String turnType; // STRAIGHT | LEFT | RIGHT | UTURN | ARRIVED
  final String description;
  final String name;
  final String facility;

  const Waypoint({
    required this.lat,
    required this.lon,
    required this.turnType,
    required this.description,
    required this.name,
    this.facility = '',
  });
}

/// 블루투스로 전송할 회전 신호 코드 (1바이트 프로토콜).
class BtCode {
  static const int straight = 0x00;
  static const int left = 0x01;
  static const int right = 0x02;
  static const int uturn = 0x03;
  static const int arrived = 0x04;

  static int fromTurnType(String t) {
    switch (t) {
      case 'LEFT':
        return left;
      case 'RIGHT':
        return right;
      case 'UTURN':
        return uturn;
      case 'ARRIVED':
        return arrived;
      default:
        return straight;
    }
  }
}