// Architectural register file: 32 x 32-bit, two read ports and one write port.
// That shape comes straight from the ISA - an R-type instruction reads rs1 and
// rs2 and writes rd, all within one instruction.
//
// Reads are asynchronous so a single-cycle datapath can read operands, compute,
// and write the result back between two clock edges.
module regfile #(
  parameter int NREG = 32
) (
  input  logic        clk_i,
  input  logic        rst_ni,
  input  logic [4:0]  rs1_addr_i,
  input  logic [4:0]  rs2_addr_i,
  input  logic [4:0]  rd_addr_i,
  input  logic        rd_we_i,
  input  logic [31:0] rd_wdata_i,
  output logic [31:0] rs1_rdata_o,
  output logic [31:0] rs2_rdata_o
);

  logic [31:0] mem [NREG];

  // x0 is hardwired to zero: it cannot hold a value, so the write is dropped
  // rather than stored. RISC-V relies on this - `ret` is `jalr x0, 0(ra)`,
  // which computes a link address purely to discard it.
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      for (int i = 0; i < NREG; i++) mem[i] <= '0;
    end else if (rd_we_i && (rd_addr_i != 5'd0)) begin
      mem[rd_addr_i] <= rd_wdata_i;
    end
  end

  // Enforced on the read ports too, independently of the write path.
  assign rs1_rdata_o = (rs1_addr_i == 5'd0) ? 32'd0 : mem[rs1_addr_i];
  assign rs2_rdata_o = (rs2_addr_i == 5'd0) ? 32'd0 : mem[rs2_addr_i];

endmodule
