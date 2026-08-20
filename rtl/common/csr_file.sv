// Machine-mode CSRs and the trap protocol. This is what makes the design a
// processor rather than a calculator: without it there is no way to take an
// exception and no way to return from one.
//
// Only the subset needed to run riscv-tests p-mode is implemented; every other
// address reads as illegal so the core raises an illegal-instruction exception
// instead of silently returning zero.
module csr_file
  import rv32_pkg::*;
#(
  // MXL=1 (32-bit), extension bit 8 = 'I'. No 'M' bit: this core is RV32I.
  parameter logic [31:0] MISA_VALUE = 32'h4000_0100
) (
  input  logic        clk_i,
  input  logic        rst_ni,

  // CSR access port
  input  logic [11:0] addr_i,
  input  logic [31:0] wdata_i,
  input  logic        we_i,
  output logic [31:0] rdata_o,
  output logic        illegal_o,

  // Trap interface
  input  logic        trap_i,
  input  logic [31:0] trap_cause_i,
  input  logic [31:0] trap_pc_i,
  input  logic [31:0] trap_val_i,
  input  logic        mret_i,
  output logic [31:0] tvec_o,
  output logic [31:0] epc_o,

  input  logic        insn_retired_i
);

  logic [31:0] mstatus_q, mtvec_q, mepc_q, mcause_q, mtval_q,
               mscratch_q, mie_q, mip_q, mcountinhibit_q;
  logic [63:0] mcycle_q, minstret_q;

  localparam int MIE_BIT  = 3;
  localparam int MPIE_BIT = 7;
  // mstatus[12:11] = MPP, the privilege level before the trap. This core
  // implements M-mode only, so it is always machine mode. Leaving it zero makes
  // mstatus read 0x0080 where a conforming model reads 0x1880.
  localparam logic [1:0]  MPP_M = 2'b11;
  // Only CY (bit 0) and IR (bit 2) are defined in mcountinhibit.
  localparam logic [31:0] MCOUNTINHIBIT_MASK = 32'h0000_0005;

  logic exists, writable;
  always_comb begin
    exists   = 1'b1;
    writable = 1'b1;
    unique case (addr_i)
      CSR_MSTATUS, CSR_MIE, CSR_MTVEC, CSR_MSCRATCH,
      CSR_MEPC, CSR_MCAUSE, CSR_MTVAL, CSR_MIP, CSR_MISA,
      CSR_MCYCLE, CSR_MINSTRET, CSR_MCYCLEH, CSR_MINSTRETH,
      CSR_MCOUNTINHIBIT: begin
        exists = 1'b1; writable = 1'b1;
      end
      CSR_MVENDORID, CSR_MARCHID, CSR_MIMPID, CSR_MHARTID: begin
        exists = 1'b1; writable = 1'b0;    // read-only identity registers
      end
      default: begin
        // PMP: zero entries implemented, so these are accessible and hardwired
        // to zero rather than absent. riscv-tests writes pmpaddr0/pmpcfg0 in
        // its common prologue, so trapping here diverges on EVERY test.
        if (((addr_i >= CSR_PMPCFG0)  && (addr_i <= CSR_PMPCFG3)) ||
            ((addr_i >= CSR_PMPADDR0) && (addr_i <= CSR_PMPADDR15))) begin
          exists = 1'b1; writable = 1'b1;  // writes accepted, then ignored
        end else begin
          exists = 1'b0; writable = 1'b0;
        end
      end
    endcase
  end

  assign illegal_o = !exists || (we_i && !writable);

  always_comb begin
    unique case (addr_i)
      CSR_MSTATUS:       rdata_o = {mstatus_q[31:13], MPP_M, mstatus_q[10:0]};
      CSR_MISA:          rdata_o = MISA_VALUE;
      CSR_MIE:           rdata_o = mie_q;
      CSR_MTVEC:         rdata_o = mtvec_q;
      CSR_MSCRATCH:      rdata_o = mscratch_q;
      CSR_MEPC:          rdata_o = mepc_q;
      CSR_MCAUSE:        rdata_o = mcause_q;
      CSR_MTVAL:         rdata_o = mtval_q;
      CSR_MIP:           rdata_o = mip_q;
      CSR_MCOUNTINHIBIT: rdata_o = mcountinhibit_q;
      CSR_MCYCLE:        rdata_o = mcycle_q[31:0];
      CSR_MINSTRET:      rdata_o = minstret_q[31:0];
      CSR_MCYCLEH:       rdata_o = mcycle_q[63:32];
      CSR_MINSTRETH:     rdata_o = minstret_q[63:32];
      default:           rdata_o = 32'd0;
    endcase
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      mstatus_q  <= '0; mtvec_q    <= '0; mepc_q  <= '0; mcause_q <= '0;
      mtval_q    <= '0; mscratch_q <= '0; mie_q   <= '0; mip_q    <= '0;
      mcycle_q   <= '0; minstret_q <= '0; mcountinhibit_q <= '0;
    end else begin
      if (!mcountinhibit_q[0]) mcycle_q <= mcycle_q + 64'd1;
      if (insn_retired_i && !mcountinhibit_q[2]) minstret_q <= minstret_q + 64'd1;

      // Trap entry outranks a CSR write in the same cycle. That ordering is
      // load-bearing: it lets the core drive we_i as pure write INTENT, which
      // is what breaks the loop trap_taken -> csr_we -> illegal_o ->
      // illegal_insn -> trap_taken.
      if (trap_i) begin
        mepc_q              <= trap_pc_i;
        mcause_q            <= trap_cause_i;
        mtval_q             <= trap_val_i;
        mstatus_q[MPIE_BIT] <= mstatus_q[MIE_BIT];  // push interrupt enable
        mstatus_q[MIE_BIT]  <= 1'b0;                // and disable interrupts
      end else if (mret_i) begin
        mstatus_q[MIE_BIT]  <= mstatus_q[MPIE_BIT]; // pop it back
        mstatus_q[MPIE_BIT] <= 1'b1;
      end else if (we_i && writable) begin
        unique case (addr_i)
          CSR_MSTATUS:       mstatus_q  <= wdata_i;
          CSR_MIE:           mie_q      <= wdata_i;
          // mtvec[1:0] selects the mode; only direct mode is supported here.
          CSR_MTVEC:         mtvec_q    <= {wdata_i[31:2], 2'b00};
          CSR_MSCRATCH:      mscratch_q <= wdata_i;
          CSR_MEPC:          mepc_q     <= {wdata_i[31:1], 1'b0};
          CSR_MCAUSE:        mcause_q   <= wdata_i;
          CSR_MTVAL:         mtval_q    <= wdata_i;
          CSR_MCOUNTINHIBIT: mcountinhibit_q <= wdata_i & MCOUNTINHIBIT_MASK;
          CSR_MCYCLE:        mcycle_q[31:0]    <= wdata_i;
          CSR_MINSTRET:      minstret_q[31:0]  <= wdata_i;
          CSR_MCYCLEH:       mcycle_q[63:32]   <= wdata_i;
          CSR_MINSTRETH:     minstret_q[63:32] <= wdata_i;
          default: ;  // MISA, MIP and the PMP registers accept writes, ignore them
        endcase
      end
    end
  end

  assign tvec_o = mtvec_q;
  assign epc_o  = mepc_q;

endmodule
