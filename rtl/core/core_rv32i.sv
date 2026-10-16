// Single-cycle RV32I core with machine-mode traps.
//
// One instruction per clock, always. RV32I has no multiply or divide, so
// nothing in this datapath can stall: fetch, decode, register read, execute,
// memory access and writeback all complete between two clock edges, and IPC is
// exactly 1.000. The only architectural state is the PC, the register file and
// the CSRs.
//
// The cost is the clock period: everything above sits in one combinational
// path, which is what later pipelined designs exist to break up.
module core_rv32i
  import rv32_pkg::*;
#(
  parameter logic [31:0] BOOT_ADDR = 32'h0000_0000
) (
  input  logic        clk_i,
  input  logic        rst_ni,

  // Instruction memory: combinational read
  output logic        instr_req_o,
  output logic [31:0] instr_addr_o,
  input  logic [31:0] instr_rdata_i,
  input  logic        instr_ready_i,

  // Data memory
  output logic        data_req_o,
  output logic [31:0] data_addr_o,
  output logic        data_we_o,
  output logic [3:0]  data_be_o,
  output logic [31:0] data_wdata_o,
  input  logic [31:0] data_rdata_i,
  input  logic        data_ready_i,

  // RVFI retirement port (one retirement per cycle) - what the Spike comparison consumes
  output logic        rvfi_valid_o,
  output logic [63:0] rvfi_order_o,
  output logic [31:0] rvfi_insn_o,
  output logic        rvfi_trap_o,
  output logic [4:0]  rvfi_rd_addr_o,
  output logic [31:0] rvfi_rd_wdata_o,
  output logic [31:0] rvfi_pc_rdata_o,
  output logic [31:0] rvfi_pc_wdata_o
);

  // ---- Forward declarations ----------------------------------------------
  // Driven below but referenced earlier. SystemVerilog requires a declaration
  // to precede any reference in the same scope, so they cannot be declared
  // where they are assigned.
  logic        trap_taken;
  logic [31:0] trap_cause, trap_val;
  logic [31:0] pc_n_notrap;
  logic        misaligned_fetch;
  logic        mem_op;       // a real load/store is being presented
  logic        core_stall;   // waiting on instruction or data memory

  // ---- Fetch --------------------------------------------------------------
  logic [31:0] pc_q, pc_n, insn;
  assign instr_addr_o = pc_q;
  assign instr_req_o  = 1'b1;              // fetching every cycle
  assign insn         = instr_rdata_i;

  // ---- Decode -------------------------------------------------------------
  decoded_t dec;
  decoder u_decoder (.insn_i(insn), .dec_o(dec));

  // No caches on this core, so FENCE.I needs no action.
  logic unused_fence_i;
  assign unused_fence_i = dec.is_fence_i;

  // ---- Register file ------------------------------------------------------
  logic [31:0] rs1_data, rs2_data, rd_wdata;
  logic        rd_we;

  regfile u_regfile (
    .clk_i(clk_i), .rst_ni(rst_ni),
    .rs1_addr_i(dec.rs1_addr), .rs2_addr_i(dec.rs2_addr),
    .rd_addr_i(dec.rd_addr), .rd_we_i(rd_we), .rd_wdata_i(rd_wdata),
    .rs1_rdata_o(rs1_data), .rs2_rdata_o(rs2_data)
  );

  // ---- Execute ------------------------------------------------------------
  logic [31:0] alu_a, alu_b, alu_result;
  assign alu_a = dec.alu_a_pc  ? pc_q    : rs1_data;   // AUIPC feeds the PC in
  assign alu_b = dec.alu_b_imm ? dec.imm : rs2_data;

  alu u_alu (.op_i(dec.alu_op), .a_i(alu_a), .b_i(alu_b), .result_o(alu_result));

  // ---- Branch and jump ----------------------------------------------------
  logic branch_taken;
  always_comb begin
    unique case (dec.funct3)
      F3_BEQ:  branch_taken = (rs1_data == rs2_data);
      F3_BNE:  branch_taken = (rs1_data != rs2_data);
      F3_BLT:  branch_taken = ($signed(rs1_data) <  $signed(rs2_data));
      F3_BGE:  branch_taken = ($signed(rs1_data) >= $signed(rs2_data));
      F3_BLTU: branch_taken = (rs1_data <  rs2_data);
      F3_BGEU: branch_taken = (rs1_data >= rs2_data);
      default: branch_taken = 1'b0;
    endcase
  end

  logic [31:0] branch_target, jalr_target;
  assign branch_target = pc_q + dec.imm;
  // JALR clears the low bit of the computed target, per the spec.
  assign jalr_target   = (rs1_data + dec.imm) & 32'hFFFF_FFFE;

  // ---- Load / store -------------------------------------------------------
  logic [31:0] mem_addr;
  assign mem_addr    = rs1_data + dec.imm;
  assign data_addr_o = mem_addr;

  // A byte or halfword store replicates its data across the word; the byte
  // enables then select which copy actually lands.
  assign data_wdata_o = (dec.funct3 == F3_SB) ? {4{rs2_data[7:0]}}  :
                        (dec.funct3 == F3_SH) ? {2{rs2_data[15:0]}} : rs2_data;

  always_comb begin
    unique case (dec.funct3)
      F3_SB:   data_be_o = 4'b0001 << mem_addr[1:0];
      F3_SH:   data_be_o = mem_addr[1] ? 4'b1100 : 4'b0011;
      default: data_be_o = 4'b1111;
    endcase
  end

  logic misaligned_load, misaligned_store;
  assign misaligned_load  = dec.is_load &&
      (((dec.funct3 == F3_LH || dec.funct3 == F3_LHU) && mem_addr[0]) ||
       ( dec.funct3 == F3_LW && (|mem_addr[1:0])));
  assign misaligned_store = dec.is_store &&
      ((dec.funct3 == F3_SH && mem_addr[0]) ||
       (dec.funct3 == F3_SW && (|mem_addr[1:0])));

  // A misaligned or trapping store must never reach memory.
  // A request is raised for any real memory access; the memory commits a write
  // only on the handshake cycle, so holding this across stall cycles is safe.
  assign mem_op     = (dec.is_load || dec.is_store) && !trap_taken;
  assign data_req_o = mem_op;
  assign data_we_o  = dec.is_store && !misaligned_store && !trap_taken;

  assign core_stall = !instr_ready_i || (mem_op && !data_ready_i);

  // Byte and halfword loads select a lane by address, then sign-extend from
  // the top bit OF THAT LANE - not from bit 31 of the word.
  logic [31:0] load_data;
  logic [7:0]  load_byte;
  logic [15:0] load_half;
  assign load_byte = data_rdata_i[8*mem_addr[1:0] +: 8];
  assign load_half = mem_addr[1] ? data_rdata_i[31:16] : data_rdata_i[15:0];
  always_comb begin
    unique case (dec.funct3)
      F3_LB:   load_data = {{24{load_byte[7]}},  load_byte};
      F3_LBU:  load_data = {24'b0,               load_byte};
      F3_LH:   load_data = {{16{load_half[15]}}, load_half};
      F3_LHU:  load_data = {16'b0,               load_half};
      default: load_data = data_rdata_i;
    endcase
  end

  // ---- CSR access ---------------------------------------------------------
  logic [31:0] csr_rdata, csr_wdata, csr_operand, mtvec, mepc;
  logic        csr_we, csr_illegal;

  // funct3[2] selects the immediate form, where the operand is the
  // zero-extended rs1 field rather than the register value.
  assign csr_operand = dec.funct3[2] ? {27'b0, dec.rs1_addr} : rs1_data;

  always_comb begin
    unique case (dec.funct3)
      F3_CSRRW, F3_CSRRWI: csr_wdata = csr_operand;
      F3_CSRRS, F3_CSRRSI: csr_wdata = csr_rdata |  csr_operand;
      F3_CSRRC, F3_CSRRCI: csr_wdata = csr_rdata & ~csr_operand;
      default:             csr_wdata = csr_rdata;
    endcase
  end

  // CSRRS/CSRRC with rs1 = x0 are pure reads and must not write at all.
  logic csr_writes;
  assign csr_writes = (dec.funct3 == F3_CSRRW) || (dec.funct3 == F3_CSRRWI) ||
                      (dec.rs1_addr != 5'd0);

  // Pure write INTENT: no trap and no stall term. illegal_o is computed from
  // this, and core_stall depends on trap_taken, so either term closes a loop
  // (trap_taken -> core_stall -> csr_we -> csr_illegal -> trap_taken).
  // csr_file applies the stall to the actual update through stall_i.
  assign csr_we = dec.is_csr && csr_writes;

  logic insn_retired;

  csr_file u_csr_file (
    .clk_i(clk_i), .rst_ni(rst_ni),
    .addr_i(dec.imm[11:0]), .wdata_i(csr_wdata), .we_i(csr_we),
    .rdata_o(csr_rdata), .illegal_o(csr_illegal),
    .trap_i(trap_taken), .trap_cause_i(trap_cause), .trap_pc_i(pc_q),
    .trap_val_i(trap_val), .mret_i(dec.is_mret && !trap_taken),
    .tvec_o(mtvec), .epc_o(mepc), .insn_retired_i(insn_retired), .stall_i(core_stall)
  );

  // ---- Traps --------------------------------------------------------------
  logic illegal_insn;
  assign illegal_insn = dec.illegal || (dec.is_csr && csr_illegal);

  // Priority order matters: an illegal instruction is detected before its
  // operands are ever used.
  always_comb begin
    trap_taken = 1'b0;
    trap_cause = '0;
    trap_val   = '0;
    if (illegal_insn) begin
      trap_taken = 1'b1; trap_cause = EXC_ILLEGAL_INSN;     trap_val = insn;
    end else if (dec.is_ecall) begin
      trap_taken = 1'b1; trap_cause = EXC_ECALL_M;          trap_val = '0;
    end else if (dec.is_ebreak) begin
      trap_taken = 1'b1; trap_cause = EXC_BREAKPOINT;       trap_val = pc_q;
    end else if (misaligned_load) begin
      trap_taken = 1'b1; trap_cause = EXC_LOAD_MISALIGNED;  trap_val = mem_addr;
    end else if (misaligned_store) begin
      trap_taken = 1'b1; trap_cause = EXC_STORE_MISALIGNED; trap_val = mem_addr;
    end else if (misaligned_fetch) begin
      trap_taken = 1'b1; trap_cause = EXC_INSN_MISALIGNED;  trap_val = pc_n_notrap;
    end
  end

  // ---- Writeback ----------------------------------------------------------
  always_comb begin
    if      (dec.is_load)               rd_wdata = load_data;
    else if (dec.is_jal || dec.is_jalr) rd_wdata = pc_q + 32'd4;  // link address
    else if (dec.is_csr)                rd_wdata = csr_rdata;
    else                                rd_wdata = alu_result;
  end

  assign rd_we = dec.rd_we && !trap_taken && !core_stall;

  // ---- Next PC ------------------------------------------------------------
  always_comb begin
    if      (dec.is_jal)                    pc_n_notrap = pc_q + dec.imm;
    else if (dec.is_jalr)                   pc_n_notrap = jalr_target;
    else if (dec.is_branch && branch_taken) pc_n_notrap = branch_target;
    else                                    pc_n_notrap = pc_q + 32'd4;
  end

  // A jump or taken branch to an unaligned address traps instead of jumping.
  assign misaligned_fetch = (dec.is_jal || dec.is_jalr ||
                             (dec.is_branch && branch_taken)) && (|pc_n_notrap[1:0]);

  always_comb begin
    if      (core_stall)  pc_n = pc_q;      // hold until memory answers
    else if (trap_taken)  pc_n = mtvec;
    else if (dec.is_mret) pc_n = mepc;
    else                  pc_n = pc_n_notrap;
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) pc_q <= BOOT_ADDR;
    else         pc_q <= pc_n;
  end

  // ---- RVFI retirement port ----------------------------------------------
  // Nothing stalls, so an instruction retires every cycle after reset.
  assign insn_retired = !core_stall;

  logic [63:0] order_q;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni)           order_q <= 64'd0;
    else if (insn_retired) order_q <= order_q + 64'd1;
  end

  // RVFI requires rd_wdata to read ZERO whenever rd_addr is zero. Writes to x0
  // are discarded, so `jalr x0, 0(ra)` - an ordinary `ret` - computes a link
  // value that is never stored. Reporting it diverges from the reference model
  // on every single function return.
  logic rvfi_rd_write;
  assign rvfi_rd_write = rd_we && (dec.rd_addr != 5'd0);

  assign rvfi_valid_o    = insn_retired;
  assign rvfi_order_o    = order_q;
  assign rvfi_insn_o     = insn;
  assign rvfi_trap_o     = trap_taken;
  assign rvfi_rd_addr_o  = rvfi_rd_write ? dec.rd_addr : 5'd0;
  assign rvfi_rd_wdata_o = rvfi_rd_write ? rd_wdata    : 32'd0;
  assign rvfi_pc_rdata_o = pc_q;
  assign rvfi_pc_wdata_o = pc_n;

endmodule
