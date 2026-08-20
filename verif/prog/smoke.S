# Smoke program for the RV32I core. Assembled by the toolchain rather than
# hand-encoded: hand-written hex previously produced a misaligned store and a
# mislabelled SLT, both of which looked like core bugs and were not.
    .section .text.init
    .globl _start
_start:
    addi x1,  x0, 5           # x1  = 5
    addi x2,  x0, 7           # x2  = 7
    add  x3,  x1, x2          # x3  = 12
    sub  x4,  x1, x2          # x4  = -2
    and  x5,  x1, x2          # x5  = 5
    or   x6,  x1, x2          # x6  = 7
    xor  x7,  x1, x2          # x7  = 2
    slt  x9,  x1, x2          # x9  = 1   (5 < 7 signed)
    sltu x10, x4, x1          # x10 = 0   (-2 unsigned is huge)
    lui  x11, 0x12345         # x11 = 0x12345000
    srai x12, x4, 1           # x12 = -1  (arithmetic shift keeps the sign)

    addi x13, x0, 512         # word-aligned scratch, clear of the program itself
    sw   x3,  0(x13)          # store 12
    lw   x8,  0(x13)          # load it back -> 12
    sb   x1,  4(x13)          # byte store
    lbu  x14, 4(x13)          # zero-extended byte load -> 5

    beq  x1, x1, taken        # always taken
    addi x15, x0, 99          # must be skipped
taken:
    addi x15, x0, 42          # x15 = 42

    jal  x16, target          # link address into x16
    addi x17, x0, 99          # must be skipped
target:
    addi x18, x0, 7           # x18 = 7

    ecall
