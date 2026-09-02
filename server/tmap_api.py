import requests

TMAP_API_KEY = "XUPfI18eMKchmKLpsgDn56e4NvfQERS9rBT5roYg"
BASE_URL = "https://apis.openapi.sk.com/tmap"


def get_pedestrian_route(start_lat, start_lon, end_lat, end_lon):
    url = f"{BASE_URL}/routes/pedestrian?version=1"

    headers = {
        "appKey": TMAP_API_KEY,
        "Content-Type": "application/json"
    }

    body = {
        "startX":       str(start_lon),
        "startY":       str(start_lat),
        "endX":         str(end_lon),
        "endY":         str(end_lat),
        "reqCoordType": "WGS84GEO",
        "resCoordType": "WGS84GEO",
        "startName":    "출발지",
        "endName":      "목적지",
        # 0=추천, 4=추천+대로우선, 10=최단거리, 30=최단거리+계단제외
        # 시각장애인 보행 특성상 계단을 피하면서 가장 짧은 경로 사용
        "searchOption": "30",
        "sort":         "index"
    }

    try:
        response = requests.post(url, headers=headers, json=body, timeout=10)
        response.raise_for_status()
        data   = response.json()
        parsed = parse_route(data)
        return {'success': True, 'route': data, 'parsed': parsed}

    except requests.exceptions.RequestException as e:
        return {'success': False, 'error': str(e)}


def parse_route(route_data):
    waypoints = []
    features  = route_data.get('features', [])

    for feature in features:
        geometry   = feature.get('geometry', {})
        properties = feature.get('properties', {})

        if geometry.get('type') == 'Point':
            coords = geometry.get('coordinates', [])
            waypoints.append({
                'lon':         coords[0],
                'lat':         coords[1],
                'description': properties.get('description', ''),
                'turnType':    properties.get('turnType', 0),
                'distance':    properties.get('distance', 0),
                'duration':    properties.get('time', 0),
            })

    return waypoints