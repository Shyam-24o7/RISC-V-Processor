module tb_magic_mem;
  logic        clk = 0;
  logic [31:0] iaddr, irdata, daddr, dwdata, drdata;
  logic        dwe;
  logic [3:0]  dbe;
  int          errors = 0;

  always #5 clk = ~clk;

  magic_mem #(.WORDS(256)) dut (
    .clk_i(clk),
    .instr_addr_i(iaddr), .instr_rdata_o(irdata),
    .data_addr_i(daddr), .data_we_i(dwe), .data_be_i(dbe),
    .data_wdata_i(dwdata), .data_rdata_o(drdata)
  );

  task automatic chk(string name, logic [31:0] got, exp);
    if (got !== exp) begin
      $display("FAIL %s: got 0x%08x expected 0x%08x", name, got, exp);
      errors++;
    end
  endtask

  task automatic store(logic [31:0] a, d, logic [3:0] be);
    @(negedge clk); daddr = a; dwdata = d; dbe = be; dwe = 1;
    @(negedge clk); dwe = 0;
  endtask

  initial begin
    dwe = 0; dbe = 4'hF; daddr = 0; dwdata = 0; iaddr = 0;

    daddr = 32'h20; #1;
    chk("unwritten reads as NOP", drdata, 32'h0000_0013);

    store(32'h10, 32'hDEAD_BEEF, 4'hF); daddr = 32'h10; #1;
    chk("full word", drdata, 32'hDEAD_BEEF);

    store(32'h10, 32'h0000_00AA, 4'b0001); daddr = 32'h10; #1;
    chk("byte enable keeps neighbours", drdata, 32'hDEAD_BEAA);

    store(32'h10, 32'h1234_0000, 4'b1100); daddr = 32'h10; #1;
    chk("halfword enable", drdata, 32'h1234_BEAA);

    iaddr = 32'h10; #1;
    chk("instruction port sees same array", irdata, 32'h1234_BEAA);

    daddr = 32'h14; #1;
    chk("adjacent word untouched", drdata, 32'h0000_0013);

    // The high address bits are ignored, so 0x80000010 aliases to 0x10.
    daddr = 32'h8000_0010; #1;
    chk("high bits alias", drdata, 32'h1234_BEAA);

    if (errors == 0) $display("PASS tb_magic_mem");
    else             $fatal(1, "%0d failures", errors);
    $finish;
  end
endmodule
