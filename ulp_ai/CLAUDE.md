# CLAUDE.md — ULP-AI SoC: Synopsys 흐름으로 검증하고 동작 조건 확립하기

이 파일은 RHEL 9 서버의 Claude Code 가 `ulp_ai/` 에서 작업할 때 따르는 지시서다.
목표: RTL → 합성(UPF 포함) → 게이트 시뮬 → **PrimeTime 전력/타이밍 분석**을 실제로 돌려,
"평균 ≤ 10 µW, 구동 중 ≤ 1 mW"가 **어떤 조건(공정 코너·전압·주파수·웨이크 빈도·메모리 크기)에서 성립하는지** 숫자로 확립한다.

## 0. 기본 규칙

- 작업 디렉터리는 `ulp_ai/`. 산출물은 `logs/`, `reports/`, `out/` 에만 쓴다. `out/`, `logs/`, `*.fsdb` 는 커밋하지 않는다(.gitignore 추가).
- **RTL 동작을 바꾸면 반드시 `./run_sim.sh`(Icarus) 또는 `make -f flow/Makefile rtl_sim`(VCS)이 PASS 인지 다시 확인**하고, 바꾼 이유를 커밋 메시지에 쓴다.
- 라이선스·툴 버전·PDK 경로는 추측하지 말고 확인한다. 모르면 멈추고 사용자에게 묻는다(PDK 이름, 코너 이름, SRAM 컴파일러 유무).
- PDK·라이브러리 파일 내용(셀 이름 외의 수치 데이터)은 NDA 대상일 수 있다. 보고서에는 결과 수치만 적고 라이브러리 원문을 복사하지 않는다.
- 단계마다 아래 "통과 기준"을 확인하고, 실패하면 원인을 고친 뒤 다음 단계로 간다. 경고를 무시하고 진행하지 않는다.
- 긴 작업(합성, PT)은 `| tee logs/*.log` 로 남기고, 끝나면 핵심 수치만 요약한다.

## 1. 환경 확인 (먼저 할 일)

```bash
cat /etc/redhat-release; module avail 2>&1 | grep -iE 'vcs|verdi|syn|dc|pt|prime|fusion'
```
- 필요한 툴: VCS(+Verdi, FSDB), Design Compiler 또는 Fusion Compiler, PrimeTime(PX 또는 PrimePower 라이선스).
  게이트 레벨 UPF 시뮬은 VCS NLP 라이선스가 필요하다. 없으면 7.3의 대안을 쓴다.
- `module load` 또는 `source <툴>/setup` 방식을 확인하고, 이 파일 맨 아래 "서버 메모"에 적어 둔다.
- `lmstat -a` 로 라이선스 기능명(VCS, DC-Ultra/DesignWare, PrimeTime, PrimeTime-PX)을 확인한다.
- `flow/scripts/lib_setup.tcl` 을 실제 PDK 로 작성한다: 표준셀 `.db`(TT/SS/FF 코너), ICG 셀, 리텐션 플롭, 격리셀, 파워스위치 셀, SRAM 매크로 `.db`/Verilog 모델.
  **ULL/HVT 계열(저누설) 라이브러리를 기본으로** 하고, 어떤 Vt 를 썼는지 기록한다.

통과 기준: 툴 3종 실행 가능, lib_setup.tcl 의 `error` 줄 제거, `dc_shell` 에서 `link` 성공.

## 2. 합성 전에 반드시 고칠 RTL (알려진 이슈)

1. **`rtl/icg.v` 는 행동 모델(래치)**: 합성용 `rtl/icg_lib.v` 를 만들어 라이브러리 ICG 셀(예: `CKLNQD*`, `TLATNTSCA*` 등 PDK 이름)을 인스턴스한다. 시뮬용 `icg.v` 는 그대로 둔다.
2. **`rtl/sram.v` 는 8 KB 행동 모델**: 플롭으로 합성하면 면적·누설이 수십 배가 되어 결론이 무의미해진다.
   SRAM 컴파일러로 2048×32, 바이트 쓰기, **리텐션(저전압 유지) 모드 지원** 매크로를 만들고 `rtl/sram_macro.v` 래퍼로 연결한다.
   매크로가 없으면 사용자에게 알리고, 데이터시트의 리텐션 누설 값을 수작업으로 더하는 방식(보고서에 명시)으로 진행한다.
   `$readmemh` 초기화는 테스트벤치에서 `tb.dut.u_ram...` 백도어 로드로 옮긴다.
3. **비합성 구문 점검**: `rv32e_core.v` 의 `task wr` 사용, `initial` 블록 등을 DC 가 경고 없이 받는지 확인. 경고가 나면 동작을 바꾸지 않는 선에서 고친다.
4. **리셋**: 비동기 리셋, 동기 해제(reset synchronizer)를 도메인별로 추가할지 판단하고 결정 사항을 기록한다.
5. 이미 반영된 수정: AON 은 메인 도메인 신호(sleep_req, ack_tgl, period, deep_en)를 `iso_en` 동안 갱신하지 않고 마지막 값을 보관한다(`aon_ctrl.v`). 그래서 격리 클램프 값은 결과에 영향이 없어야 한다. 게이트 시뮬에서 이걸 확인한다.

통과 기준: Icarus/VCS RTL 시뮬 PASS (5/5 결과 일치), 합성용 파일 목록이 `syn_dc.tcl` 의 `RTL` 과 일치.

## 3. RTL 시뮬 (VCS)

```bash
make -f flow/Makefile rtl_sim
```
- 통과 기준: `logs/sim_rtl.log` 에 `PASS`. `[PWR] … main ON/OFF` 표식이 웨이크마다 나온다.
- 이 로그의 `[PWR]` 시각으로 전력 분석 구간을 정한다:
  - `WIN_ON_*`: 한 번의 "main ON → main OFF" 구간(추론 1회 전체)
  - `WIN_OFF_*`: 그다음 "main OFF → main ON" 구간(딥슬립)
- 실제 조건 확인용으로 `sw/gen_firmware.py` 의 `PERIOD` 를 32768(1 s)로 바꾼 실행도 한 번 한다(시간이 오래 걸리면 2~3회 웨이크로 줄인다).

## 4. 합성 (DC, UPF 포함)

```bash
HF_MHZ=1  CORNER_SYN=<TT 코너명> make -f flow/Makefile syn
HF_MHZ=10 CORNER_SYN=<TT 코너명> make -f flow/Makefile syn   # 결과는 out_10mhz/ 등으로 분리
```
- `flow/upf/ulp_soc.upf` 의 셀/전압을 PDK 에 맞게 고친다. 전원 도메인: PD_TOP(AON) 상시, PD_MAIN 스위치.
- 통과 기준:
  - `reports/check_mv.rpt` 에 오류 0 (격리/리텐션/스위치 누락 없음)
  - `reports/timing_syn.rpt` 에 setup 위반 0 (해당 주파수)
  - `reports/clock_gating.rpt` 에서 레지스터의 대부분이 게이팅됨
  - 면적 보고서에 SRAM 이 매크로로 잡힘(플롭 수천 개로 풀리지 않음)

## 5. 게이트 레벨 시뮬 + 파형

```bash
make -f flow/Makefile gls STDCELL_VERILOG="<표준셀/매크로 verilog 모델들>"
```
- 기능: `PASS` 가 RTL 과 같아야 한다. 다르면 X 전파, 리셋, 격리/리텐션 순서를 의심한다.
- 파형: `ulp_soc.fsdb` 생성 확인. 크기가 너무 크면 `$fsdbDumpvars` 범위나 시간을 줄인다.
- 확인 포인트: main OFF 구간에서 PD_MAIN 출력이 클램프되고, ON 후 PC/레지스터가 리텐션으로 복원되어 다음 웨이크가 정상인지.

## 6. PrimeTime: 타이밍 + 전력

```bash
CORNER=tt FSDB=ulp_soc.fsdb WIN_ON_START=.. WIN_ON_END=.. WIN_OFF_START=.. WIN_OFF_END=.. make -f flow/Makefile pt
```
- 코너별로 반복한다: **TT/25°C**(대표값), **FF/85°C 이상**(누설 최악), **SS/저온**(타이밍 최악).
- 수집할 값(도메인별: PD_TOP, PD_MAIN):
  - 활성 구간: 평균 동적 전력, 누설, 구간 길이 → `E_wake = P_active_avg × T_active`
  - 딥슬립 구간: `P_sleep` = AON 누설+동적 + 리텐션 플롭 누설 + SRAM 리텐션 누설 + 꺼진 PD_MAIN 의 스위치 누설
  - 블록별(u_core, u_acc, u_ram) 비율
- 스위치·SRAM 리텐션 누설이 PT 에서 잡히지 않으면 데이터시트 값으로 따로 더하고 보고서에 출처를 쓴다.
- 통과 기준: 모든 코너 타이밍 위반 0(대상 주파수), 전력 보고서에 두 도메인이 모두 나옴.

## 7. 조건 확립 (최종 목표)

다음 식으로 정리한다.

```
P_avg = P_sleep + E_wake × f_wake
조건 A (평균): P_avg ≤ 10 µW   →  f_wake,max = (10 µW − P_sleep) / E_wake
조건 B (구동): P_active,peak ≤ 1 mW (최대 주파수·최악 코너)
```

1. 코너 × 주파수(1, 4, 10 MHz) × 전압(라이브러리가 허용하는 범위) 표를 만든다.
2. 각 행에 `P_sleep`, `E_wake`, `P_active`, `f_wake,max`, 타이밍 여유(slack)를 채운다.
3. 결론 문장을 만든다. 예: "TT 0.9 V 25 °C, 1 MHz 에서 웨이크 ≤ N Hz 이면 평균 ≤ 10 µW. FF 85 °C 에서는 P_sleep 이 X µW 라 ≤ M Hz."
4. **메모리 크기 조건**: SRAM 리텐션 누설(µW/KB)로 "10 µW 를 지키는 최대 리텐션 용량"을 계산한다.
5. 조건 B 가 깨지는 코너가 있으면 주파수 상한을 제시한다.
6. 개선 우선순위를 수치 근거로 제안한다(예: SRAM 일부만 리텐션, HVT 교체, 전압 하향).

### 7.3 NLP 라이선스가 없을 때의 대안
게이트 시뮬을 UPF 없이 실행하고(항상 ON), 딥슬립 구간 전력은 PT 에서 **PD_MAIN 을 OFF 상태로 지정한 누설 분석**
(`set_power_analysis_options`/파워스테이트 기반) 또는 리텐션 셀·스위치 누설 합산으로 구한다. 이 경우 보고서에 "추정"이라고 명시한다.

## 8. 산출물

- `reports/SUMMARY.md`: 위 7의 표와 결론, 사용한 PDK/코너/툴 버전, 가정 목록, 추정치 표시.
- 기존 강의자료·README 의 "가정값"(코어 8 pJ/cycle, 가속기 12 pJ/cycle, AON 0.3 µW, 리텐션 1.0 µW, ON 누설 10 µW)과 **측정값을 나란히 비교**한 표.
- 커밋: 스크립트·제약·UPF·RTL 수정·SUMMARY.md 만. 라이브러리 경로가 들어간 `lib_setup.tcl` 은 사내 정책에 따라 커밋 여부를 사용자에게 묻는다.

## 서버 메모 (Claude Code 가 채움)
- 툴 로드 방법:
- 툴 버전:
- PDK / 코너 이름:
- SRAM 매크로:
