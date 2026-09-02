import time
from collections import deque

import cv2
import numpy as np
import serial
from flask import Flask, Response
from ultralytics import YOLO

app = Flask(__name__)

# ==========================================
# 1. 시리얼
# ==========================================
SERIAL_PORT = "/dev/ttyUSB0"   # 안 되면 /dev/ttyACM0
BAUD_RATE = 9600

ser = None
try:
    ser = serial.Serial(SERIAL_PORT, BAUD_RATE, timeout=1)
    time.sleep(2)              # 아두이노 리셋 대기 (없으면 초기 명령 유실)
    ser.reset_input_buffer()
    print(f"시리얼 연결 성공: {SERIAL_PORT}")
except Exception as e:
    print(f"시리얼 연결 실패: {e}")

# ==========================================
# 2. 모델
# ==========================================
print("YOLO 로딩 (1/2) 볼라드 커스텀...")
model_bollard = YOLO("best.pt")
print("YOLO 로딩 (2/2) COCO...")
model_coco = YOLO("yolo11n.pt")

# ==========================================
# 3. 카메라
# ==========================================
cap = None
for cam_id in [0, 1, 19, 20]:
    t = cv2.VideoCapture(cam_id, cv2.CAP_V4L2)
    if t.isOpened() and t.read()[0]:
        cap = t
        print(f"카메라 /dev/video{cam_id} 연결")
        break
    t.release()

if cap is None:
    print("Error: 카메라를 찾을 수 없습니다.")
    exit()

cap.set(cv2.CAP_PROP_FRAME_WIDTH, 640)
cap.set(cv2.CAP_PROP_FRAME_HEIGHT, 480)

# ==========================================
# 4. 신호등 색 판정
#    램프는 하우징보다 훨씬 밝은 '작은' 영역이다.
#    절대 밝기가 아니라 대비로 찾아야 원거리/야간/과노출에서 살아남는다.
# ==========================================
def get_traffic_light_color(roi):
    if roi is None or roi.size == 0 or roi.shape[0] * roi.shape[1] < 120:
        return "UNKNOWN"

    h0, w0 = roi.shape[:2]
    if h0 * w0 < 3000:                      # 원거리 박스는 확대해야 통계가 선다
        k = int(np.ceil(np.sqrt(3000.0 / (h0 * w0))))
        roi = cv2.resize(roi, (w0 * k, h0 * k))
    roi = cv2.GaussianBlur(roi, (3, 3), 0)

    H, W = roi.shape[:2]
    h, s, v = cv2.split(cv2.cvtColor(roi, cv2.COLOR_BGR2HSV))

    v_max, v_med = float(np.percentile(v, 99)), float(np.median(v))
    if v_max - v_med < 30:
        return "UNKNOWN"                    # 대비 없음 = 단색 면(간판·벽)

    lit = v >= max(60.0, v_med + 0.45 * (v_max - v_med), 0.60 * v_max)
    n = int(np.count_nonzero(lit))
    ratio = n / float(H * W)
    if n < 12 or ratio < 0.006 or ratio > 0.50:
        return "UNKNOWN"

    cy = float(np.nonzero(lit)[0].mean()) / H      # 0=위, 1=아래
    vertical = H >= W * 1.15

    chroma = lit & (s >= 40)                # 과노출 중심부는 채도가 없어 제외
    n_ch = int(np.count_nonzero(chroma))
    if n_ch < max(8, int(0.12 * n)):
        # 색 판독 실패 → 위험쪽(RED)만 위치로 추정 허용
        return "RED" if (vertical and cy < 0.45) else "UNKNOWN"

    hue = h[chroma]
    cnt = {"RED":   int(np.count_nonzero((hue < 12) | (hue > 168))),
           "GREEN": int(np.count_nonzero((hue >= 42) & (hue <= 100)))}
    st = max(cnt, key=cnt.get)
    if cnt[st] / float(n_ch) < 0.45:
        return "UNKNOWN"

    if vertical:                            # 위=적 아래=녹 교차검증
        if (st == "RED" and cy > 0.62) or (st == "GREEN" and cy < 0.38):
            return "UNKNOWN"
    return st

# ==========================================
# 5. 볼라드 좌우 판정
#    화면 중앙 밴드는 어느 쪽으로 피해야 할지 모호하므로,
#    박스 중심이 중앙에 걸치면 '더 넓은 쪽'이 아니라 박스가 치우친 쪽으로 본다.
# ==========================================
CENTER_LO, CENTER_HI = 0.45, 0.55   # 이 안이면 정면 → 가까운 쪽 기준으로 판단

def bollard_side(x1, x2, frame_w):
    cx = (x1 + x2) / 2.0 / frame_w
    if cx < 0.5:
        return "left"
    return "right"

# ==========================================
# 6. 3프레임 중 2회 확정 필터
#    상태별로 따로 세야 한다. 최종 상태값을 필터링하면
#    볼라드와 빨간불이 번갈아 잡힐 때 둘 다 억제된다.
# ==========================================
HIST_LEN, HIST_HITS = 3, 2
hist = {"boll_l": deque(maxlen=HIST_LEN),
        "boll_r": deque(maxlen=HIST_LEN),
        "red":    deque(maxlen=HIST_LEN),
        "green":  deque(maxlen=HIST_LEN)}

def confirmed(key, detected):
    hist[key].append(bool(detected))
    return sum(hist[key]) >= HIST_HITS

last_state = "0"
last_tx = 0.0
HEARTBEAT = 1.0        # 상태가 안 변해도 이 주기로 재전송 (아두이노 워치독용)


def generate_frames():
    global last_state, last_tx

    while True:
        success, frame = cap.read()
        if not success:
            break

        H, W = frame.shape[:2]
        original = frame.copy()
        annotated = frame.copy()

        # --- 볼라드 (좌우 분리) ---
        res_b = model_bollard(frame, imgsz=320, verbose=False)
        raw_l = raw_r = False
        biggest = {"left": 0, "right": 0}    # 박스 높이 = 거리 대용

        for box in res_b[0].boxes:
            x1, y1, x2, y2 = map(int, box.xyxy[0])
            side = bollard_side(x1, x2, W)
            h = y2 - y1
            biggest[side] = max(biggest[side], h)
            if side == "left":
                raw_l = True
                bc = (255, 200, 0)
            else:
                raw_r = True
                bc = (0, 200, 255)
            cv2.rectangle(annotated, (x1, y1), (x2, y2), bc, 2)
            cv2.putText(annotated, f"Bollard {side[0].upper()}", (x1, y1 - 10),
                        cv2.FONT_HERSHEY_SIMPLEX, 0.6, bc, 2)

        # --- 신호등 ---
        res_t = model_coco(frame, imgsz=320, classes=[9], verbose=False)
        raw_red = raw_green = False
        for box in res_t[0].boxes:
            x1, y1, x2, y2 = map(int, box.xyxy[0])
            if y2 <= y1 or x2 <= x1:
                continue
            color = get_traffic_light_color(original[y1:y2, x1:x2])
            if color == "RED":
                raw_red = True
                bc, label = (0, 0, 255), "Red Light"
            elif color == "GREEN":
                raw_green = True
                bc, label = (0, 255, 0), "Green Light"
            else:
                bc, label = (255, 255, 255), "Traffic Light"
            cv2.rectangle(annotated, (x1, y1), (x2, y2), bc, 2)
            cv2.putText(annotated, label, (x1, y1 - 10),
                        cv2.FONT_HERSHEY_SIMPLEX, 0.6, bc, 2)

        # --- 확정 ---
        ok_l     = confirmed("boll_l", raw_l)
        ok_r     = confirmed("boll_r", raw_r)
        ok_red   = confirmed("red",    raw_red)
        ok_green = confirmed("green",  raw_green)

        # --- 우선순위: 빨간불 > 볼라드 > 초록불 ---
        # 양쪽 볼라드가 동시에 잡히면 더 가까운 쪽(박스가 큰 쪽)만 알린다.
        if ok_red:
            state = "2"
        elif ok_l and ok_r:
            state = "4" if biggest["left"] >= biggest["right"] else "5"
        elif ok_l:
            state = "4"
        elif ok_r:
            state = "5"
        elif ok_green:
            state = "3"
        else:
            state = "0"

        # --- 전송: 변화 시 즉시, 아니면 1초마다 (워치독 유지) ---
        now = time.time()
        if ser and ser.is_open and (state != last_state or now - last_tx >= HEARTBEAT):
            ser.write(f"{state}\n".encode())
            ser.flush()
            if state != last_state:
                print(f"[전송] {last_state} -> {state}")
            last_state, last_tx = state, now

        # --- 디버그 오버레이 ---
        cv2.line(annotated, (W // 2, 0), (W // 2, H), (80, 80, 80), 1)
        names = {"0": "SAFE", "2": "RED", "3": "GREEN",
                 "4": "BOLLARD LEFT", "5": "BOLLARD RIGHT"}
        cv2.putText(annotated, f"{state} {names.get(state, '')}", (10, 30),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.8, (255, 255, 255), 2)

        ok, buf = cv2.imencode(".jpg", annotated)
        yield (b"--frame\r\nContent-Type: image/jpeg\r\n\r\n"
               + buf.tobytes() + b"\r\n")


@app.route("/")
def index():
    return ("<html><head><meta charset='utf-8'><title>kiroro</title></head>"
            "<body style='text-align:center;background:#111;color:#fff'>"
            "<h1>볼라드 &amp; 신호등 감지</h1>"
            "<img src='/video_feed' style='width:80%;max-width:640px'/>"
            "</body></html>")


@app.route("/video_feed")
def video_feed():
    return Response(generate_frames(),
                    mimetype="multipart/x-mixed-replace; boundary=frame")


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000, threaded=True)