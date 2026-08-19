    .section .text.init
    .globl _start
_start:
    # Zero every architectural register so the RTL and Spike start from
    # identical state. Without this, a register the program never writes holds
    # whatever reset left behind on one side and something else on the other,
    # and the trace comparison diverges for no interesting reason.
    li  x1, 0
    li  x2, 0
    li  x3, 0
    li  x4, 0
    li  x5, 0
    li  x6, 0
    li  x7, 0
    li  x8, 0
    li  x9, 0
    li  x10, 0
    li  x11, 0
    li  x12, 0
    li  x13, 0
    li  x14, 0
    li  x15, 0
    li  x16, 0
    li  x17, 0
    li  x18, 0
    li  x19, 0
    li  x20, 0
    li  x21, 0
    li  x22, 0
    li  x23, 0
    li  x24, 0
    li  x25, 0
    li  x26, 0
    li  x27, 0
    li  x28, 0
    li  x29, 0
    li  x30, 0
    li  x31, 0

    la  sp, _stack_top
    call main

    # Signal completion. The testbench watches for a store to tohost; Spike's
    # HTIF interprets a write of 1 as "exit 0" and stops on its own.
    la   t0, tohost
    li   t1, 1
    sw   t1, 0(t0)

    # The RTL testbench stops the instant it sees the tohost store, but Spike
    # keeps executing until HTIF polls and notices - so Spike's trace runs a
    # few instructions further into this loop. Comparing to a labelled stop
    # point makes both traces end at exactly the same instruction, instead of
    # truncating one to the other's length (which would mask a hung core).
    .globl _finish_loop
_finish_loop:
    j    _finish_loop
