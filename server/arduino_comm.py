# 아두이노 연결 및 진동 명령 전송

def init_arduino(port='/dev/ttyUSB0', baud=9600):
    """
    아두이노 초기화
    PC에서 테스트할 땐 연결 없이 None 반환
    라즈베리파이에서 실제 연결할 때 사용
    """
    try:
        import serial
        import time
        ser = serial.Serial(port, baud, timeout=1)
        time.sleep(2)
        print(f"[Arduino] 연결 성공: {port}")
        return ser
    except Exception as e:
        print(f"[Arduino] 연결 없음 (PC 테스트 모드): {e}")
        return None


def send_vibration(arduino, pattern):
    """
    진동 패턴 전송
    arduino=None 이면 출력만 하고 넘어감 (PC 테스트용)
    """
    # 패턴 → 아두이노 명령 코드
    commands = {
        'short':    'V1',  # 짧게 1번
        'long':     'V2',  # 길게 1번
        'double':   'V3',  # 짧게 2번
        'go':       'V4',  # 초록불 (빠르게 3번)
        'stop':     'V5',  # 빨간불 (길게 2번)
        'left':     'V6',  # 좌회전
        'right':    'V7',  # 우회전
        'straight': 'V8',  # 직진
        'uturn':    'V9',  # 유턴
    }

    cmd = commands.get(pattern, 'V1')

    if arduino is None:
        # PC 테스트 모드 → 출력만
        print(f"[Arduino] 진동 명령: {pattern} ({cmd})")
        return

    try:
        arduino.write(f"{cmd}\n".encode())
        arduino.flush()
        print(f"[Arduino] 전송 완료: {cmd}")
    except Exception as e:
        print(f"[Arduino] 전송 오류: {e}")