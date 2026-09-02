import 'dart:convert';

import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;

import '../models/route_result.dart';
import '../models/waypoint.dart';

/// 서버와의 경로 요청/응답, 그리고 실시간 위치 트래킹을 전담하는 서비스.
///
/// 현재 서버는 파이프(|)/콤마(,) 구분 텍스트 프로토콜을 사용하므로 그에 맞춰
/// 파싱한다. 추후 서버가 JSON으로 전환되면 이 파일의 [_parseRouteData]만
/// 교체하면 되고, 다른 계층(NavigationController, UI)은 [RouteResult] 모델만
/// 바라보므로 영향을 받지 않는다.
///
/// 원본 코드와의 차이: 필드 파싱 실패 시 `?? 0`으로 조용히 넘어가지 않고
/// [RouteParseException]을 던진다. 예를 들어 좌표 파싱이 실패한 채로
/// (0,0) 좌표가 도착 판정 로직에 들어가면 "도착하지 않았는데 도착했다"고
/// 잘못 안내할 위험이 있으므로, 그런 상황은 호출자가 반드시 인지하고
/// 처리하도록 강제한다.
///
/// v2 변경사항 (서버 트래킹 연동):
/// 1. INFO 세그먼트의 7번째 필드(session_id)를 파싱해 [RouteResult.sessionId]에
///    채워 넣는다. 필드가 없으면(구버전 서버) 빈 문자열로 두고 에러를
///    던지지 않는다 — 트래킹은 부가 기능이라 하위호환이 더 중요하다.
/// 2. [trackPosition] 추가: /api/navigation/track에 세션ID+좌표를 보내고
///    누적 도보거리를 받아온다. NavigationController에서 fire-and-forget으로
///    호출되므로, 이 메서드 자체의 실패는 호출자가 catchError로 조용히
///    무시할 수 있게 예외를 명확히 던지기만 한다(별도 재시도 로직 없음).
class RouteService {
  final String baseUrl;

  RouteService({required this.baseUrl});

  Future<RouteResult> fetchRoute({
    required String destinationText,
    required Position currentPosition,
  }) async {
    final body = 'startAddress=${Uri.encodeComponent(destinationText)}'
        '&longitude=${currentPosition.longitude}'
        '&latitude=${currentPosition.latitude}'
        '&endAddress=${Uri.encodeComponent(destinationText)}';

    final response = await http
        .post(
      Uri.parse('$baseUrl/route'),
      headers: {'Content-Type': 'application/x-www-form-urlencoded'},
      body: body,
    )
        .timeout(const Duration(seconds: 15));

    if (response.statusCode != 200) {
      throw RouteParseException('서버 오류: HTTP ${response.statusCode}');
    }

    return _parseRouteData(response.body);
  }

  /// 세션ID + 현재 좌표를 서버로 보내 도로망 스냅 및 누적 도보거리를 받아온다.
  ///
  /// NavigationController._tick()에서 await 없이(fire-and-forget) 호출되는
  /// 것을 전제로 설계됐다 — 이 메서드가 느리거나 실패해도 로컬 안내 흐름
  /// (TTS/햅틱/화면 갱신)에는 절대 영향을 주지 않아야 한다. 그래서 내부에
  /// 재시도나 큐잉 로직을 두지 않고, 실패 시 예외를 그대로 던져 호출자가
  /// catchError로 조용히 흡수하도록 한다.
  Future<TrackResult> trackPosition({
    required String sessionId,
    required double lat,
    required double lon,
  }) async {
    // 서버(/api/navigation/track)는 request.get_json()으로만 body를 읽고,
    // 필드명도 lat/lon(위경도 약칭)을 기대한다. form-urlencoded나
    // latitude/longitude 키로 보내면 서버 쪽에서 session_id/lat/lon이
    // 전부 None으로 읽혀 즉시 400을 반환한다 — 반드시 JSON + lat/lon.
    final response = await http
        .post(
      Uri.parse('$baseUrl/api/navigation/track'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'session_id': sessionId,
        'lat': lat,
        'lon': lon,
        // timestamp는 선택 필드: 클라이언트에서 측정한 시각(초 단위)을
        // 보내면 서버가 네트워크 지연을 속도 필터 계산에서 배제할 수 있다.
        'timestamp': DateTime.now().millisecondsSinceEpoch / 1000,
      }),
    )
        .timeout(const Duration(seconds: 8));

    if (response.statusCode != 200) {
      throw RouteParseException('트래킹 서버 오류: HTTP ${response.statusCode}');
    }

    late final Map<String, dynamic> json;
    try {
      json = jsonDecode(response.body) as Map<String, dynamic>;
    } catch (_) {
      throw RouteParseException('트래킹 응답 JSON 파싱 실패', response.body);
    }

    final walked = (json['total_distance_walked'] as num?)?.toDouble();
    if (walked == null) {
      throw RouteParseException('트래킹 응답에 total_distance_walked 없음', response.body);
    }

    return TrackResult(totalDistanceWalked: walked);
  }

  RouteResult _parseRouteData(String data) {
    final segments = data.trim().split('|');
    final List<Waypoint> waypoints = [];

    int totalDistance = 0;
    int totalTime = 0;
    String destName = '';
    double destLat = 0;
    double destLon = 0;
    String sessionId = '';
    bool infoParsed = false;

    for (final seg in segments) {
      if (seg.isEmpty) continue; // 응답 끝의 trailing '|' 등으로 생기는 빈 조각은 무시

      if (seg.startsWith('INFO:')) {
        final infoParts = seg.split(':');
        if (infoParts.length < 3) {
          throw RouteParseException('INFO 세그먼트 필드 부족 (거리/시간 누락)', seg);
        }
        final dist = int.tryParse(infoParts[1]);
        final time = int.tryParse(infoParts[2]);
        if (dist == null || time == null) {
          throw RouteParseException('INFO 세그먼트 거리/시간 파싱 실패', seg);
        }
        totalDistance = dist;
        totalTime = time;

        if (infoParts.length >= 6) {
          destName = infoParts[3];
          final lat = double.tryParse(infoParts[4]);
          final lon = double.tryParse(infoParts[5]);
          if (lat == null || lon == null) {
            throw RouteParseException('INFO 세그먼트 목적지 좌표 파싱 실패', seg);
          }
          destLat = lat;
          destLon = lon;
        }

        // 7번째 필드(session_id): 서버 트래킹 연동용. 구버전 서버는 이
        // 필드를 안 보낼 수 있으므로, 없으면 에러 없이 빈 문자열로 둔다.
        // 이 경우 RouteResult.canTrack == false가 되어 트래킹 호출 자체가
        // 스킵된다(로컬 안내 로직에는 영향 없음).
        if (infoParts.length >= 7) {
          sessionId = infoParts[6];
        }

        infoParsed = true;
        continue;
      }

      final parts = seg.split(',');
      if (parts.length < 3) {
        throw RouteParseException('웨이포인트 필드 부족 (최소 3개: 위도,경도,회전타입 필요)', seg);
      }
      final lat = double.tryParse(parts[0].trim());
      final lon = double.tryParse(parts[1].trim());
      if (lat == null || lon == null) {
        throw RouteParseException('웨이포인트 좌표 파싱 실패', seg);
      }
      final turnType = parts[2].trim();
      final desc = parts.length > 3 ? parts[3].trim() : '';
      final name = parts.length > 4 ? parts[4].trim() : '';
      final facility = parts.length > 5? parts[5].trim() : '';
      waypoints.add(Waypoint(
          lat: lat,
          lon: lon,
          turnType: turnType,
          description: desc,
          name: name,
          facility: facility
      ));
    }

    if (!infoParsed) {
      throw RouteParseException('INFO 세그먼트가 응답에 없음 (총 거리/시간 정보 누락)');
    }

    return RouteResult(
      totalDistance: totalDistance,
      totalTime: totalTime,
      destinationName: destName,
      destinationLat: destLat,
      destinationLon: destLon,
      waypoints: waypoints,
      sessionId: sessionId,
    );
  }
}