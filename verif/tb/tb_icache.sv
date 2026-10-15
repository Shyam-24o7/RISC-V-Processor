// Every accepted request must get exactly one response, in order, carrying
// the instruction at its address. Memory holds each word's own byte address
// as data, so a response paired with the wrong request is visible at once.
module tb_icache;
  localparam int LAT   = 3;
  localparam int SETS  = 128;
  localparam int WAY_B = SETS * 16;      // bytes per way
  localparam int N     = 4000;           // random-phase requests

  logic clk = 0, rst_n = 0;
  int   errors = 0;
  always #5 clk = ~clk;

  logic         req, gnt, rvalid, inv_req, inv_done;
  logic [31:0]  addr, rdata;
  logic         m_req, m_we, m_ready, s_hit, s_miss;
  logic [27:0]  m_addr;
  logic [127:0] m_wdata, m_rdata;

  icache #(.SETS(SETS)) dut (
    .clk_i(clk), .rst_ni(rst_n),
    .req_i(req), .addr_i(addr), .gnt_o(gnt), .rvalid_o(rvalid), .rdata_o(rdata),
    .inv_req_i(inv_req), .inv_done_o(inv_done),
    .mem_req_o(m_req), .mem_we_o(m_we), .mem_addr_o(m_addr), .mem_wdata_o(m_wdata),
    .mem_ready_i(m_ready), .mem_rdata_i(m_rdata),
    .stat_hit_o(s_hit), .stat_miss_o(s_miss)
  );

  main_mem #(.WORDS(65536), .LATENCY(LAT)) mem (
    .clk_i(clk), .rst_ni(rst_n), .req_i(m_req), .we_i(m_we), .addr_i(m_addr),
    .wdata_i(m_wdata), .ready_o(m_ready), .rdata_o(m_rdata)
  );

  // Expected data for the request being presented: its own address, unless a
  // directed test overrides it.
  logic        use_ovr = 0;
  logic [31:0] ovr, cur_exp;
  assign cur_exp = use_ovr ? ovr : addr;

  // ---- scoreboard ----
  logic [31:0] exp_q [16384];
  int exp_wr = 0, exp_rd = 0, hits = 0, misses = 0;
  always @(posedge clk) begin
    if (rst_n) begin
      if (rvalid) begin
        if (exp_rd >= exp_wr) begin
          $display("FAIL response with no request outstanding"); errors++;
        end else if (rdata !== exp_q[exp_rd]) begin
          $display("FAIL response %0d: got 0x%08x expected 0x%08x", exp_rd, rdata, exp_q[exp_rd]);
          errors++;
        end
        exp_rd++;
      end
      if (req && gnt) begin exp_q[exp_wr] = cur_exp; exp_wr++; end
      if (s_hit)  hits++;
      if (s_miss) misses++;
      if (inv_req && gnt) begin $display("FAIL gnt high during invalidation"); errors++; end
    end
  end

  task automatic chk(string name, int got, int exp);
    if (got != exp) begin $display("FAIL %s: got %0d expected %0d", name, got, exp); errors++; end
  endtask

  // One directed fetch with an explicit expected value.
  task automatic fetch(logic [31:0] a, logic [31:0] e);
    @(negedge clk); use_ovr = 1; ovr = e; addr = a; req = 1;
    #1; while (!gnt) begin @(negedge clk); #1; end
    @(negedge clk); req = 0;
    wait (exp_rd == exp_wr);
    use_ovr = 0;
  endtask

  // ---- random phase driver: like the fetch unit, the address advances only
  // when a request is accepted; req itself comes and goes ----
  logic rand_on = 0;
  int   accepted = 0;
  always @(posedge clk) begin
    if (rand_on && req && gnt) begin
      accepted++;
      if ($urandom_range(0, 7) == 0)
        addr <= 32'($urandom_range(0, (4 * WAY_B / 4) - 1)) << 2;   // jump within 4 ways
      else
        addr <= addr + 32'd4;
    end
  end
  always @(negedge clk) if (rand_on) req = ($urandom_range(0, 4) != 0);

  initial begin
    req = 0; addr = 0; inv_req = 0; ovr = 0;
    #1;   // after main_mem's own initial fill
    for (int w = 0; w < 65536; w++) mem.mem[w] = 32'(w) << 2;
    repeat (2) @(negedge clk); rst_n = 1;

    // ---- miss then hit in the same line ----
    fetch(32'h40, 32'h40);
    chk("first fetch misses", misses, 1);
    fetch(32'h44, 32'h44);
    chk("same line hits", hits, 1);
    chk("still one miss", misses, 1);

    // ---- it really is a cache: memory changes, the cached copy does not ----
    mem.mem[32'h40 >> 2] = 32'hDEAD_BEEF;
    fetch(32'h40, 32'h40);

    // ---- FENCE.I invalidation makes the new contents visible ----
    @(negedge clk); inv_req = 1;
    #1; while (!inv_done) begin @(negedge clk); #1; end
    @(negedge clk); inv_req = 0;
    fetch(32'h40, 32'hDEAD_BEEF);
    mem.mem[32'h40 >> 2] = 32'h40;     // restore for the random phase
    @(negedge clk); inv_req = 1;
    #1; while (!inv_done) begin @(negedge clk); #1; end
    @(negedge clk); inv_req = 0;

    // ---- random: sequential runs, jumps, conflicts across 4 ways' worth ----
    @(negedge clk); addr = 32'h0; req = 1; rand_on = 1;
    wait (accepted >= N);
    @(negedge clk); rand_on = 0; req = 0;
    wait (exp_rd == exp_wr);

    if (hits == 0 || misses < 2) begin $display("FAIL random phase did not exercise both paths"); errors++; end
    $display("icache: %0d requests, %0d hits, %0d misses", exp_wr, hits, misses);
    if (errors == 0) $display("PASS tb_icache");
    else             $fatal(1, "%0d failures", errors);
    $finish;
  end

  initial begin #5000000; $fatal(1, "GLOBAL TIMEOUT"); end
endmodule
