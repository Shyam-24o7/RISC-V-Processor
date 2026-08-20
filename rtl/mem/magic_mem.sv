// Zero-latency memory: address in, data out, same cycle, never stalls.
//
// This is a deliberate lie, and the correct one for a single-cycle core. Real
// memory takes cycles to answer, but a single-cycle datapath must complete
// fetch, decode, execute, memory and writeback between two clock edges - so at
// this stage memory has to reply instantly or the design cannot exist.
//
// SIMULATION ONLY. It uses $readmemh and an initial block, breaking the
// project's "no initial blocks in rtl/" rule on purpose. scripts/synth.tcl
// excludes it; an FPGA build instantiates real BRAM instead.
module magic_mem #(
  parameter int    WORDS    = 65536,
  parameter string INIT_HEX = ""
) (
  input  logic        clk_i,

  // Instruction port: read-only
  input  logic [31:0] instr_addr_i,
  output logic [31:0] instr_rdata_o,

  // Data port: read/write with byte enables
  input  logic [31:0] data_addr_i,
  input  logic        data_we_i,
  input  logic [3:0]  data_be_i,
  input  logic [31:0] data_wdata_i,
  output logic [31:0] data_rdata_o
);

  logic [31:0] mem [WORDS];

  // Only the low address bits are decoded, so a program linked at 0x80000000
  // aliases to word 0. Both ports alias identically, so it stays consistent.
  localparam int AW = $clog2(WORDS);
  logic [AW-1:0] iword, dword;
  assign iword = instr_addr_i[AW+1:2];
  assign dword = data_addr_i[AW+1:2];

  initial begin
    // NOP fill, so a runaway PC executes harmlessly rather than fetching X
    // and poisoning every downstream signal in the simulation.
    for (int i = 0; i < WORDS; i++) mem[i] = 32'h0000_0013;
    if (INIT_HEX != "") $readmemh(INIT_HEX, mem);
  end

  // Byte enables let SB and SH update part of a word without disturbing the
  // rest of it.
  always_ff @(posedge clk_i) begin
    if (data_we_i) begin
      if (data_be_i[0]) mem[dword][7:0]   <= data_wdata_i[7:0];
      if (data_be_i[1]) mem[dword][15:8]  <= data_wdata_i[15:8];
      if (data_be_i[2]) mem[dword][23:16] <= data_wdata_i[23:16];
      if (data_be_i[3]) mem[dword][31:24] <= data_wdata_i[31:24];
    end
  end

  assign instr_rdata_o = mem[iword];
  assign data_rdata_o  = mem[dword];

endmodule
