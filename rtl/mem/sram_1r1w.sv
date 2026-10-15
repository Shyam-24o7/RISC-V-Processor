// Simple dual-port RAM: one synchronous read port, one write port with
// independently enabled lanes. Coded in the form Vivado maps to block RAM;
// every cache tag and data array is built from it.
//
// Read-during-write to the SAME address returns the OLD contents in this
// model. Block RAM collision behaviour depends on its configured mode, so the
// caches never rely on it: they detect the collision and read again.
module sram_1r1w #(
  parameter int DEPTH = 128,
  parameter int WIDTH = 128,
  parameter int LANES = 16          // WIDTH must be a multiple of LANES
) (
  input  logic                     clk_i,

  input  logic [$clog2(DEPTH)-1:0] rd_addr_i,
  output logic [WIDTH-1:0]         rd_data_o,   // the cycle after rd_addr_i

  input  logic                     wr_en_i,
  input  logic [$clog2(DEPTH)-1:0] wr_addr_i,
  input  logic [LANES-1:0]         wr_lanes_i,
  input  logic [WIDTH-1:0]         wr_data_i
);

  localparam int LW = WIDTH / LANES;

  (* ram_style = "block" *) logic [WIDTH-1:0] mem [DEPTH];

  always_ff @(posedge clk_i) begin
    if (wr_en_i) begin
      for (int l = 0; l < LANES; l++) begin
        if (wr_lanes_i[l]) mem[wr_addr_i][l*LW +: LW] <= wr_data_i[l*LW +: LW];
      end
    end
    rd_data_o <= mem[rd_addr_i];
  end

endmodule
