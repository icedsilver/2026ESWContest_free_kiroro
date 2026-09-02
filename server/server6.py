from flask import Flask, request, jsonify
from flask_cors import CORS
import threading
import math
import json
import os
import time
import uuid
import logging
import requests as req

from tmap_api import get_pedestrian_route
from arduino_comm import send_vibration
from vision import (start_camera_detection, stop_camera_detection,
                    get_detection_status, update_signal, update_crosswalk)

logging.basicConfig(
    filename='app.log',
    level=logging.INFO,
    format='%(asctime)s %(message)s'
)

app = Flask(__name__)
CORS(app)

arduino = None
TMAP_APP_KEY = os.environ.get('TMAP_APP_KEY', 'XUPfI18eMKchmKLpsgDn56e4NvfQERS9rBT5roYg')

# ── 도착 판정 관련 ────────────────────────────────────────────────
# 앱(NavigationController)의 판정 조건:
#   INFO 세그먼트의 도착 좌표까지 거리 < 15 m 가 3 tick 연속 유지되어야 도착.
#   한 번이라도 벗어나면 카운터 리셋 → 체감 반경은 7~8 m 수준.
# 그래서 도착 좌표는 "사람이 실제로 설 수 있는 지점"이어야 하고,
# 그건 POI 좌표(건물/부지 내부)가 아니라 경로의 EP(보행 네트워크 위의 점)다.
ARRIVAL_PULLBACK_M = 10.0        # EP에서 경로를 따라 되돌아오는 거리
MIN_ROUTE_FOR_PULLBACK_M = 50.0  # 이보다 짧은 경로는 되돌리지 않음

# ── 실시간 위치 스냅 / 누적거리 트래킹 관련 ───────────────────────
SNAP_MAX_DIST_M = 30.0    # 이 이상 경로에서 벗어나면 "경로 이탈"로 간주 (원본 GPS 좌표 그대로 사용)
# 고정 거리(m) 임계값 대신 속도(m/s) 임계값을 쓴다.
# 이유: GPS 수신 주기가 1초든 5초든 상관없이 "사람이 낼 수 없는 속도"만 걸러내면 되므로
#       주기가 바뀌어도 임계값을 다시 튜닝할 필요가 없다.
MAX_WALK_SPEED_MPS = 3.0  # 약 시속 10.8km — 빠른 조깅까지 허용, 이보다 빠르면 GPS 튐으로 간주
SESSION_TTL_SEC = 2 * 60 * 60  # 세션 미사용 2시간 후 만료 (in-memory 버전 기준)

# ── 저장된 좌표(수동 오버라이드) ───────────────────────────────────
# TMap이 넓은 부지의 입구를 제대로 안 주는 곳은 현장에서 직접 좌표를 찍어
# 여기에 저장해두고, 같은 이름으로 검색되면 그 좌표를 목적지로 쓴다.
PLACES_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                           'saved_places.json')
_places_lock = threading.Lock()


def _norm(s):
    """이름 비교용 정규화 — 공백 제거 + 소문자."""
    return str(s or '').replace(' ', '').lower()


def load_places():
    try:
        with open(PLACES_FILE, encoding='utf-8') as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return {}


def store_places(places):
    """임시 파일에 쓰고 원자적으로 교체 — 저장 중 서버가 죽어도 파일이 안 깨진다."""
    tmp = PLACES_FILE + '.tmp'
    with open(tmp, 'w', encoding='utf-8') as f:
        json.dump(places, f, ensure_ascii=False, indent=2)
    os.replace(tmp, PLACES_FILE)


def find_saved_place(*names):
    """검색어나 POI 이름 중 하나라도 저장된 좌표와 일치하면 그 항목 반환."""
    places = load_places()
    index = {_norm(k): v for k, v in places.items()}
    for name in names:
        key = _norm(name)
        if key and key in index:
            return index[key]
    return None


def haversine(lat1, lon1, lat2, lon2):
    """두 WGS84 좌표 사이 거리(m)."""
    r = 6371000.0
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dphi = p2 - p1
    dlmb = math.radians(lon2 - lon1)
    a = math.sin(dphi / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dlmb / 2) ** 2
    return 2 * r * math.asin(math.sqrt(a))


FACILITY_TURN_TYPES = {
    125: 'OVERPASS', 126: 'UNDERPASS', 127: 'STAIRS',
    128: 'RAMP', 129: 'STAIRS_RAMP',
    211: 'CROSSWALK', 212: 'CROSSWALK_LEFT', 213: 'CROSSWALK_RIGHT',
    214: 'CROSSWALK_8', 215: 'CROSSWALK_10', 216: 'CROSSWALK_2',
    217: 'CROSSWALK_4', 218: 'ELEVATOR',
}

def tmap_turn_type_to_str(turn_type_code):
    code = int(turn_type_code)
    if code in (11, 16, 17, 18, 19, 182, 183, 184):
        return 'STRAIGHT'
    elif code in (12, 22):
        return 'LEFT'
    elif code in (13, 23):
        return 'RIGHT'
    elif code in (14,):
        return 'UTURN'
    else:
        # 200=출발지, 201=목적지. 원본은 200을 ARRIVED로 잘못 매핑해서
        # 출발하자마자 "목적지에 도착했습니다"가 나갔다.
        # 도착 판정은 destDist가 전담하므로 둘 다 웨이포인트에서 제외한다.
        return 'STRAIGHT'


def search_poi(keyword, center_lat=None, center_lon=None, count=5):
    """TMap POI 검색 — 가장 연관성 높은 결과 1건 반환."""
    params = {
        'version':       1,
        'searchKeyword': keyword,
        'count':         count,
        'appKey':        TMAP_APP_KEY,
    }
    if center_lat and center_lon:
        params['centerLat'] = center_lat
        params['centerLon'] = center_lon
    try:
        res  = req.get('https://apis.openapi.sk.com/tmap/pois', params=params, timeout=20)
        pois = res.json().get('searchPoiInfo', {}).get('pois', {}).get('poi', [])
        return pois[0] if pois else None
    except Exception:
        return None


def pick_destination_coord(poi):
    """경로 요청에 쓸 목적지 좌표.
    frontLat/frontLon = 시설물 입구, noorLat/noorLon = 중심점.
    중심점을 주면 EP가 부지 안쪽에 스냅되므로 입구를 우선한다."""
    for lat_key, lon_key, source in (('frontLat', 'frontLon', 'front'),
                                     ('noorLat',  'noorLon',  'center')):
        try:
            lat = float(poi.get(lat_key))
            lon = float(poi.get(lon_key))
        except (TypeError, ValueError):
            continue
        if lat and lon:
            return lat, lon, source
    return None, None, 'none'


def extract_path(features):
    """LineString 좌표를 순서대로 이어붙여 경로 폴리라인 생성."""
    path = []
    for f in features:
        if f['geometry']['type'] != 'LineString':
            continue
        for lon, lat in f['geometry']['coordinates']:
            if path and path[-1] == (lat, lon):
                continue
            path.append((lat, lon))
    return path


def pull_back_along_path(path, back_m=ARRIVAL_PULLBACK_M):
    """경로 끝점에서 경로를 따라 back_m 만큼 되돌아온 좌표.
    판정 원을 사용자가 걸어오는 길 위로 당겨 GPS 튐에 대비한다."""
    if len(path) < 2:
        return None
    remain = back_m
    for i in range(len(path) - 1, 0, -1):
        lat2, lon2 = path[i]
        lat1, lon1 = path[i - 1]
        seg = haversine(lat1, lon1, lat2, lon2)
        if seg <= 0:
            continue
        if seg >= remain:
            t = remain / seg
            return (lat2 + (lat1 - lat2) * t,
                    lon2 + (lon1 - lon2) * t)
        remain -= seg
    return path[0]


# ══ GPS 스냅 / 누적거리 트래킹 ═══════════════════════════════════════
#
# 목적: 실시간 GPS 좌표를 티맵이 준 경로 폴리라인 위로 스냅시켜서
#       ① 지그재그 노이즈로 인한 거리 과대산정을 줄이고
#       ② "경로 진행률"과 "경로 이탈 여부"를 함께 계산한다.
#
# in-memory 버전: 세션은 프로세스 메모리(dict)에 저장된다.
#   - 장점: 별도 인프라(Redis 등) 없이 바로 검증 가능
#   - 한계: 멀티 워커/멀티 인스턴스 환경에서는 세션 공유가 안 됨,
#           서버 재시작 시 세션 전부 소실. 운영 규모가 커지면 Redis로 교체 권장.
#
# ※ 배포 주의: 이 구조 때문에 gunicorn 등으로 워커를 2개 이상 띄우면
#   /route 를 처리한 워커와 /api/navigation/track 을 처리한 워커가 달라져
#   "세션 없음(404)"이 무작위로 발생한다. 워커는 반드시 1개.

class RouteSession:
    """경로 하나에 대한 실시간 위치 트래킹 (스냅 + 누적거리)."""

    def __init__(self, path, max_snap_dist_m=SNAP_MAX_DIST_M, max_speed_mps=MAX_WALK_SPEED_MPS):
        if len(path) < 2:
            raise ValueError('path는 최소 2개의 좌표가 필요합니다')
        self.path = path  # [(lat, lon), ...]
        self.max_snap_dist_m = max_snap_dist_m
        self.max_speed_mps = max_speed_mps
        self.last_point = None
        self.last_snap_time = None  # 속도 계산용 (직전 snap 호출 시각)
        self.total_distance = 0.0
        self.last_segment_idx = 0  # 진행률 단조 증가용 (뒤로 안 가게)
        self.created_at = time.time()
        self.last_used_at = time.time()

    def _project_on_segment(self, p, a, b):
        """p를 a-b 선분에 투영 (짧은 구간 평면 근사, 도보 경로 스케일에서는 오차 무시 가능)."""
        ref_lat = math.radians(p[0])
        R = 6371000.0

        def to_xy(pt):
            x = math.radians(pt[1]) * R * math.cos(ref_lat)
            y = math.radians(pt[0]) * R
            return x, y

        px, py = to_xy(p)
        ax, ay = to_xy(a)
        bx, by = to_xy(b)
        abx, aby = bx - ax, by - ay
        len_sq = abx * abx + aby * aby
        t = 0.0 if len_sq == 0 else ((px - ax) * abx + (py - ay) * aby) / len_sq
        t = max(0.0, min(1.0, t))
        sx, sy = ax + t * abx, ay + t * aby
        dist = math.hypot(px - sx, py - sy)

        lat = math.degrees(sy / R)
        lon = math.degrees(sx / (R * math.cos(ref_lat)))
        return (lat, lon), dist

    def snap(self, gps_lat, gps_lon, timestamp=None):
        """
        timestamp: 이 GPS 포인트가 측정된 시각(unix epoch, 초). 생략하면 서버 수신 시각을 쓴다.
        가능하면 클라이언트에서 측정한 시각을 넘기는 걸 권장한다 — 네트워크 지연이
        속도 계산에 섞여 정상 이동이 오탐지되는 걸 막아준다.
        """
        now = float(timestamp) if timestamp is not None else time.time()
        self.last_used_at = time.time()

        p = (gps_lat, gps_lon)
        best_point = None
        best_dist = float('inf')
        best_idx = -1

        for i in range(len(self.path) - 1):
            snapped, dist = self._project_on_segment(p, self.path[i], self.path[i + 1])
            if dist < best_dist:
                best_dist = dist
                best_point = snapped
                best_idx = i

        on_route = best_dist <= self.max_snap_dist_m
        point = best_point if on_route else p

        added = 0.0
        rejected_as_jump = False
        if self.last_point is not None:
            seg_dist = haversine(self.last_point[0], self.last_point[1], point[0], point[1])
            dt = max(now - self.last_snap_time, 1e-3) if self.last_snap_time is not None else None
            implied_speed = (seg_dist / dt) if dt else 0.0

            if dt is None or implied_speed <= self.max_speed_mps:
                self.total_distance += seg_dist
                added = seg_dist
            else:
                rejected_as_jump = True

        self.last_point = point
        self.last_snap_time = now
        # +1: best_idx는 "그 지점이 속한 선분의 시작 인덱스"라 마지막 선분(len-2)에 있어도
        # 실제로는 경로 끝(len-1)에 도달한 것이므로 +1을 해줘야 progress가 1.0까지 채워진다.
        self.last_segment_idx = max(self.last_segment_idx, best_idx + 1)

        return {
            'lat': point[0],
            'lon': point[1],
            'on_route': on_route,
            'distance_from_route': round(best_dist, 2),
            'progress': round(min(self.last_segment_idx / max(len(self.path) - 1, 1), 1.0), 4),
            'segment_added_m': round(added, 2),
            'rejected_as_jump': rejected_as_jump,
            'total_distance_walked': round(self.total_distance, 2),
        }

    def is_expired(self, ttl_sec=SESSION_TTL_SEC):
        return (time.time() - self.last_used_at) > ttl_sec


_route_sessions = {}
_sessions_lock = threading.Lock()


def _cleanup_expired_sessions_locked():
    """만료된 세션 정리. 요청 처리 중 가볍게 스윕 — 별도 스케줄러 없이
    in-memory 버전에서 메모리 누수 방지.

    ※ 이 함수는 호출자가 이미 _sessions_lock 을 잡고 있다고 가정한다.
      threading.Lock 은 재진입이 불가능하므로, 락을 잡은 채로 다시 잡으면
      그 자리에서 영구 정지(deadlock)한다. 이름 끝의 _locked 가 그 계약을 뜻한다.
      (이전에 이 함수 내부에서 with _sessions_lock: 을 다시 호출하는 버그가
      있었고, create_route_session()이 이미 락을 쥔 채로 이 함수를 부르는
      구조라 /route 요청이 세션 생성 단계에서 그대로 멈추는 문제가 있었다.)"""
    expired = [sid for sid, s in _route_sessions.items() if s.is_expired()]
    for sid in expired:
        del _route_sessions[sid]
    return len(expired)


def create_route_session(path):
    session_id = uuid.uuid4().hex
    session = RouteSession(path)
    with _sessions_lock:
        _cleanup_expired_sessions_locked()
        _route_sessions[session_id] = session
    return session_id


# ══ 좌표 저장 API ═══════════════════════════════════════════════════

@app.route('/api/place', methods=['POST'])
def place_save():
    """좌표 저장. JSON 또는 form 둘 다 받는다.
    body: {"name": "한양대 에리카", "lat": 37.2933, "lon": 126.8352, "memo": "정문"}"""
    data = request.get_json(silent=True) or request.form
    name = str(data.get('name', '')).strip()
    try:
        lat = float(data.get('lat'))
        lon = float(data.get('lon'))
    except (TypeError, ValueError):
        return jsonify({'success': False, 'error': 'lat/lon 형식 오류'}), 400

    if not name:
        return jsonify({'success': False, 'error': '이름 없음'}), 400
    if not (33 <= lat <= 39 and 124 <= lon <= 132):
        return jsonify({'success': False, 'error': '국내 좌표 범위 아님'}), 400

    entry = {'name': name, 'lat': lat, 'lon': lon,
             'memo': str(data.get('memo', '')).strip()}

    with _places_lock:
        places = load_places()
        places[name] = entry
        store_places(places)

    app.logger.info('[place] 저장 %s (%s, %s)', name, lat, lon)
    return jsonify({'success': True, 'place': entry, 'total': len(places)})


@app.route('/api/place/save', methods=['GET'])
def place_save_get():
    """브라우저 주소창에서 바로 저장할 수 있는 GET 버전.
    /api/place/save?name=한양대에리카&lat=37.2933&lon=126.8352"""
    return place_save()


@app.route('/api/place', methods=['GET'])
def place_list():
    places = load_places()
    return jsonify({'success': True, 'count': len(places),
                    'places': list(places.values())})


@app.route('/api/place', methods=['DELETE'])
def place_delete():
    name = request.args.get('name', '').strip()
    with _places_lock:
        places = load_places()
        target = next((k for k in places if _norm(k) == _norm(name)), None)
        if target is None:
            return jsonify({'success': False, 'error': '해당 이름 없음'}), 404
        removed = places.pop(target)
        store_places(places)
    return jsonify({'success': True, 'removed': removed})


# ══ 경로 API ════════════════════════════════════════════════════════

@app.route('/api/status', methods=['GET'])
def status():
    return jsonify({'success': True, 'message': '서버 정상 작동 중'})


@app.route('/route', methods=['POST'])
def route_legacy():
    data        = request.form
    end_address = data.get('endAddress', '').strip()
    lat         = float(data.get('latitude', 0))
    lon         = float(data.get('longitude', 0))

    poi = (search_poi(end_address, lat, lon)
           or search_poi(end_address.replace(' ', ''), lat, lon))

    # 저장해둔 좌표가 있으면 POI 좌표보다 우선 (검색어/POI 이름 둘 다 대조)
    saved = find_saved_place(end_address, poi.get('name') if poi else None)

    if saved:
        end_lat, end_lon = saved['lat'], saved['lon']
        coord_source = 'saved'
        poi_name = poi.get('name', end_address) if poi else saved['name']
    elif poi:
        end_lat, end_lon, coord_source = pick_destination_coord(poi)
        poi_name = poi.get('name', end_address)
        if end_lat is None:
            return '오류: 목적지 좌표를 찾을 수 없음', 404
    else:
        return '오류: 목적지를 찾을 수 없음', 404

    result = get_pedestrian_route(lat, lon, end_lat, end_lon)
    if not result['success']:
        return '오류: 경로 없음', 500

    total_distance = 0
    total_time     = 0
    features = result['route'].get('features', [])
    for f in features:
        if f['geometry']['type'] == 'Point':
            props = f['properties']
            if props.get('pointType') == 'SP':
                total_distance = props.get('totalDistance', 0)
                total_time     = props.get('totalTime', 0)
                break

    # ── 도착 좌표: EP(보행 네트워크 위의 점) → 경로 따라 10 m 되돌림 ──
    arrive_lat, arrive_lon = end_lat, end_lon
    arrive_source = coord_source
    for f in features:
        if (f['geometry']['type'] == 'Point'
                and f['properties'].get('pointType') == 'EP'):
            ep_lon, ep_lat = f['geometry']['coordinates']
            arrive_lat, arrive_lon = ep_lat, ep_lon
            arrive_source = 'ep'
            break

    path = extract_path(features)

    if arrive_source == 'ep' and total_distance >= MIN_ROUTE_FOR_PULLBACK_M:
        pulled = pull_back_along_path(path)
        if pulled is not None:
            if haversine(arrive_lat, arrive_lon, pulled[0], pulled[1]) <= ARRIVAL_PULLBACK_M * 3:
                arrive_lat, arrive_lon = pulled
                arrive_source = 'ep-pullback'

    # ── 실시간 스냅/누적거리 트래킹용 세션 생성 ──
    # 경로가 너무 짧으면(포인트 2개 미만) 세션 생성을 건너뛴다.
    session_id = None
    if len(path) >= 2:
        session_id = create_route_session(path)

    app.logger.info('[route] %s dest=(%s,%s)/%s arrive=(%s,%s)/%s dist=%s session=%s',
                    poi_name, end_lat, end_lon, coord_source,
                    arrive_lat, arrive_lon, arrive_source, total_distance, session_id)

    parts = []
    parts.append(f"INFO:{total_distance}:{total_time}:{poi_name}:{arrive_lat}:{arrive_lon}:{session_id or ''}")

    for wp in result['parsed']:
        turn_str = tmap_turn_type_to_str(wp['turnType'])
        facility_str = FACILITY_TURN_TYPES.get(int(wp['turnType']))

        if turn_str == 'STRAIGHT' and facility_str is None:
            continue

        description = wp['description'].replace(',', ' ')
        name        = wp.get('name', '').replace(',', ' ')
        parts.append(
            f"{wp['lat']},{wp['lon']},{turn_str},{description},{name},{facility_str or ''}"
        )

    return '|'.join(parts)


@app.route('/api/route', methods=['POST'])
def route():
    data      = request.get_json()
    start_lat = data.get('start_lat')
    start_lon = data.get('start_lon')
    end_lat   = data.get('end_lat')
    end_lon   = data.get('end_lon')

    if not all([start_lat, start_lon, end_lat, end_lon]):
        return jsonify({'success': False, 'error': '좌표 정보 누락'}), 400

    result = get_pedestrian_route(start_lat, start_lon, end_lat, end_lon)
    if not result['success']:
        return jsonify({'success': False, 'error': result['error']}), 500

    return jsonify(result['route'])


@app.route('/api/navigation/next', methods=['POST'])
def next_direction():
    data        = request.get_json()
    current_lat = data.get('lat')
    current_lon = data.get('lon')
    route_data  = data.get('route')

    if not route_data:
        return jsonify({'success': False, 'error': '경로 데이터 없음'}), 400

    features   = route_data.get('features', [])
    min_dist   = float('inf')
    next_point = None

    for feature in features:
        if feature['geometry']['type'] == 'Point':
            props          = feature['properties']
            pt_lon, pt_lat = feature['geometry']['coordinates']
            dist = haversine(current_lat, current_lon, pt_lat, pt_lon)
            if dist < min_dist:
                min_dist   = dist
                next_point = props

    return jsonify({'success': True, 'next_point': next_point})


@app.route('/api/navigation/track', methods=['POST'])
def navigation_track():
    """실시간 GPS 좌표를 현재 경로에 스냅하고 누적 도보 거리를 갱신한다.
    body: {"session_id": "...", "lat": 37.29, "lon": 126.83, "timestamp": 1700000000.123}
    timestamp는 선택 — 클라이언트에서 위치를 측정한 시각(unix epoch, 초)을 보내면
    네트워크 지연이 속도 필터 계산에 섞이는 걸 막을 수 있다. 생략 시 서버 수신 시각 사용.
    /route 응답의 INFO 세그먼트 마지막 필드로 session_id가 내려간다."""
    data = request.get_json(silent=True) or {}
    session_id = data.get('session_id')
    lat = data.get('lat')
    lon = data.get('lon')
    timestamp = data.get('timestamp')

    if not session_id or lat is None or lon is None:
        return jsonify({'success': False, 'error': 'session_id/lat/lon 필요'}), 400

    with _sessions_lock:
        session = _route_sessions.get(session_id)

    if session is None:
        return jsonify({'success': False, 'error': '세션 없음 또는 만료됨 - 경로 재요청 필요'}), 404

    result = session.snap(float(lat), float(lon), timestamp=timestamp)

    app.logger.info(
        '[track] session=%s lat=%.6f lon=%.6f on_route=%s dist_from_route=%.1fm '
        'jump_rejected=%s added=%.2fm total=%.2fm progress=%.1f%%',
        session_id, float(lat), float(lon),
        result['on_route'], result['distance_from_route'],
        result['rejected_as_jump'], result['segment_added_m'],
        result['total_distance_walked'], result['progress'] * 100,
    )

    return jsonify({'success': True, **result})


@app.route('/api/navigation/track/end', methods=['POST'])
def navigation_track_end():
    """도착/취소 시 세션 명시적 종료. 최종 누적거리를 반환하고 메모리에서 제거."""
    data = request.get_json(silent=True) or {}
    session_id = data.get('session_id')

    with _sessions_lock:
        session = _route_sessions.pop(session_id, None)

    if session is None:
        return jsonify({'success': False, 'error': '세션 없음'}), 404

    return jsonify({
        'success': True,
        'total_distance_walked': round(session.total_distance, 2),
        'duration_sec': round(time.time() - session.created_at, 1),
    })


@app.route('/api/camera/start', methods=['POST'])
def camera_start():
    thread = threading.Thread(
        target=start_camera_detection,
        args=(arduino,),
        daemon=True
    )
    thread.start()
    return jsonify({'success': True, 'message': '카메라 인식 시작'})


@app.route('/api/camera/stop', methods=['POST'])
def camera_stop():
    stop_camera_detection()
    return jsonify({'success': True, 'message': '카메라 인식 중지'})


@app.route('/api/camera/status', methods=['GET'])
def camera_status():
    return jsonify({'success': True, 'status': get_detection_status()})


@app.route('/api/vibrate', methods=['POST'])
def vibrate():
    data    = request.get_json()
    pattern = data.get('pattern', 'short')
    send_vibration(arduino, pattern)
    return jsonify({'success': True, 'pattern': pattern})


@app.route('/api/signal', methods=['POST'])
def signal():
    data   = request.get_json()
    status = data.get('status', 'unknown')  # green / red / unknown
    update_signal(status)
    return jsonify({'success': True, 'signal': status})


@app.route('/api/crosswalk', methods=['POST'])
def crosswalk():
    data     = request.get_json()
    detected = data.get('detected', False)
    update_crosswalk(detected)
    return jsonify({'success': True, 'crosswalk': detected})


@app.route('/api/geocode', methods=['GET'])
def geocode():
    address = request.args.get('address', '')
    if not address:
        return jsonify({'success': False, 'error': '주소 없음'}), 400

    lat = request.args.get('lat', type=float)
    lon = request.args.get('lon', type=float)

    saved = find_saved_place(address)
    if saved:
        return jsonify({'success': True, 'lat': saved['lat'], 'lon': saved['lon'],
                        'name': saved['name'], 'coord_source': 'saved'})

    poi = search_poi(address, lat, lon, count=1)
    if poi is None:
        return jsonify({'success': False, 'error': '검색 결과 없음'}), 404

    d_lat, d_lon, source = pick_destination_coord(poi)
    if d_lat is None:
        return jsonify({'success': False, 'error': '좌표 없음'}), 404

    return jsonify({
        'success':      True,
        'lat':          d_lat,
        'lon':          d_lon,
        'name':         poi.get('name', address),
        'coord_source': source,
    })


if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000, debug=False)
