# ULP-AI : 평균 10 µW 이하 RISC-V 기반 간헐동작 AI 프로세서 (Verilog 시안)

## 1. 가능한가? — 결론: **가능하다** (단, 지배항은 "연산"이 아니라 "누설")

평균전력 = P_sleep + (E_wake × 웨이크 빈도)

| 항목 | 가정값 (22–40 nm ULP/ULL, 0.6–0.9 V) | 비고 |
|---|---|---|
| AON 도메인 + 32 kHz 발진기 | 0.2–0.5 µW | RTC급 회로 |
| 리텐션 SRAM 8 KB + 리텐션 플롭 | 0.5–2 µW | **가장 큰 항목.** 메모리 크기에 비례 |
| 메인 도메인 ON 누설 | 5–20 µW | 깨어 있을 때만 |
| 코어 동적에너지 | ~5–10 pJ/cycle | RV32E 멀티사이클 |
| 가속기(INT8×4 MAC + SRAM 읽기) | ~10–15 pJ/cycle | SRAM 접근이 대부분 |

* **구동 중**: 1 MHz에서 (8+12) pJ × 1 MHz ≈ 20 µW + ON누설 10 µW ≈ **30 µW ≪ 1 mW**.
  10 MHz로 올려도 ~0.2–0.3 mW 수준 → "구동 시 1 mW 이하" 조건 여유 충분.
* **간헐 동작(1초에 1회 추론)**: 이 시안의 16-8-4 MLP 한 번에 동적 ~5.5 nJ →
  평균 ≈ 0.3 + 1.0 + 0.0055 + ON누설분 ≈ **1–2 µW** (테스트벤치가 직접 계산해 출력).
* 더 큰 모델(예: KWS용 DS-CNN 수십 k 파라미터, 수 M MAC)도 MAC당 ~1–3 pJ이면
  추론당 수–수십 µJ → 1 Hz면 수 µW 추가. 즉 **10 µW 예산의 핵심은 (1) 리텐션 메모리 크기,
  (2) 웨이크 빈도 × 추론당 에너지, (3) 공정 선택(ULL/FD-SOI 바디바이어스)** 이다.

> 수치는 문헌 범위의 근사치이며, 실제 값은 공정·라이브러리로 합성/전력분석(PrimeTime PX, Voltus 등) 후 확정해야 한다.

## 2. 아키텍처

```
          ┌──────────── 메인 도메인 (파워게이팅, 1–10 MHz RC 발진기) ────────────┐
          │  ┌────────────┐ ICG  ┌──────────────┐ ICG                            │
          │  │ RV32E core │◀────│  bus/arbiter │────▶┌──────────────────┐        │
          │  │ 멀티사이클  │────▶│ (가속기 우선) │◀────│ NN 가속기 INT8×4 │        │
          │  └────────────┘      └──────┬───────┘     │ FC + bias + ReLU │        │
          │                             ▼             │ + 재양자화/포화   │        │
          │                     ┌───────────────┐     └──────────────────┘        │
          │                     │ 8 KB SRAM     │  (코드+가중치, 리텐션 모드)       │
          │                     └───────────────┘                                 │
          └───────────────▲─────────────── iso / pwr_on / ret / hfosc_en ─────────┘
                          │ 토글 핸드셰이크 (2FF CDC)
          ┌───────────────┴────── AON 도메인 (32.768 kHz, 상시) ───────────────────┐
          │  주기 웨이크업 타이머  +  전원 시퀀서 RUN→ISO→OFF→ON→UNISO→WAITACK     │
          └──────────────────────────────────────────────────────────────────────┘
```

저전력 기법 정리
1. **RV32E + 멀티사이클**: 레지스터 16개, 파이프라인/캐시/분기예측 없음 → 면적·누설·토글 최소.
   (더 줄이려면 비트시리얼 SERV 계열로 교체 가능: 면적↓, 사이클↑)
2. **AI 연산은 가속기로**: 32 bit 워드 하나에 INT8 4개 → 사이클당 4 MAC. 코어는 레이어 설정 후 `WFI`.
3. **3단계 전력 상태**
   * RUN: 필요한 블록만 클럭 (ICG: 코어는 WFI 시, 가속기는 유휴 시 클럭 정지)
   * LIGHT SLEEP: 코어 클럭만 정지, 가속기 동작 중 (`DONE` 인터럽트로 기상)
   * DEEP SLEEP: 메인 도메인 파워게이팅 + HF 발진기 OFF, SRAM/상태 리텐션, AON만 동작
4. **피연산자 격리**: 가속기 유휴 시 곱셈기 입력을 0으로 고정 → 글리치 전력 제거.
5. **SRAM 은 요청이 있을 때만 활성** (출력 유지 → 토글 없음).
6. 딥슬립 진입 조건 `core WFI & ~accel_busy & ~accel_irq` 를 메인 도메인에서 한 신호로 만들어 동기화 → 연산 중 전원 차단 방지.

## 3. 파일

| 파일 | 내용 |
|---|---|
| `rtl/rv32e_core.v` | RV32E 멀티사이클 코어 (RV32I 정수명령 전체, WFI, EBREAK) |
| `rtl/nn_accel.v` | INT8 FC 레이어 가속기 (bias, ReLU, shift 재양자화, int8 포화) |
| `rtl/aon_ctrl.v` | 32 kHz 웨이크업 타이머 + 파워게이팅 시퀀서 |
| `rtl/ulp_soc.v` | SoC 톱: 버스 중재, 메모리맵, 클럭게이팅, CDC |
| `rtl/icg.v`, `rtl/sram.v` | 행동 모델 (실제 칩에선 표준셀 ICG / 리텐션 SRAM 매크로로 교체) |
| `sw/gen_firmware.py` | 미니 어셈블러 + 2층 MLP(16-8-4) 가중치 생성 + 파이썬 골든 모델 |
| `tb/tb_ulp_soc.v` | 5회 웨이크 → 추론 → 결과를 골든과 비교, 평균전력 추정 출력 |

메모리맵: `0x0000_0000` SRAM 8 KB · `0x1000_0000` 가속기 · `0x2000_0000` AON(PERIOD, DEEP_EN, STAT, RESULT)

## 4. 실행

```bash
sudo apt-get install -y iverilog
```

```bash
./run_sim.sh
```

결과(검증됨):
```
wake 0: class 2 OK / wake 1: class 3 OK / ... / wake 4: class 1 OK
추론 1회당 동적에너지 ~5.5 nJ
평균전력(1 s 주기 환산) ~1.31 uW
PASS
```
(시뮬에선 시간을 줄이려고 웨이크 주기를 1 ms로 둠. 실사용은 `PERIOD=32768` → 1 s)

## 5. 이 시안의 한계 / 다음 단계

* 파워게이팅·리텐션·격리는 **제어신호만** 생성. 실제 동작은 UPF(IEEE 1801)로 전원 도메인·리텐션 플롭·격리셀을 정의해 구현한다. RTL 시뮬에서는 "HF 클럭 정지"로 모델링.
* 코어는 인터럽트 트랩/CSR 없음(WFI 재개 방식). 필요하면 Ibex(micro 구성)·SERV·PicoRV32 등 검증된 코어로 교체.
* 가속기는 FC 전용. Conv/DW-Conv는 im2col을 SW로 하거나 라인버퍼를 추가. 입력벡터를 매번 SRAM에서 다시 읽으므로, 작은 로컬 버퍼를 두면 SRAM 에너지가 ~1/3 감소.
* 더 낮추기: 바이너리/터너리 가중치(XNOR-popcount), 근임계(0.4–0.5 V) 동작, FD-SOI 역바디바이어스로 슬립 누설 감소, 이벤트 기반 아날로그 프런트엔드로 웨이크 빈도 자체를 줄이기.

## 6. 참고 문헌 / 오픈소스 (원문 확인 권장)

논문
* D. Rossi et al., "Vega: A Ten-Core SoC for IoT Endnodes With DNN Acceleration and Cognitive Wake-Up From MRAM-Based State-Retentive Sleep Mode," IEEE JSSC 2022 — µW급 cognitive sleep + 웨이크업 구조.
* W. Shan et al., "A 510-nW Wake-Up Keyword-Spotting Chip Using Serial-FFT-Based MFCC and Binarized Depthwise Separable CNN in 28-nm CMOS," IEEE JSSC 2021 — sub-µW 상시 AI.
* J. S. P. Giraldo, M. Verhelst, "Laika: A 5 µW Programmable LSTM Accelerator for Always-on Keyword Spotting in 65 nm CMOS," ESSCIRC 2018.
* A. Pullini et al., "Mr.Wolf: An Energy-Precision Scalable Parallel Ultra Low Power SoC for IoT Edge Processing," IEEE JSSC 2019.
* B. Moons, M. Verhelst, "An Energy-Efficient Precision-Scalable ConvNet Processor in 40-nm CMOS (Envision)," IEEE JSSC 2017.

GitHub
* `pulp-platform/pulpissimo` — RISC-V MCU, 전원/클럭 관리 구조 참고
* `pulp-platform/ne16` — PULP 계열 신경망 가속기
* `lowRISC/ibex` — RV32IMC/EMC 소형 코어 (micro 구성)
* `olofk/serv` — 비트시리얼 최소면적 RISC-V
* `YosysHQ/picorv32` — 소형 RISC-V
* `tensorflow/tflite-micro`, `mit-han-lab/tinyengine` — MCU용 INT8 추론 SW
