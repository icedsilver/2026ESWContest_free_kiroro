# 픽시캠(신호등) + 허스키렌즈(횡단보도) 상태 관리
# PC 테스트 모드 → 실제 카메라 없이 상태만 관리

_running = False
_status = {
    'signal':    'unknown',  # 픽시캠: 신호등 상태
    'crosswalk': False,      # 허스키렌즈: 횡단보도 감지
    'cam1_ok':   False,      # 픽시캠 연결 상태
    'cam2_ok':   False,      # 허스키렌즈 연결 상태
}


def get_detection_status():
    return _status


def stop_camera_detection():
    global _running
    _running = False
    print("[Vision] 카메라 인식 중지")


def start_camera_detection(arduino):
    """
    PC 테스트 모드
    실제 픽시캠/허스키렌즈 없으므로
    상태만 초기화하고 종료
    라즈베리파이 연결 후 실제 코드로 교체 예정
    """
    global _running, _status
    _running = True

    print("[Vision] PC 테스트 모드 - 실제 카메라 없음")
    print("[Vision] 라즈베리파이 연결 후 실제 인식 코드로 교체 예정")

    _status['cam1_ok'] = False  # 픽시캠 미연결
    _status['cam2_ok'] = False  # 허스키렌즈 미연결


def update_signal(signal):
    """픽시캠 신호등 상태 업데이트"""
    _status['signal'] = signal
    print(f"[Vision] 신호등: {signal}")


def update_crosswalk(detected):
    """허스키렌즈 횡단보도 상태 업데이트"""
    _status['crosswalk'] = detected
    print(f"[Vision] 횡단보도: {detected}")