// Two requesters hammer one memory. Each transaction must complete exactly
// once with the right data, a tie must go to the data side, and a transfer
// must never be interrupted by the other side.
module tb_mem_arbiter;
  localparam int N = 200;            // transactions per requester
  logic clk = 0, rst_n = 0;
  int   errors = 0;
  always #5 clk = ~clk;

  logic         i_req, i_ready, d_req, d_we, d_ready, m_req, m_we, m_ready;
  logic [27:0]  i_addr, d_addr, m_addr;
  logic [127:0] i_rdata, d_wdata, d_rdata, m_wdata, m_rdata;

  mem_arbiter dut (
    .clk_i(clk), .rst_ni(rst_n),
    .i_req_i(i_req), .i_we_i(1'b0), .i_addr_i(i_addr), .i_wdata_i('0),
    .i_ready_o(i_ready), .i_rdata_o(i_rdata),
    .d_req_i(d_req), .d_we_i(d_we), .d_addr_i(d_addr), .d_wdata_i(d_wdata),
    .d_ready_o(d_ready), .d_rdata_o(d_rdata),
    .m_req_o(m_req), .m_we_o(m_we), .m_addr_o(m_addr), .m_wdata_o(m_wdata),
    .m_ready_i(m_ready), .m_rdata_i(m_rdata)
  );

  main_mem #(.WORDS(4096), .LATENCY(2)) mem (
    .clk_i(clk), .rst_ni(rst_n), .req_i(m_req), .we_i(m_we), .addr_i(m_addr),
    .wdata_i(m_wdata), .ready_o(m_ready), .rdata_o(m_rdata)
  );

  function automatic logic [127:0] pattern(logic [27:0] line);
    return {32'(line) * 4 + 3, 32'(line) * 4 + 2, 32'(line) * 4 + 1, 32'(line) * 4};
  endfunction

  // Instruction side: reads lines 0..N-1 in order, random gaps.
  int i_done = 0;
  initial begin
    i_req = 0; i_addr = 0;
    wait (rst_n);
    for (int k = 0; k < N; k++) begin
      @(negedge clk); i_req = 1; i_addr = 28'(k);
      #1; while (!i_ready) begin @(negedge clk); #1; end   // completes at next edge
      if (i_rdata !== pattern(28'(k))) begin
        $display("FAIL i read line %0d", k); errors++;
      end
      i_done++;
      @(negedge clk); i_req = 0;
      repeat ($urandom_range(0, 2)) @(negedge clk);
    end
  end

  // Data side: writes a line above the instruction region, reads it back.
  int d_done = 0;
  initial begin
    d_req = 0; d_we = 0; d_addr = 0; d_wdata = 0;
    wait (rst_n);
    for (int k = 0; k < N; k++) begin
      logic [127:0] v;
      v = {$urandom, $urandom, $urandom, $urandom};
      @(negedge clk); d_req = 1; d_we = 1; d_addr = 28'(512 + k); d_wdata = v;
      #1; while (!d_ready) begin @(negedge clk); #1; end
      @(negedge clk); d_we = 0;                 // same line, now a read
      #1; while (!d_ready) begin @(negedge clk); #1; end
      if (d_rdata !== v) begin $display("FAIL d readback line %0d", 512 + k); errors++; end
      d_done++;
      @(negedge clk); d_req = 0;
      repeat ($urandom_range(0, 2)) @(negedge clk);
    end
  end

  // A transfer is never interrupted: while m_req stays high, the address the
  // memory sees must not change.
  logic        prev_req;
  logic [27:0] prev_addr;
  always_ff @(posedge clk) begin
    prev_req <= m_req && !m_ready; prev_addr <= m_addr;
    if (rst_n && prev_req && m_addr !== prev_addr) begin
      $display("FAIL transfer interrupted: addr changed mid-transaction"); errors++;
    end
  end

  initial begin
    #1;   // after main_mem's own initial fill
    for (int w = 0; w < 4096; w++) mem.mem[w] = 32'(w);   // line L word k = 4L+k
    repeat (2) @(negedge clk); rst_n = 1;
    wait (i_done == N && d_done == N);

    // Tie: both raise req in the same idle cycle -> data side first.
    @(negedge clk); i_req = 1; i_addr = 28'd3; d_req = 1; d_we = 0; d_addr = 28'd600;
    #1 if (m_addr !== 28'd600) begin $display("FAIL tie not given to data side"); errors++; end
    while (!d_ready) begin @(negedge clk); #1; end
    @(negedge clk); d_req = 0;
    #1; while (!i_ready) begin @(negedge clk); #1; end
    @(negedge clk); i_req = 0;

    if (errors == 0) $display("PASS tb_mem_arbiter");
    else             $fatal(1, "%0d failures", errors);
    $finish;
  end

  initial begin #2000000; $fatal(1, "GLOBAL TIMEOUT"); end
endmodule
