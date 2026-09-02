// --- 핀 배치 ---
const int RED1_PIN = 4, GREEN1_PIN = 6,  BLUE1_PIN = 9;
const int RED2_PIN = 7, GREEN2_PIN = 10, BLUE2_PIN = 8;
const int VIB_L = 5, VIB_R = 3;     // 왼쪽 / 오른쪽 진동 모터

const uint8_t KICK = 255;
const uint8_t HOLD = 175;
const uint8_t HOLD_HI = 255;
const uint16_t TIMEOUT = 2500;

// 좌우 세기를 따로 담는다. 0이면 그쪽 모터는 정지.
struct Step { uint8_t l, r; uint16_t ms; };

// 볼라드 왼쪽: 왼쪽 모터만 짧게 2번
const Step P_BOLL_L[] = {{KICK,0,60},{HOLD_HI,0,90},{0,0,170},
                         {KICK,0,60},{HOLD_HI,0,90},{0,0,0}};
// 볼라드 오른쪽
const Step P_BOLL_R[] = {{0,KICK,60},{0,HOLD_HI,90},{0,0,170},
                         {0,KICK,60},{0,HOLD_HI,90},{0,0,0}};
// 볼라드 정면(양쪽)
const Step P_BOLL_B[] = {{KICK,KICK,60},{HOLD_HI,HOLD_HI,90},{0,0,170},
                         {KICK,KICK,60},{HOLD_HI,HOLD_HI,90},{0,0,0}};
// 빨간불: 양쪽 빠르게 3번 x 2
const Step P_RED[] = {{KICK,KICK,45},{HOLD,HOLD,45},{0,0,150},
                      {KICK,KICK,45},{HOLD,HOLD,45},{0,0,150},
                      {KICK,KICK,45},{HOLD,HOLD,45},{0,0,450},
                      {KICK,KICK,45},{HOLD,HOLD,45},{0,0,150},
                      {KICK,KICK,45},{HOLD,HOLD,45},{0,0,150},
                      {KICK,KICK,45},{HOLD,HOLD,45},{0,0,0}};
// 초록불: 양쪽 길게 1번
const Step P_GREEN[] = {{KICK,KICK,80},{HOLD_HI,HOLD_HI,800},{0,0,0}};

struct Pattern { const Step *s; uint8_t len, prio; uint16_t cool; };
const Pattern PATS[] = {
  {P_BOLL_L,  6, 2, 2500},   // 0 볼라드 좌
  {P_BOLL_R,  6, 2, 2500},   // 1 볼라드 우
  {P_BOLL_B,  6, 2, 2500},   // 2 볼라드 정면
  {P_RED,    18, 3, 3000},   // 3 빨간불
  {P_GREEN,   3, 1, 4000},   // 4 초록불
};

int8_t active = -1;
uint8_t stepIdx = 0;
uint32_t stepUntil = 0, lastFire[5] = {0,0,0,0,0}, lastRx = 0;
String cmd = "";

void motors(uint8_t l, uint8_t r) { analogWrite(VIB_L, l); analogWrite(VIB_R, r); }

void setLeds(bool r, bool g, bool b) {
  digitalWrite(RED1_PIN, r);   digitalWrite(RED2_PIN, r);
  digitalWrite(GREEN1_PIN, g); digitalWrite(GREEN2_PIN, g);
  digitalWrite(BLUE1_PIN, b);  digitalWrite(BLUE2_PIN, b);
}

void startPattern(uint8_t p) {
  uint32_t now = millis();
  if (active >= 0 && PATS[p].prio <= PATS[active].prio) return;  // 선점만 허용
  if (now - lastFire[p] < PATS[p].cool) return;                  // 쿨다운
  active = p; stepIdx = 0; stepUntil = now; lastFire[p] = now;
}

// delay()를 쓰지 않는다. 진동 재생 중에도 다음 명령을 받아야 한다.
void servicePattern() {
  if (active < 0) return;
  uint32_t now = millis();
  if (now < stepUntil) return;

  const Pattern &P = PATS[active];
  if (stepIdx >= P.len || P.s[stepIdx].ms == 0) {
    active = -1; motors(0, 0); return;
  }
  motors(P.s[stepIdx].l, P.s[stepIdx].r);
  stepUntil = now + P.s[stepIdx].ms;
  stepIdx++;
}

void setup() {
  Serial.begin(9600);
  int pins[] = {RED1_PIN,GREEN1_PIN,BLUE1_PIN,RED2_PIN,GREEN2_PIN,BLUE2_PIN,
                VIB_L,VIB_R};
  for (int p : pins) pinMode(p, OUTPUT);
  motors(0, 0);
  setLeds(false, false, false);
  lastRx = millis();
}

void loop() {
  while (Serial.available()) {
    char c = Serial.read();
    if (c == '\n' || c == '\r') {
      cmd.trim();
      if (cmd.length()) {
        lastRx = millis();
        if      (cmd == "4") { setLeds(false,false,true);  startPattern(0); }  // 볼라드 좌
        else if (cmd == "5") { setLeds(false,false,true);  startPattern(1); }  // 볼라드 우
        else if (cmd == "1") { setLeds(false,false,true);  startPattern(2); }  // 볼라드 정면
        else if (cmd == "2") { setLeds(true, false,false); startPattern(3); }  // 빨간불
        else if (cmd == "3") { setLeds(false,true, false); startPattern(4); }  // 초록불
        else if (cmd == "0") { setLeds(false,false,false); }
      }
      cmd = "";
    } else if (cmd.length() < 8) {
      cmd += c;
    }
  }

  // 워치독: 링크가 죽으면 무조건 정지
  // 사용자가 화면을 안 보므로, 통신이 끊긴 채 진동이 남으면 알아챌 방법이 없다.
  if (millis() - lastRx > TIMEOUT) {
    active = -1;
    motors(0, 0);
    bool blink = (millis() / 250) % 2;
    setLeds(blink, false, false);
  }

  servicePattern();
}