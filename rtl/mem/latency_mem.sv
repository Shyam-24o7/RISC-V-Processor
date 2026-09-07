// Memory with a configurable access latency and a ready handshake.
//
// magic_mem answers combinationally and never stalls, which is the right lie
// for bringing a core up but hides the single most important fact about real
// systems: memory is slow. This model tells the truth instead. A request is
// held by the core until `ready` rises, LATENCY cycles later.
//
// Why this matters for comparing microarchitectures: with magic_mem, memory
// access costs nothing and sits outside every synthesised path, which flatters
// a single-cycle core enormously - it appears able to fetch an instruction AND
// access data inside one clock period. Real memory forces that cost into the
// open, and a pipelined design absorbs it far better because its stages are
// already separated.
//
// LATENCY counts WAIT STATES, so an access takes LATENCY+1 cycles. 0 reproduces
// magic_mem exactly (ready always high) and is the control for the sweep.
// Defining it as "cycles to ready" instead makes 0 and 1 measure identically,
// which silently wastes a data point.
//
// SIMULATION ONLY: uses $readmemh and an initial block.
module latency_mem #(
  parameter int    WORDS    = 65536,
  parameter int    LATENCY  = 1,      // WAIT STATES: ready after N idle cycles
  parameter string INIT_HEX = ""
) (
  input  logic        clk_i,
  input  logic        rst_ni,

  // Instruction port (read only)
  input  logic        instr_req_i,
  input  logic [31:0] instr_addr_i,
  output logic [31:0] instr_rdata_o,
  output logic        instr_ready_o,

  // Data port
  input  logic        data_req_i,
  input  logic [31:0] data_addr_i,
  input  logic        data_we_i,
  input  logic [3:0]  data_be_i,
  input  logic [31:0] data_wdata_i,
  output logic [31:0] data_rdata_o,
  output logic        data_ready_o
);

  logic [31:0] mem [WORDS];

  localparam int AW = $clog2(WORDS);
  logic [AW-1:0] iword, dword;
  assign iword = instr_addr_i[AW+1:2];
  assign dword = data_addr_i[AW+1:2];

  initial begin
    for (int i = 0; i < WORDS; i++) mem[i] = 32'h0000_0013;   // NOP fill
    if (INIT_HEX != "") $readmemh(INIT_HEX, mem);
  end

  // ---- Latency counters -------------------------------------------------
  // Each port counts cycles while a request is outstanding and asserts ready
  // on the LATENCY'th one. The counter clears on the handshake so a
  // back-to-back request pays the full cost again, which is what an
  // uncached memory does.
  generate
    if (LATENCY == 0) begin : g_zero_latency
      assign instr_ready_o = 1'b1;
      assign data_ready_o  = 1'b1;
    end else begin : g_counted_latency
      localparam int CW = $clog2(LATENCY + 2);
      logic [CW-1:0] icnt_q, dcnt_q;

      always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
          icnt_q <= '0;
        end else if (instr_req_i && !instr_ready_o) begin
          icnt_q <= icnt_q + 1'b1;
        end else begin
          icnt_q <= '0;                       // handshake done, or no request
        end
      end

      always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
          dcnt_q <= '0;
        end else if (data_req_i && !data_ready_o) begin
          dcnt_q <= dcnt_q + 1'b1;
        end else begin
          dcnt_q <= '0;
        end
      end

      assign instr_ready_o = instr_req_i && (icnt_q == CW'(LATENCY));
      assign data_ready_o  = data_req_i  && (dcnt_q == CW'(LATENCY));
    end
  endgenerate

  // ---- Array access -----------------------------------------------------
  // The write commits only on the handshake cycle, so a request held across
  // several stall cycles is not applied repeatedly.
  always_ff @(posedge clk_i) begin
    if (data_req_i && data_ready_o && data_we_i) begin
      if (data_be_i[0]) mem[dword][7:0]   <= data_wdata_i[7:0];
      if (data_be_i[1]) mem[dword][15:8]  <= data_wdata_i[15:8];
      if (data_be_i[2]) mem[dword][23:16] <= data_wdata_i[23:16];
      if (data_be_i[3]) mem[dword][31:24] <= data_wdata_i[31:24];
    end
  end

  assign instr_rdata_o = mem[iword];
  assign data_rdata_o  = mem[dword];

endmodule
