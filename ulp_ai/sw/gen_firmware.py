#!/usr/bin/env python3
"""미니 RV32E 어셈블러 + 2층 MLP(16-8-4) INT8 데이터 생성 + 골든 모델.
출력: firmware.hex (SRAM 초기값), expected.hex (웨이크마다 기대 분류결과)"""
import random, sys, os
random.seed(24)
OUT = sys.argv[1] if len(sys.argv) > 1 else "."
R = {f"x{i}": i for i in range(16)}
R.update(zero=0, ra=1, sp=2, gp=3, tp=4, t0=5, t1=6, t2=7, s0=8, s1=9,
         a0=10, a1=11, a2=12, a3=13, a4=14, a5=15)

def I(op, rd, f3, rs1, imm): return ((imm & 0xFFF) << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | op
def S(op, f3, rs1, rs2, imm): return (((imm >> 5) & 0x7F) << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | ((imm & 0x1F) << 7) | op
def B(f3, rs1, rs2, o):
    return (((o >> 12) & 1) << 31) | (((o >> 5) & 0x3F) << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | (((o >> 1) & 0xF) << 8) | (((o >> 11) & 1) << 7) | 0x63
def J(rd, o):
    return (((o >> 20) & 1) << 31) | (((o >> 1) & 0x3FF) << 21) | (((o >> 11) & 1) << 20) | (((o >> 12) & 0xFF) << 12) | (rd << 7) | 0x6F

# ---------------- 메모리 배치 ----------------
W1, X, H, B1, W2, B2, Y = 0x400, 0x480, 0x490, 0x4A0, 0x4C0, 0x4E0, 0x4F0
ACC, AON = 0x10000000, 0x20000000
NITER, PERIOD, SH1, SH2 = 5, 33, 7, 6   # PERIOD 33틱 ≈ 1 ms (시뮬 단축용; 실사용은 32768틱=1 s)

prog = []   # (kind, args)
def ins(*a): prog.append(a)
def li(rd, v):
    v &= 0xFFFFFFFF
    lo = v & 0xFFF; lo = lo - 0x1000 if lo & 0x800 else lo
    hi = ((v - lo) >> 12) & 0xFFFFF
    if hi: ins("lui", rd, hi)
    ins("addi", rd, "zero" if not hi else rd, lo)
def label(n): prog.append(("label", n))

def layer(w, x, y, b, ln, no, sh, relu):
    for off, v in ((0x08, w), (0x0C, x), (0x10, y), (0x20, b), (0x14, ln), (0x18, no), (0x1C, sh)):
        li("t0", v); ins("sw", "t0", "s0", off)
    li("t0", 1 | (2 if relu else 0)); ins("sw", "t0", "s0", 0x00)   # START
    ins("wfi")                                                      # 가볍게 잠자며 완료 대기
    li("t0", 2); ins("sw", "t0", "s0", 0x04)                        # DONE 클리어

li("s0", ACC); li("s1", AON)
li("t0", 1); ins("sw", "t0", "s0", 0x24)       # 가속기 DONE 인터럽트 enable
li("t0", PERIOD); ins("sw", "t0", "s1", 0x00)
li("t0", 1); ins("sw", "t0", "s1", 0x04)       # deep sleep enable
li("a5", NITER)
label("loop")
ins("wfi")                                      # ← 딥슬립 (파워게이팅) / 타이머로 기상
li("a4", X); ins("lb", "t1", "a4", 0); ins("addi", "t1", "t1", 23); ins("sb", "t1", "a4", 0)  # '센서' 입력 변화
layer(W1, X, H, B1, 16, 8, SH1, True)
layer(W2, H, Y, B2, 8, 4, SH2, False)
li("a0", Y); ins("lb", "a1", "a0", 0); li("a2", 0); li("a3", 1)
label("am"); li("t1", 4); ins("bge", "a3", "t1", "amd")
ins("add", "t2", "a0", "a3"); ins("lb", "t2", "t2", 0); ins("bge", "a1", "t2", "skip")
ins("addi", "a1", "t2", 0); ins("addi", "a2", "a3", 0)
label("skip"); ins("addi", "a3", "a3", 1); ins("jal", "zero", "am")
label("amd"); ins("sw", "a2", "s1", 0x0C)      # 결과 출력
ins("addi", "a5", "a5", -1); ins("bne", "a5", "zero", "loop")
ins("ebreak")

# 2패스 조립
labels, pc = {}, 0
for p in prog:
    if p[0] == "label": labels[p[1]] = pc
    else: pc += 4
words, pc = [], 0
for p in prog:
    if p[0] == "label": continue
    op, *a = p; r = lambda n: R[n]
    if op == "lui":   w = (a[1] << 12) | (r(a[0]) << 7) | 0x37
    elif op == "addi": w = I(0x13, r(a[0]), 0, r(a[1]), a[2])
    elif op == "add":  w = (r(a[2]) << 20) | (r(a[1]) << 15) | (r(a[0]) << 7) | 0x33
    elif op == "lb":   w = I(0x03, r(a[0]), 0, r(a[1]), a[2])
    elif op == "sb":   w = S(0x23, 0, r(a[1]), r(a[0]), a[2])
    elif op == "sw":   w = S(0x23, 2, r(a[1]), r(a[0]), a[2])
    elif op in ("bge", "bne"): w = B(5 if op == "bge" else 1, r(a[0]), r(a[1]), labels[a[2]] - pc)
    elif op == "jal":  w = J(r(a[0]), labels[a[1]] - pc)
    elif op == "wfi":  w = 0x10500073
    elif op == "ebreak": w = 0x00100073
    words.append(w & 0xFFFFFFFF); pc += 4
assert len(words) * 4 <= W1, "code too large"

# ---------------- 데이터 + 골든 모델 ----------------
rnd = lambda n, lo=-64, hi=63: [random.randint(lo, hi) for _ in range(n)]
w1, x, b1 = rnd(8 * 16), rnd(16), rnd(8, -2000, 2000)
w2, b2 = rnd(4 * 8), rnd(4, -500, 500)
def fc(W, xv, b, no, ln, sh, relu):
    out = []
    for j in range(no):
        a = b[j] + sum(W[j * ln + k] * xv[k] for k in range(ln))
        a >>= sh
        if relu and a < 0: a = 0
        out.append(max(-128, min(127, a)))
    return out
exp, xv = [], list(x)
for _ in range(NITER):
    xv[0] = ((xv[0] + 23 + 128) & 0xFF) - 128
    y = fc(w2, fc(w1, xv, b1, 8, 16, SH1, True), b2, 4, 8, SH2, False)
    exp.append(max(range(4), key=lambda i: (y[i], -i)))

mem = bytearray(8192)
for i, w in enumerate(words): mem[4*i:4*i+4] = w.to_bytes(4, "little")
def put8(a, v):  mem[a:a+len(v)] = bytes(t & 0xFF for t in v)
def put32(a, v):
    for i, t in enumerate(v): mem[a+4*i:a+4*i+4] = (t & 0xFFFFFFFF).to_bytes(4, "little")
put8(W1, w1); put8(X, x); put32(B1, b1); put8(W2, w2); put32(B2, b2)
with open(os.path.join(OUT, "firmware.hex"), "w") as f:
    for i in range(0, 8192, 4): f.write("%08x\n" % int.from_bytes(mem[i:i+4], "little"))
with open(os.path.join(OUT, "expected.hex"), "w") as f:
    for e in exp: f.write("%x\n" % e)
print(f"code {len(words)} insns, expected classes {exp}")
