// Five-stage pipelined RV32I core with machine-mode traps.
//
//   IF -> ID -> EX -> MEM -> WB
//
// The single-cycle core put fetch through writeback in one clock period. This
// one cuts that chain into five, so the clock can be much shorter - at the cost
// of hazards, which is what the forwarding unit and the interlock below exist
// to handle.
//
// Design decisions and why:
//
//   Forwarding EX/MEM->EX and MEM/WB->EX removes nearly every read-after-write
//   stall. A result is available at the end of EX, long before it is written
//   back, so it can be routed straight to a younger instruction's operand mux.
//
//   Load-use is the one hazard forwarding cannot fix: a loaded value does not
//   exist until the end of MEM, so a dependent instruction must lose a cycle.
//   Detected in ID, costs exactly one bubble.
//
//   Branches resolve in EX, flushing two instructions. Resolving in ID would
//   cost one, but needs a comparator plus extra forwarding paths into ID, which
//   lengthens the very stage that is usually critical.
//
//   Traps and CSR access both happen at MEM, in program order. That gives
//   precise exceptions for free - the trapping instruction has not written
//   anything architectural yet, and everything younger is still in the pipe and
//   can simply be flushed. It also means CSR instructions need no hazard logic
//   at all: two back-to-back CSR ops access the file in consecutive cycles at
//   the same stage, so they are already ordered.
module core_rv32i_p5
  import rv32_pkg::*;
#(
  parameter logic [31:0] BOOT_ADDR = 32'h0000_0000
) (
  input  logic        clk_i,
  input  logic        rst_ni,

  output logic        instr_req_o,
  output logic [31:0] instr_addr_o,
  input  logic [31:0] instr_rdata_i,
  input  logic        instr_ready_i,
  input  logic        instr_gnt_i,

  output logic        data_req_o,
  output logic [31:0] data_addr_o,
  output logic        data_we_o,
  output logic [3:0]  data_be_o,
  output logic [31:0] data_wdata_o,
  input  logic [31:0] data_rdata_i,
  input  logic        data_ready_i,
  // The data cache reads its arrays one edge early, at this address.
  output logic [31:0] data_pre_addr_o,
  // FENCE.I handshake with the caches.
  output logic        flush_req_o,
  input  logic        flush_done_i,

  // RVFI retirement port, emitted at WB so retirement stays in program order.
  output logic        rvfi_valid_o,
  output logic [63:0] rvfi_order_o,
  output logic [31:0] rvfi_insn_o,
  output logic        rvfi_trap_o,
  output logic [4:0]  rvfi_rd_addr_o,
  output logic [31:0] rvfi_rd_wdata_o,
  output logic [31:0] rvfi_pc_rdata_o,
  output logic [31:0] rvfi_pc_wdata_o
);

  // ======================================================================
  // Pipeline register definitions
  // ======================================================================
  typedef struct packed {
    logic        valid;
    logic [31:0] pc;
    logic [31:0] insn;
    decoded_t    dec;
    logic [31:0] rs1_data;
    logic [31:0] rs2_data;
  } id_ex_t;

  typedef struct packed {
    logic        valid;
    logic [31:0] pc;
    logic [31:0] insn;
    decoded_t    dec;
    logic [31:0] alu_result;
    logic [31:0] rs1_data;     // rs1 after forwarding - CSR ops need it at MEM
    logic [31:0] store_data;   // rs2 after forwarding
    logic [31:0] mem_addr;
    logic [31:0] pc_next;      // this instruction's own next PC, for RVFI
    logic        fetch_misaligned;   // the only exception that needs EX to detect
  } ex_mem_t;

  typedef struct packed {
    logic        valid;
    logic [31:0] pc;
    logic [31:0] insn;
    logic [4:0]  rd_addr;
    logic        rd_we;
    logic [31:0] wb_data;
    logic [31:0] pc_next;
    logic        trap;
  } mem_wb_t;

  id_ex_t  id_ex_q;
  ex_mem_t ex_mem_q;
  mem_wb_t mem_wb_q;

  // Control signals driven from later stages, declared up front because
  // SystemVerilog requires a declaration before any reference.
  logic        stall_ld_use;
  logic        stall_mem;     // data access outstanding
  logic        flush_branch;
  logic        flush_trap;
  logic [31:0] redirect_pc;
  logic        redirect_valid;

  // ======================================================================
  // IF - decoupled instruction fetch
  // ======================================================================
  // The fetch unit owns the fetch PC and a prefetch buffer, and its head IS
  // the IF/ID interface. When the buffer is empty if_valid simply goes low and
  // a bubble flows down the pipe, instead of a fetch stall freezing the entire
  // core the way a direct memory read did. That is what lets fetch latency
  // overlap with work already in flight.
  logic        if_valid;
  logic [31:0] if_pc, if_insn;
  logic        if_pop;

  fetch_unit #(.DEPTH(4), .BOOT_ADDR(BOOT_ADDR)) u_fetch (
    .clk_i(clk_i), .rst_ni(rst_ni),
    .redirect_i(redirect_valid), .redirect_pc_i(redirect_pc),
    .instr_req_o(instr_req_o), .instr_addr_o(instr_addr_o),
    .instr_gnt_i(instr_gnt_i),
    .instr_rdata_i(instr_rdata_i), .instr_ready_i(instr_ready_i),
    .insn_valid_o(if_valid), .insn_pc_o(if_pc), .insn_o(if_insn),
    .insn_ready_i(if_pop)
  );

  // Decode consumes the head whenever the front end can advance.
  assign if_pop = if_valid && !stall_mem && !stall_ld_use;

  // ======================================================================
  // ID - decode and register read
  // ======================================================================
  decoded_t dec_id;
  decoder u_decoder (.insn_i(if_insn), .dec_o(dec_id));

  logic [31:0] rs1_data_id, rs2_data_id;
  logic [4:0]  wb_rd_addr;
  logic        wb_rd_we;
  logic [31:0] wb_rd_data;

  regfile u_regfile (
    .clk_i(clk_i), .rst_ni(rst_ni),
    .rs1_addr_i(dec_id.rs1_addr), .rs2_addr_i(dec_id.rs2_addr),
    .rd_addr_i(wb_rd_addr), .rd_we_i(wb_rd_we), .rd_wdata_i(wb_rd_data),
    .rs1_rdata_o(rs1_data_id), .rs2_rdata_o(rs2_data_id)
  );

  // The register file writes on the clock edge and reads asynchronously, so an
  // instruction in ID would see the OLD value of a register being written by
  // the instruction in WB this same cycle. Forward around it.
  logic [31:0] rs1_id_fwd, rs2_id_fwd;
  logic        wb_hits_rs1, wb_hits_rs2;
  assign wb_hits_rs1 = wb_rd_we && (wb_rd_addr != 5'd0) &&
                       (wb_rd_addr == dec_id.rs1_addr);
  assign wb_hits_rs2 = wb_rd_we && (wb_rd_addr != 5'd0) &&
                       (wb_rd_addr == dec_id.rs2_addr);
  assign rs1_id_fwd = wb_hits_rs1 ? wb_rd_data : rs1_data_id;
  assign rs2_id_fwd = wb_hits_rs2 ? wb_rd_data : rs2_data_id;

  // ---- MEM-result interlock (load-use, and CSR-use) ----
  // The hazard forwarding cannot fix: a value that does not exist until the end
  // of MEM cannot be routed back into an EX that is happening now. That covers
  // loads AND CSR reads, since the CSR file is accessed at MEM. A dependent
  // instruction in ID waits exactly one cycle, after which the producer is in
  // MEM/WB and normal forwarding works.
  logic id_ex_result_at_mem;
  assign id_ex_result_at_mem = id_ex_q.dec.is_load || id_ex_q.dec.is_csr;

  assign stall_ld_use = id_ex_q.valid && id_ex_result_at_mem &&
                        (id_ex_q.dec.rd_addr != 5'd0) &&
                        if_valid &&
                        ((id_ex_q.dec.rd_addr == dec_id.rs1_addr) ||
                         (id_ex_q.dec.rd_addr == dec_id.rs2_addr));

  // ---- ID/EX ----
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      id_ex_q <= '0;
    end else if (stall_mem) begin
      id_ex_q <= id_ex_q;                          // frozen behind MEM
    end else if (flush_trap || flush_branch || stall_ld_use) begin
      id_ex_q <= '0;                               // insert a bubble
    end else begin
      id_ex_q.valid    <= if_valid;
      id_ex_q.pc       <= if_pc;
      id_ex_q.insn     <= if_insn;
      id_ex_q.dec      <= dec_id;
      id_ex_q.rs1_data <= rs1_id_fwd;
      id_ex_q.rs2_data <= rs2_id_fwd;
    end
  end

  // ======================================================================
  // EX - execute, branch resolution, address generation
  // ======================================================================

  // ---- Forwarding ----
  // EX/MEM can only be forwarded from when the result actually EXISTS in EX.
  // Two instruction classes produce their writeback value at MEM instead:
  //   loads     - alu_result holds the address, not the loaded data
  //   CSR reads - the CSR file is accessed at MEM, so alu_result is meaningless
  // Forwarding either one hands the consumer garbage. Both are excluded here
  // and covered by the interlock below.
  logic ex_mem_fwd_ok;
  assign ex_mem_fwd_ok = ex_mem_q.valid && ex_mem_q.dec.rd_we &&
                         !ex_mem_q.dec.is_load && !ex_mem_q.dec.is_csr &&
                         (ex_mem_q.dec.rd_addr != 5'd0);

  logic mem_wb_fwd_ok;
  assign mem_wb_fwd_ok = mem_wb_q.valid && mem_wb_q.rd_we &&
                         (mem_wb_q.rd_addr != 5'd0);

  logic [31:0] fwd_rs1, fwd_rs2;
  always_comb begin
    if      (ex_mem_fwd_ok && (ex_mem_q.dec.rd_addr == id_ex_q.dec.rs1_addr))
      fwd_rs1 = ex_mem_q.alu_result;
    else if (mem_wb_fwd_ok && (mem_wb_q.rd_addr == id_ex_q.dec.rs1_addr))
      fwd_rs1 = mem_wb_q.wb_data;
    else
      fwd_rs1 = id_ex_q.rs1_data;
  end

  always_comb begin
    if      (ex_mem_fwd_ok && (ex_mem_q.dec.rd_addr == id_ex_q.dec.rs2_addr))
      fwd_rs2 = ex_mem_q.alu_result;
    else if (mem_wb_fwd_ok && (mem_wb_q.rd_addr == id_ex_q.dec.rs2_addr))
      fwd_rs2 = mem_wb_q.wb_data;
    else
      fwd_rs2 = id_ex_q.rs2_data;
  end

  // ---- ALU ----
  logic [31:0] alu_a_ex, alu_b_ex, alu_result_ex;
  assign alu_a_ex = id_ex_q.dec.alu_a_pc  ? id_ex_q.pc  : fwd_rs1;
  assign alu_b_ex = id_ex_q.dec.alu_b_imm ? id_ex_q.dec.imm : fwd_rs2;

  alu u_alu (.op_i(id_ex_q.dec.alu_op), .a_i(alu_a_ex), .b_i(alu_b_ex),
             .result_o(alu_result_ex));

  // The EX-stage result that will eventually be written back. JAL/JALR write a
  // link address rather than an ALU result, and computing it HERE rather than
  // at MEM is what lets it be forwarded to the very next instruction. Loads and
  // CSR reads cannot be handled this way - their values genuinely do not exist
  // until MEM - so they are excluded from forwarding and interlocked instead.
  logic [31:0] ex_result;
  always_comb begin
    if (id_ex_q.dec.is_jal || id_ex_q.dec.is_jalr) ex_result = id_ex_q.pc + 32'd4;
    else                                           ex_result = alu_result_ex;
  end

  // ---- Branch / jump ----
  logic branch_cond_ex;
  always_comb begin
    unique case (id_ex_q.dec.funct3)
      F3_BEQ:  branch_cond_ex = (fwd_rs1 == fwd_rs2);
      F3_BNE:  branch_cond_ex = (fwd_rs1 != fwd_rs2);
      F3_BLT:  branch_cond_ex = ($signed(fwd_rs1) <  $signed(fwd_rs2));
      F3_BGE:  branch_cond_ex = ($signed(fwd_rs1) >= $signed(fwd_rs2));
      F3_BLTU: branch_cond_ex = (fwd_rs1 <  fwd_rs2);
      F3_BGEU: branch_cond_ex = (fwd_rs1 >= fwd_rs2);
      default: branch_cond_ex = 1'b0;
    endcase
  end

  logic        take_branch_ex;
  logic [31:0] branch_target_ex;
  assign take_branch_ex   = id_ex_q.valid &&
                            ((id_ex_q.dec.is_branch && branch_cond_ex) ||
                             id_ex_q.dec.is_jal || id_ex_q.dec.is_jalr);
  assign branch_target_ex = id_ex_q.dec.is_jalr
                          ? ((fwd_rs1 + id_ex_q.dec.imm) & 32'hFFFF_FFFE)
                          : (id_ex_q.pc + id_ex_q.dec.imm);

  logic [31:0] pc_next_ex;
  assign pc_next_ex = take_branch_ex ? branch_target_ex : (id_ex_q.pc + 32'd4);

  // ---- Address generation and alignment checks ----
  logic [31:0] mem_addr_ex;
  assign mem_addr_ex = fwd_rs1 + id_ex_q.dec.imm;

  // Fetch misalignment depends on the branch decision, so it is detected here
  // and carried as one bit. Every other exception is classified at MEM from
  // fields already in the EX/MEM register: that was worth doing because the
  // priority mux and its 32-bit tval select sat at the end of the longest path
  // in the design (forwarding -> adder -> alignment -> priority -> tval).
  logic misaligned_fetch_ex;
  assign misaligned_fetch_ex = take_branch_ex && (|branch_target_ex[1:0]);

  // ---- EX/MEM ----
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      ex_mem_q <= '0;
    end else if (stall_mem) begin
      ex_mem_q <= ex_mem_q;                        // hold the request steady
    end else if (flush_trap) begin
      ex_mem_q <= '0;
    end else begin
      ex_mem_q.valid      <= id_ex_q.valid;
      ex_mem_q.pc         <= id_ex_q.pc;
      ex_mem_q.insn       <= id_ex_q.insn;
      ex_mem_q.dec        <= id_ex_q.dec;
      ex_mem_q.alu_result <= ex_result;
      ex_mem_q.rs1_data   <= fwd_rs1;
      ex_mem_q.store_data <= fwd_rs2;
      ex_mem_q.mem_addr   <= mem_addr_ex;
      ex_mem_q.pc_next    <= pc_next_ex;
      ex_mem_q.fetch_misaligned <= misaligned_fetch_ex;
    end
  end

  // ======================================================================
  // MEM - data memory, CSR access, trap point
  // ======================================================================
  assign data_addr_o = ex_mem_q.mem_addr;

  assign data_wdata_o = (ex_mem_q.dec.funct3 == F3_SB) ? {4{ex_mem_q.store_data[7:0]}}  :
                        (ex_mem_q.dec.funct3 == F3_SH) ? {2{ex_mem_q.store_data[15:0]}} :
                                                          ex_mem_q.store_data;

  always_comb begin
    unique case (ex_mem_q.dec.funct3)
      F3_SB:   data_be_o = 4'b0001 << ex_mem_q.mem_addr[1:0];
      F3_SH:   data_be_o = ex_mem_q.mem_addr[1] ? 4'b1100 : 4'b0011;
      default: data_be_o = 4'b1111;
    endcase
  end

  // ---- CSR access, in program order at this stage ----
  logic [31:0] csr_rdata, csr_wdata, csr_operand, mtvec, mepc;
  logic        csr_we, csr_illegal;

  // funct3[2] selects the immediate form, where the operand is the zero-extended
  // rs1 FIELD rather than the register value. Note this must use rs1, not the
  // store data - store_data carries rs2, and a CSRRW writing rs2 would be
  // silently wrong for every CSR instruction with two different source regs.
  assign csr_operand = ex_mem_q.dec.funct3[2]
                     ? {27'b0, ex_mem_q.dec.rs1_addr}
                     : ex_mem_q.rs1_data;

  always_comb begin
    unique case (ex_mem_q.dec.funct3)
      F3_CSRRW, F3_CSRRWI: csr_wdata = csr_operand;
      F3_CSRRS, F3_CSRRSI: csr_wdata = csr_rdata |  csr_operand;
      F3_CSRRC, F3_CSRRCI: csr_wdata = csr_rdata & ~csr_operand;
      default:             csr_wdata = csr_rdata;
    endcase
  end

  logic csr_writes;
  assign csr_writes = (ex_mem_q.dec.funct3 == F3_CSRRW) ||
                      (ex_mem_q.dec.funct3 == F3_CSRRWI) ||
                      (ex_mem_q.dec.rs1_addr != 5'd0);

  // Pure write INTENT. No stall or trap term: illegal_o is computed from this,
  // and the stall depends on the trap decision, so any such term closes a loop.
  // csr_file applies the stall to the actual update through stall_i.
  assign csr_we = ex_mem_q.valid && ex_mem_q.dec.is_csr && csr_writes;

  // ---- Exception classification ----
  // Priority matches the single-cycle core. For a fetch misalignment the
  // registered pc_next IS the branch target, so no extra state is carried.
  logic misaligned_ld_mem, misaligned_st_mem;
  assign misaligned_ld_mem = ex_mem_q.dec.is_load &&
      (((ex_mem_q.dec.funct3 == F3_LH || ex_mem_q.dec.funct3 == F3_LHU) && ex_mem_q.mem_addr[0]) ||
       ( ex_mem_q.dec.funct3 == F3_LW && (|ex_mem_q.mem_addr[1:0])));
  assign misaligned_st_mem = ex_mem_q.dec.is_store &&
      ((ex_mem_q.dec.funct3 == F3_SH && ex_mem_q.mem_addr[0]) ||
       (ex_mem_q.dec.funct3 == F3_SW && (|ex_mem_q.mem_addr[1:0])));

  logic        exc_valid_mem;
  logic [31:0] exc_cause_mem, exc_tval_mem;
  always_comb begin
    exc_valid_mem = 1'b1;
    exc_cause_mem = '0;
    exc_tval_mem  = '0;
    if (ex_mem_q.dec.illegal) begin
      exc_cause_mem = EXC_ILLEGAL_INSN;      exc_tval_mem = ex_mem_q.insn;
    end else if (ex_mem_q.dec.is_ecall) begin
      exc_cause_mem = EXC_ECALL_M;
    end else if (ex_mem_q.dec.is_ebreak) begin
      exc_cause_mem = EXC_BREAKPOINT;        exc_tval_mem = ex_mem_q.pc;
    end else if (misaligned_ld_mem) begin
      exc_cause_mem = EXC_LOAD_MISALIGNED;   exc_tval_mem = ex_mem_q.mem_addr;
    end else if (misaligned_st_mem) begin
      exc_cause_mem = EXC_STORE_MISALIGNED;  exc_tval_mem = ex_mem_q.mem_addr;
    end else if (ex_mem_q.fetch_misaligned) begin
      exc_cause_mem = EXC_INSN_MISALIGNED;   exc_tval_mem = ex_mem_q.pc_next;
    end else begin
      exc_valid_mem = 1'b0;
    end
    if (!ex_mem_q.valid) exc_valid_mem = 1'b0;
  end

  // ---- The trap point ----
  // Everything older has already retired; everything younger is still in the
  // pipe and gets flushed. That is what makes the exception precise.
  logic        trap_taken;
  logic [31:0] trap_cause, trap_tval;
  always_comb begin
    if (exc_valid_mem) begin
      trap_taken = 1'b1;
      trap_cause = exc_cause_mem;
      trap_tval  = exc_tval_mem;
    end else if (ex_mem_q.valid && ex_mem_q.dec.is_csr && csr_illegal) begin
      trap_taken = 1'b1;
      trap_cause = EXC_ILLEGAL_INSN;
      trap_tval  = ex_mem_q.insn;
    end else begin
      trap_taken = 1'b0;
      trap_cause = '0;
      trap_tval  = '0;
    end
  end

  logic mret_taken;
  assign mret_taken = ex_mem_q.valid && ex_mem_q.dec.is_mret && !trap_taken;

  // A trapping store must never reach memory.
  logic mem_op;
  assign mem_op     = ex_mem_q.valid &&
                      (ex_mem_q.dec.is_load || ex_mem_q.dec.is_store) &&
                      !trap_taken;
  assign data_req_o = mem_op;

  // ---- FENCE.I ----
  // Held in MEM until both caches report done: the data cache has written back
  // every dirty line and the instruction cache is invalidated. It then
  // redirects fetch to the next instruction, discarding anything already
  // prefetched - those words may be stale.
  logic fence_i_mem, fence_i_done;
  assign fence_i_mem  = ex_mem_q.valid && ex_mem_q.dec.is_fence_i;
  assign fence_i_done = fence_i_mem && flush_done_i;
  assign flush_req_o  = fence_i_mem;

  assign stall_mem  = (mem_op && !data_ready_i) || (fence_i_mem && !flush_done_i);

  // The data cache reads its arrays on the edge BEFORE an access reaches MEM,
  // so it needs that access's address now: the one leaving EX if the pipe
  // advances, or the held one if MEM is stalled.
  assign data_pre_addr_o = stall_mem ? ex_mem_q.mem_addr : mem_addr_ex;

  assign data_we_o = ex_mem_q.valid && ex_mem_q.dec.is_store &&
                     !trap_taken;

  logic wb_valid;   // WB stage retires an instruction this cycle

  csr_file u_csr_file (
    .clk_i(clk_i), .rst_ni(rst_ni),
    .addr_i(ex_mem_q.dec.imm[11:0]), .wdata_i(csr_wdata), .we_i(csr_we),
    .rdata_o(csr_rdata), .illegal_o(csr_illegal),
    .trap_i(trap_taken), .trap_cause_i(trap_cause),
    .trap_pc_i(ex_mem_q.pc),
    .trap_val_i(trap_tval), .mret_i(mret_taken),
    .tvec_o(mtvec), .epc_o(mepc), .insn_retired_i(wb_valid), .stall_i(stall_mem)
  );

  // ---- Load data extraction ----
  logic [31:0] load_data;
  logic [7:0]  load_byte;
  logic [15:0] load_half;
  assign load_byte = data_rdata_i[8*ex_mem_q.mem_addr[1:0] +: 8];
  assign load_half = ex_mem_q.mem_addr[1] ? data_rdata_i[31:16] : data_rdata_i[15:0];
  always_comb begin
    unique case (ex_mem_q.dec.funct3)
      F3_LB:   load_data = {{24{load_byte[7]}},  load_byte};
      F3_LBU:  load_data = {24'b0,               load_byte};
      F3_LH:   load_data = {{16{load_half[15]}}, load_half};
      F3_LHU:  load_data = {16'b0,               load_half};
      default: load_data = data_rdata_i;
    endcase
  end

  // ---- Writeback value selection ----
  logic [31:0] wb_data_mem;
  always_comb begin
    if      (ex_mem_q.dec.is_load) wb_data_mem = load_data;
    else if (ex_mem_q.dec.is_csr)  wb_data_mem = csr_rdata;
    else                           wb_data_mem = ex_mem_q.alu_result;  // incl. link
  end

  // ---- Redirect and flush control ----
  // Trap outranks mret outranks FENCE.I outranks branch: an older instruction's decision wins.
  assign flush_trap = trap_taken || mret_taken || fence_i_done;
  assign flush_branch = take_branch_ex && !flush_trap;

  always_comb begin
    redirect_valid = 1'b1;
    if      (trap_taken)     redirect_pc = mtvec;
    else if (mret_taken)     redirect_pc = mepc;
    else if (fence_i_done)   redirect_pc = ex_mem_q.pc + 32'd4;
    else if (take_branch_ex) redirect_pc = branch_target_ex;
    else begin
      redirect_pc    = '0;
      redirect_valid = 1'b0;
    end
  end

  // ---- MEM/WB ----
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      mem_wb_q <= '0;
    end else if (stall_mem) begin
      mem_wb_q <= '0;                              // nothing retires while stalled
    end else begin
      mem_wb_q.valid   <= ex_mem_q.valid;
      mem_wb_q.pc      <= ex_mem_q.pc;
      mem_wb_q.insn    <= ex_mem_q.insn;
      mem_wb_q.rd_addr <= ex_mem_q.dec.rd_addr;
      // A trapping instruction writes no architectural state.
      mem_wb_q.rd_we   <= ex_mem_q.valid && ex_mem_q.dec.rd_we && !trap_taken;
      mem_wb_q.wb_data <= wb_data_mem;
      mem_wb_q.pc_next <= trap_taken ? mtvec :
                          mret_taken ? mepc  : ex_mem_q.pc_next;
      mem_wb_q.trap    <= trap_taken;
    end
  end

  // ======================================================================
  // WB - register writeback and retirement
  // ======================================================================
  assign wb_valid   = mem_wb_q.valid;
  assign wb_rd_addr = mem_wb_q.rd_addr;
  assign wb_rd_we   = mem_wb_q.valid && mem_wb_q.rd_we;
  assign wb_rd_data = mem_wb_q.wb_data;

  logic [63:0] order_q;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni)       order_q <= 64'd0;
    else if (wb_valid) order_q <= order_q + 64'd1;
  end

  // RVFI requires rd_wdata to read zero whenever rd_addr is zero, because
  // writes to x0 are discarded - `ret` computes a link address purely to throw
  // it away, and reporting it would diverge from any reference model.
  logic rvfi_rd_write;
  assign rvfi_rd_write = wb_rd_we && (mem_wb_q.rd_addr != 5'd0);

  assign rvfi_valid_o    = wb_valid;
  assign rvfi_order_o    = order_q;
  assign rvfi_insn_o     = mem_wb_q.insn;
  assign rvfi_trap_o     = mem_wb_q.trap;
  assign rvfi_rd_addr_o  = rvfi_rd_write ? mem_wb_q.rd_addr : 5'd0;
  assign rvfi_rd_wdata_o = rvfi_rd_write ? mem_wb_q.wb_data : 32'd0;
  assign rvfi_pc_rdata_o = mem_wb_q.pc;
  assign rvfi_pc_wdata_o = mem_wb_q.pc_next;

endmodule
