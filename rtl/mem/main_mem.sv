// Main memory behind the caches. Serves whole 16-byte lines over the line
// port, LATENCY wait states after a request: an access takes LATENCY+1
// cycles, and 0 answers in the same cycle. That is the same meaning
// latency_mem gives LATENCY, so cached and uncached runs compare directly.
//
// Stored as 32-bit words, so the existing one-word-per-line hex files load
// unchanged; a line is four consecutive words, word 0 in the low bits.
// The write commits on the ready cycle, so a request held across wait states
// is applied once.
//
// SIMULATION ONLY: uses $readmemh and an initial block.
module main_mem #(
  parameter int    WORDS    = 65536,
  parameter int    LATENCY  = 4,      // wait states
  parameter string INIT_HEX = ""
) (
  input  logic         clk_i,
  input  logic         rst_ni,

  input  logic         req_i,
  input  logic         we_i,
  input  logic [27:0]  addr_i,        // line address: byte address [31:4]
  input  logic [127:0] wdata_i,
  output logic         ready_o,
  output logic [127:0] rdata_o
);

  localparam int AW = $clog2(WORDS);

  logic [31:0] mem [WORDS];

  initial begin
    for (int i = 0; i < WORDS; i++) mem[i] = 32'h0000_0013;   // NOP fill
    if (INIT_HEX != "") $readmemh(INIT_HEX, mem);
  end

  // Word index of the line's first word. Upper address bits alias, exactly
  // as in the other memory models.
  logic [AW-1:0] w0;
  assign w0 = {addr_i[AW-3:0], 2'b00};

  logic unused_addr;
  assign unused_addr = ^addr_i[27:AW-2];

  generate
    if (LATENCY == 0) begin : g_zero
      assign ready_o = req_i;
    end else begin : g_wait
      localparam int CW = $clog2(LATENCY + 2);
      logic [CW-1:0] cnt_q;
      always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni)                cnt_q <= '0;
        else if (req_i && !ready_o) cnt_q <= cnt_q + CW'(1);
        else                        cnt_q <= '0;
      end
      assign ready_o = req_i && (cnt_q == CW'(LATENCY));
    end
  endgenerate

  assign rdata_o = {mem[w0 | AW'(3)], mem[w0 | AW'(2)], mem[w0 | AW'(1)], mem[w0]};

  always_ff @(posedge clk_i) begin
    if (req_i && we_i && ready_o) begin
      for (int k = 0; k < 4; k++) mem[w0 | AW'(k)] <= wdata_i[32*k +: 32];
    end
  end

endmodule
