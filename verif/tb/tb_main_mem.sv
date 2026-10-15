// Latency must be exact (it is the knob every measurement turns), lines must
// be assembled little-endian from four words, and a write must land once.
module tb_main_mem;
  logic clk = 0, rst_n = 0;
  int   errors = 0;
  always #5 clk = ~clk;

  logic         req, we;
  logic [27:0]  addr;
  logic [127:0] wdata;
  logic         rdy0, rdy1, rdy4;
  logic [127:0] rd0, rd1, rd4;

  main_mem #(.WORDS(1024), .LATENCY(0)) m0 (.clk_i(clk), .rst_ni(rst_n),
    .req_i(req), .we_i(we), .addr_i(addr), .wdata_i(wdata), .ready_o(rdy0), .rdata_o(rd0));
  main_mem #(.WORDS(1024), .LATENCY(1)) m1 (.clk_i(clk), .rst_ni(rst_n),
    .req_i(req), .we_i(we), .addr_i(addr), .wdata_i(wdata), .ready_o(rdy1), .rdata_o(rd1));
  main_mem #(.WORDS(1024), .LATENCY(4)) m4 (.clk_i(clk), .rst_ni(rst_n),
    .req_i(req), .we_i(we), .addr_i(addr), .wdata_i(wdata), .ready_o(rdy4), .rdata_o(rd4));

  task automatic chk(string name, logic [127:0] got, exp);
    if (got !== exp) begin
      $display("FAIL %s: got 0x%032x expected 0x%032x", name, got, exp);
      errors++;
    end
  endtask

  // Hold a request on all three memories; report the cycle each one is ready.
  int c0, c1, c4;
  task automatic access(logic w, logic [27:0] a, logic [127:0] d);
    int c;
    c0 = -1; c1 = -1; c4 = -1; c = 0;
    @(negedge clk); req = 1; we = w; addr = a; wdata = d;
    while (c4 < 0) begin
      #1;
      if (rdy0 && c0 < 0) c0 = c;
      if (rdy1 && c1 < 0) c1 = c;
      if (rdy4 && c4 < 0) c4 = c;
      @(negedge clk); c++;
      if (c > 20) begin $display("FAIL no ready"); errors++; break; end
    end
    req = 0; we = 0;
    @(negedge clk);
  endtask

  initial begin
    req = 0; we = 0; addr = 0; wdata = 0;
    #1;
    for (int i = 0; i < 16; i++) begin
      m0.mem[i] = 32'h1000_0000 + i; m1.mem[i] = 32'h1000_0000 + i; m4.mem[i] = 32'h1000_0000 + i;
    end
    repeat (2) @(negedge clk); rst_n = 1;

    access(1'b0, 28'd1, '0);
    chk("latency 0 ready same cycle", 128'(c0), 128'd0);
    chk("latency 1 ready after 1",    128'(c1), 128'd1);
    chk("latency 4 ready after 4",    128'(c4), 128'd4);
    chk("line 1 = words 4..7, little-endian", m4.rdata_o,
        {32'h1000_0007, 32'h1000_0006, 32'h1000_0005, 32'h1000_0004});

    access(1'b1, 28'd2, {32'hD3, 32'hD2, 32'hD1, 32'hD0});
    chk("write landed (latency 4)", {m4.mem[11], m4.mem[10], m4.mem[9], m4.mem[8]},
        {32'hD3, 32'hD2, 32'hD1, 32'hD0});
    chk("write landed (latency 0)", {m0.mem[11], m0.mem[10], m0.mem[9], m0.mem[8]},
        {32'hD3, 32'hD2, 32'hD1, 32'hD0});
    chk("neighbour line untouched", 128'(m4.mem[12]), 128'h1000_000C);

    // Back-to-back requests each pay the full latency again.
    access(1'b0, 28'd0, '0);
    chk("second access pays full latency", 128'(c4), 128'd4);

    if (errors == 0) $display("PASS tb_main_mem");
    else             $fatal(1, "%0d failures", errors);
    $finish;
  end
endmodule
