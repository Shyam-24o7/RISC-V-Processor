// Drives the data cache exactly as the pipeline does: an access sits in MEM
// until ready, and pre_addr names the access that will be in MEM next cycle
// (the held address while stalled). Every load is checked against a flat
// reference memory; after each flush, main memory itself must equal it.
module tb_dcache;
  localparam int LAT    = 3;
  localparam int SETS   = 128;
  localparam int WAY_B  = SETS * 16;          // bytes per way (2 KiB)
  localparam int RWORDS = 8 * WAY_B / 4;      // checked region: 8 tags of every set
  localparam int RW     = $clog2(RWORDS);
  localparam int NOPS   = 8000;

  logic clk = 0, rst_n = 0;
  int   errors = 0;
  always #5 clk = ~clk;

  logic         req, we, ready, fl_req, fl_done;
  logic [3:0]   be;
  logic [31:0]  addr, wdata, rdata, pre_addr;
  logic         m_req, m_we, m_ready, s_hit, s_miss;
  logic [27:0]  m_addr;
  logic [127:0] m_wdata, m_rdata;

  dcache #(.SETS(SETS)) dut (
    .clk_i(clk), .rst_ni(rst_n),
    .req_i(req), .addr_i(addr), .we_i(we), .be_i(be), .wdata_i(wdata),
    .ready_o(ready), .rdata_o(rdata), .pre_addr_i(pre_addr),
    .flush_req_i(fl_req), .flush_done_o(fl_done),
    .mem_req_o(m_req), .mem_we_o(m_we), .mem_addr_o(m_addr), .mem_wdata_o(m_wdata),
    .mem_ready_i(m_ready), .mem_rdata_i(m_rdata),
    .stat_hit_o(s_hit), .stat_miss_o(s_miss)
  );

  main_mem #(.WORDS(65536), .LATENCY(LAT)) mem (
    .clk_i(clk), .rst_ni(rst_n), .req_i(m_req), .we_i(m_we), .addr_i(m_addr),
    .wdata_i(m_wdata), .ready_o(m_ready), .rdata_o(m_rdata)
  );

  // ---- the access stream ----
  typedef struct packed {
    logic        is_acc;     // 0 = an idle cycle (non-memory instruction in MEM)
    logic        we;
    logic [3:0]  be;
    logic [31:0] addr;
    logic [31:0] wdata;
  } acc_t;

  acc_t ops [NOPS];
  int   nops = 0, head = 0;
  logic running = 0;
  acc_t cur, nxt;

  always_comb begin
    cur = (running && head < nops)     ? ops[head]     : '0;
    // Before the stream starts, the next access to enter MEM is ops[head].
    nxt = (running && head + 1 < nops) ? ops[head + 1] :
          (!running && head < nops)    ? ops[head]     : '0;
    req = cur.is_acc; we = cur.we; be = cur.be; addr = cur.addr; wdata = cur.wdata;
    // The pipeline's contract: the next access's address, or the held one.
    pre_addr = (req && !ready) ? cur.addr : nxt.addr;
  end

  // ---- reference model and scoreboard ----
  logic [31:0] ref_mem [RWORDS];
  int hits = 0, misses = 0;
  always @(posedge clk) begin
    if (s_hit)  hits++;
    if (s_miss) misses++;
    if (running && head < nops) begin
      if (!cur.is_acc) begin
        head <= head + 1;
      end else if (ready) begin
        head <= head + 1;
        if (cur.we) begin
          for (int b = 0; b < 4; b++)
            if (cur.be[b]) ref_mem[cur.addr[2 +: RW]][8*b +: 8] = cur.wdata[8*b +: 8];
        end else if (rdata !== ref_mem[cur.addr[2 +: RW]]) begin
          $display("FAIL op %0d load 0x%08x: got 0x%08x expected 0x%08x",
                   head, cur.addr, rdata, ref_mem[cur.addr[2 +: RW]]);
          errors++;
        end
      end
    end
  end

  function automatic logic [31:0] A(int tagn, int set, int word);
    return 32'(tagn * WAY_B + set * 16 + word * 4);
  endfunction

  task automatic push(logic is_acc, logic w, logic [3:0] b, logic [31:0] a, logic [31:0] d);
    ops[nops] = {is_acc, w, b, a, d};
    nops++;
  endtask

  task automatic run_ops();
    @(negedge clk); running = 1;
    wait (head == nops);
    @(negedge clk); running = 0;
  endtask

  task automatic flush();
    @(negedge clk); fl_req = 1;
    #1; while (!fl_done) begin @(negedge clk); #1; end
    @(negedge clk); fl_req = 0;
    @(negedge clk);
  endtask

  task automatic check_memory(string when);
    int bad;
    bad = 0;
    for (int w = 0; w < RWORDS; w++) begin
      if (mem.mem[w] !== ref_mem[w]) begin
        if (bad < 5)
          $display("FAIL %s: memory 0x%05x = 0x%08x, expected 0x%08x",
                   when, w * 4, mem.mem[w], ref_mem[w]);
        bad++;
      end
    end
    errors += bad;
  endtask

  int m0;

  initial begin
    fl_req = 0;
    #1;   // after main_mem's own initial fill
    for (int w = 0; w < RWORDS; w++) begin
      mem.mem[w] = (32'(w) * 32'h9E37_79B9) ^ 32'h5A5A_0000;
      ref_mem[w] = mem.mem[w];
    end
    repeat (2) @(negedge clk); rst_n = 1;

    // ---- counters: a miss's completion is not also a hit ----
    push(1, 0, 4'b1111, A(3, 70, 0), 0);  // cold set
    run_ops();
    if (hits != 0 || misses != 1) begin
      $display("FAIL cold load counted %0d hits, %0d misses (want 0, 1)", hits, misses); errors++;
    end
    push(1, 0, 4'b1111, A(3, 70, 0), 0);  // same line again
    run_ops();
    if (hits != 1 || misses != 1) begin
      $display("FAIL repeated load counted %0d hits, %0d misses (want 1, 1)", hits, misses); errors++;
    end

    // ---- store, then load the same set on the very next access ----
    // The load's array read happens on the same edge as the store's write.
    push(1, 1, 4'b1111, A(0, 5, 0), 32'hAAAA_0001);
    push(1, 0, 4'b1111, A(0, 5, 0), 0);
    push(1, 1, 4'b0100, A(0, 5, 1), 32'h00BB_0000);
    push(1, 0, 4'b1111, A(0, 5, 1), 0);
    push(1, 1, 4'b0011, A(0, 5, 2), 32'h0000_CCDD);
    push(1, 0, 4'b1111, A(0, 5, 2), 0);
    // A different line in the same set, straight after a store.
    push(1, 1, 4'b1111, A(0, 5, 3), 32'h1234_5678);
    push(1, 0, 4'b1111, A(1, 5, 0), 0);
    run_ops();

    // ---- dirty eviction ----
    // Set 5 now holds tag 0 (dirty) and tag 1 (clean, most recent). A third
    // tag must evict tag 0 and write it back.
    push(1, 0, 4'b1111, A(2, 5, 0), 0);
    run_ops();
    if (mem.mem[A(0, 5, 0) >> 2] !== 32'hAAAA_0001) begin
      $display("FAIL dirty victim was not written back"); errors++;
    end

    // ---- LRU picks the least recently used way ----
    push(1, 0, 4'b1111, A(0, 9, 0), 0);   // X
    push(1, 0, 4'b1111, A(1, 9, 0), 0);   // Y
    push(1, 0, 4'b1111, A(0, 9, 0), 0);   // X again: Y is now LRU
    push(1, 0, 4'b1111, A(2, 9, 0), 0);   // Z evicts Y
    run_ops();
    m0 = misses;
    push(1, 0, 4'b1111, A(0, 9, 1), 0);   // X's line must still be there
    run_ops();
    if (misses != m0) begin $display("FAIL LRU evicted the recently used way"); errors++; end

    // ---- flush writes back every dirty line ----
    flush();
    check_memory("after first flush");

    // ---- random: 8 tags fighting over 2 ways in 4 sets, every size ----
    for (int i = 0; i < 6000; i++) begin
      int s, kind, sel;
      logic [3:0] b;
      // Drawn once: a unique case re-evaluates its selector to check matches.
      sel = $urandom_range(0, 3);
      unique case (sel)
        0: s = 0;
        1: s = 1;
        2: s = 37;
        default: s = SETS - 1;
      endcase
      kind = $urandom_range(0, 2);
      if      (kind == 0) b = 4'b0001 << $urandom_range(0, 3);
      else if (kind == 1) b = $urandom_range(0, 1) ? 4'b1100 : 4'b0011;
      else                b = 4'b1111;
      if ($urandom_range(0, 7) == 0) push(0, 0, 4'b0, 32'h0, 32'h0);
      push(1, 1'($urandom_range(0, 1)), b,
           A($urandom_range(0, 7), s, $urandom_range(0, 3)), $urandom);
    end
    run_ops();
    flush();
    check_memory("after final flush");

    $display("dcache: %0d ops, %0d hits, %0d misses", nops, hits, misses);
    if (hits == 0 || misses == 0) begin $display("FAIL a path was never exercised"); errors++; end
    if (errors == 0) $display("PASS tb_dcache");
    else             $fatal(1, "%0d failures", errors);
    $finish;
  end

  initial begin #50000000; $fatal(1, "GLOBAL TIMEOUT"); end
endmodule
