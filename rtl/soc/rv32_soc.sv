// The cached core complex: the five-stage pipeline, its L1 instruction and
// data caches, and the arbiter that shares one line port between them.
//
//   core --instr--> icache --+
//                            +--> mem_arbiter --line port--> (main memory)
//   core --data---> dcache --+
//
// Main memory attaches outside, so this module is exactly what is
// synthesised. FENCE.I is sequenced here: the data cache writes back every
// dirty line first, and only then does the instruction cache invalidate - so
// any refill after the invalidation reads the freshly written instructions.
module rv32_soc #(
  parameter logic [31:0] BOOT_ADDR = 32'h8000_0000,
  parameter int          SETS      = 128
) (
  input  logic         clk_i,
  input  logic         rst_ni,

  output logic         mem_req_o,
  output logic         mem_we_o,
  output logic [27:0]  mem_addr_o,
  output logic [127:0] mem_wdata_o,
  input  logic         mem_ready_i,
  input  logic [127:0] mem_rdata_i,

  output logic         rvfi_valid_o,
  output logic [63:0]  rvfi_order_o,
  output logic [31:0]  rvfi_insn_o,
  output logic         rvfi_trap_o,
  output logic [4:0]   rvfi_rd_addr_o,
  output logic [31:0]  rvfi_rd_wdata_o,
  output logic [31:0]  rvfi_pc_rdata_o,
  output logic [31:0]  rvfi_pc_wdata_o,

  output logic         ic_hit_o,
  output logic         ic_miss_o,
  output logic         dc_hit_o,
  output logic         dc_miss_o,
  output logic         bp_branch_o,      // resolved branch or jump
  output logic         bp_mispredict_o   // branch prediction was wrong
);

  // core <-> instruction cache
  logic        i_req, i_gnt, i_rvalid;
  logic [31:0] i_addr, i_rdata;

  // core <-> data cache
  logic        d_req, d_we, d_ready;
  logic [3:0]  d_be;
  logic [31:0] d_addr, d_wdata, d_rdata, d_pre_addr;

  // FENCE.I sequencing
  logic        fl_req, dc_fl_done, ic_inv_done;

  // caches <-> arbiter
  logic         ic_m_req, ic_m_we, ic_m_ready, dc_m_req, dc_m_we, dc_m_ready;
  logic [27:0]  ic_m_addr, dc_m_addr;
  logic [127:0] ic_m_wdata, ic_m_rdata, dc_m_wdata, dc_m_rdata;

  core_rv32i_p5 #(.BOOT_ADDR(BOOT_ADDR)) u_core (
    .clk_i(clk_i), .rst_ni(rst_ni),
    .instr_req_o(i_req), .instr_addr_o(i_addr), .instr_rdata_i(i_rdata),
    .instr_ready_i(i_rvalid), .instr_gnt_i(i_gnt),
    .data_req_o(d_req), .data_addr_o(d_addr), .data_we_o(d_we), .data_be_o(d_be),
    .data_wdata_o(d_wdata), .data_rdata_i(d_rdata), .data_ready_i(d_ready),
    .data_pre_addr_o(d_pre_addr), .flush_req_o(fl_req), .flush_done_i(ic_inv_done),
    .stat_branch_o(bp_branch_o), .stat_mispredict_o(bp_mispredict_o),
    .rvfi_valid_o(rvfi_valid_o), .rvfi_order_o(rvfi_order_o), .rvfi_insn_o(rvfi_insn_o),
    .rvfi_trap_o(rvfi_trap_o), .rvfi_rd_addr_o(rvfi_rd_addr_o),
    .rvfi_rd_wdata_o(rvfi_rd_wdata_o), .rvfi_pc_rdata_o(rvfi_pc_rdata_o),
    .rvfi_pc_wdata_o(rvfi_pc_wdata_o)
  );

  icache #(.SETS(SETS)) u_icache (
    .clk_i(clk_i), .rst_ni(rst_ni),
    .req_i(i_req), .addr_i(i_addr), .gnt_o(i_gnt), .rvalid_o(i_rvalid), .rdata_o(i_rdata),
    .inv_req_i(fl_req && dc_fl_done), .inv_done_o(ic_inv_done),
    .mem_req_o(ic_m_req), .mem_we_o(ic_m_we), .mem_addr_o(ic_m_addr),
    .mem_wdata_o(ic_m_wdata), .mem_ready_i(ic_m_ready), .mem_rdata_i(ic_m_rdata),
    .stat_hit_o(ic_hit_o), .stat_miss_o(ic_miss_o)
  );

  dcache #(.SETS(SETS)) u_dcache (
    .clk_i(clk_i), .rst_ni(rst_ni),
    .req_i(d_req), .addr_i(d_addr), .we_i(d_we), .be_i(d_be), .wdata_i(d_wdata),
    .ready_o(d_ready), .rdata_o(d_rdata), .pre_addr_i(d_pre_addr),
    .flush_req_i(fl_req), .flush_done_o(dc_fl_done),
    .mem_req_o(dc_m_req), .mem_we_o(dc_m_we), .mem_addr_o(dc_m_addr),
    .mem_wdata_o(dc_m_wdata), .mem_ready_i(dc_m_ready), .mem_rdata_i(dc_m_rdata),
    .stat_hit_o(dc_hit_o), .stat_miss_o(dc_miss_o)
  );

  mem_arbiter u_arbiter (
    .clk_i(clk_i), .rst_ni(rst_ni),
    .i_req_i(ic_m_req), .i_we_i(ic_m_we), .i_addr_i(ic_m_addr), .i_wdata_i(ic_m_wdata),
    .i_ready_o(ic_m_ready), .i_rdata_o(ic_m_rdata),
    .d_req_i(dc_m_req), .d_we_i(dc_m_we), .d_addr_i(dc_m_addr), .d_wdata_i(dc_m_wdata),
    .d_ready_o(dc_m_ready), .d_rdata_o(dc_m_rdata),
    .m_req_o(mem_req_o), .m_we_o(mem_we_o), .m_addr_o(mem_addr_o),
    .m_wdata_o(mem_wdata_o), .m_ready_i(mem_ready_i), .m_rdata_i(mem_rdata_i)
  );

endmodule
