// Checks the read latency, lane-masked writes, and the documented collision
// behaviour of the cache RAM template.
module tb_sram_1r1w;
  logic clk = 0;
  int   errors = 0;
  always #5 clk = ~clk;

  logic [3:0]  ra, wa;
  logic [31:0] rd, wd;
  logic        we;
  logic [3:0]  lanes;

  sram_1r1w #(.DEPTH(16), .WIDTH(32), .LANES(4)) dut (
    .clk_i(clk), .rd_addr_i(ra), .rd_data_o(rd),
    .wr_en_i(we), .wr_addr_i(wa), .wr_lanes_i(lanes), .wr_data_i(wd)
  );

  task automatic chk(string name, logic [31:0] got, exp);
    if (got !== exp) begin
      $display("FAIL %s: got 0x%08x expected 0x%08x", name, got, exp);
      errors++;
    end
  endtask

  task automatic write(logic [3:0] a, logic [3:0] l, logic [31:0] d);
    @(negedge clk); we = 1; wa = a; lanes = l; wd = d;
    @(negedge clk); we = 0;
  endtask

  // Present an address, then sample after the next edge.
  task automatic read(logic [3:0] a, output logic [31:0] d);
    @(negedge clk); ra = a;
    @(negedge clk); d = rd;
  endtask

  logic [31:0] v;

  initial begin
    we = 0; ra = 0; wa = 0; lanes = 0; wd = 0;

    write(4'd3, 4'b1111, 32'hDEAD_BEEF);
    read(4'd3, v);  chk("full write then read", v, 32'hDEAD_BEEF);

    write(4'd3, 4'b0010, 32'h0000_AA00);
    read(4'd3, v);  chk("one lane written", v, 32'hDEAD_AAEF);

    write(4'd3, 4'b1001, 32'h1100_0022);
    read(4'd3, v);  chk("two outer lanes", v, 32'h11AD_AA22);

    write(4'd7, 4'b1111, 32'h7777_7777);
    read(4'd3, v);  chk("other address untouched", v, 32'h11AD_AA22);

    // Same-address read during write returns the OLD contents. The caches
    // are designed never to depend on this, but the model must state it.
    @(negedge clk); ra = 4'd7; we = 1; wa = 4'd7; lanes = 4'b1111; wd = 32'h8888_8888;
    @(negedge clk); we = 0;
    chk("read-during-write returns old data", rd, 32'h7777_7777);
    @(negedge clk);
    chk("next read returns new data", rd, 32'h8888_8888);

    if (errors == 0) $display("PASS tb_sram_1r1w");
    else             $fatal(1, "%0d failures", errors);
    $finish;
  end
endmodule
