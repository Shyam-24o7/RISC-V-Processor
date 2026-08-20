module tb_regfile;
  logic        clk = 0, rst_n = 0;
  logic [4:0]  rs1_addr, rs2_addr, rd_addr;
  logic        rd_we;
  logic [31:0] rd_wdata, rs1_rdata, rs2_rdata;
  int          errors = 0;

  always #5 clk = ~clk;

  regfile dut (
    .clk_i(clk), .rst_ni(rst_n),
    .rs1_addr_i(rs1_addr), .rs2_addr_i(rs2_addr),
    .rd_addr_i(rd_addr), .rd_we_i(rd_we), .rd_wdata_i(rd_wdata),
    .rs1_rdata_o(rs1_rdata), .rs2_rdata_o(rs2_rdata)
  );

  task automatic wr(logic [4:0] a, logic [31:0] d);
    @(negedge clk); rd_addr = a; rd_wdata = d; rd_we = 1;
    @(negedge clk); rd_we = 0;
  endtask

  task automatic chk(string name, logic [31:0] got, exp);
    if (got !== exp) begin
      $display("FAIL %s: got 0x%08x expected 0x%08x", name, got, exp);
      errors++;
    end
  endtask

  initial begin
    rd_we = 0; rs1_addr = 0; rs2_addr = 0; rd_addr = 0; rd_wdata = 0;
    repeat (2) @(negedge clk); rst_n = 1;

    wr(5'd1, 32'hDEAD_BEEF);
    rs1_addr = 5'd1; #1;
    chk("write then read x1", rs1_rdata, 32'hDEAD_BEEF);

    // x0 must stay zero even when explicitly written.
    wr(5'd0, 32'hFFFF_FFFF);
    rs1_addr = 5'd0; #1;
    chk("x0 read port 1", rs1_rdata, 32'd0);
    rs2_addr = 5'd0; #1;
    chk("x0 read port 2", rs2_rdata, 32'd0);

    // Both ports read independently and simultaneously.
    wr(5'd2, 32'h1234_5678);
    rs1_addr = 5'd1; rs2_addr = 5'd2; #1;
    chk("port 1 independent", rs1_rdata, 32'hDEAD_BEEF);
    chk("port 2 independent", rs2_rdata, 32'h1234_5678);

    // Same register on both ports at once.
    rs1_addr = 5'd2; rs2_addr = 5'd2; #1;
    chk("same reg both ports", rs1_rdata, 32'h1234_5678);
    chk("same reg both ports", rs2_rdata, 32'h1234_5678);

    // No write when the enable is low.
    @(negedge clk); rd_addr = 5'd1; rd_wdata = 32'd0; rd_we = 0;
    @(negedge clk); rs1_addr = 5'd1; #1;
    chk("no write when we low", rs1_rdata, 32'hDEAD_BEEF);

    // Highest register works (catches an off-by-one in the address decode).
    wr(5'd31, 32'hCAFE_BABE);
    rs1_addr = 5'd31; #1;
    chk("x31", rs1_rdata, 32'hCAFE_BABE);

    if (errors == 0) $display("PASS tb_regfile");
    else             $fatal(1, "%0d failures", errors);
    $finish;
  end
endmodule
