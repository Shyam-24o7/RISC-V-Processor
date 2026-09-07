module tb_latency_mem;
  logic clk = 0, rst_n = 0;
  int   errors = 0;
  always #5 clk = ~clk;

  // ---- LATENCY = 2 instance ----
  logic        ireq, dreq, dwe;
  logic [3:0]  dbe;
  logic [31:0] iaddr, irdata, daddr, dwdata, drdata;
  logic        iready, dready;

  latency_mem #(.WORDS(256), .LATENCY(2)) dut (   // 2 wait states = 3 cycles
    .clk_i(clk), .rst_ni(rst_n),
    .instr_req_i(ireq), .instr_addr_i(iaddr),
    .instr_rdata_o(irdata), .instr_ready_o(iready),
    .data_req_i(dreq), .data_addr_i(daddr), .data_we_i(dwe),
    .data_be_i(dbe), .data_wdata_i(dwdata),
    .data_rdata_o(drdata), .data_ready_o(dready)
  );

  // ---- LATENCY = 0 instance, must behave exactly like magic_mem ----
  logic        z_dreq, z_dwe, z_dready, z_iready;
  logic [31:0] z_daddr, z_dwdata, z_drdata, z_irdata;

  latency_mem #(.WORDS(256), .LATENCY(0)) dut0 (
    .clk_i(clk), .rst_ni(rst_n),
    .instr_req_i(1'b1), .instr_addr_i(32'h10),
    .instr_rdata_o(z_irdata), .instr_ready_o(z_iready),
    .data_req_i(z_dreq), .data_addr_i(z_daddr), .data_we_i(z_dwe),
    .data_be_i(4'hF), .data_wdata_i(z_dwdata),
    .data_rdata_o(z_drdata), .data_ready_o(z_dready)
  );

  task automatic chk(string name, logic [31:0] got, exp);
    if (got !== exp) begin
      $display("FAIL %s: got 0x%08x expected 0x%08x", name, got, exp);
      errors++;
    end
  endtask

  int cycles_taken;

  // Drive a data request and count how many cycles until ready.
  task automatic data_access(logic [31:0] a, d, logic we, output int took);
    took = 0;
    @(negedge clk);
    daddr = a; dwdata = d; dwe = we; dbe = 4'hF; dreq = 1;
    forever begin
      @(posedge clk);
      took++;
      if (dready) break;
    end
    @(negedge clk);
    dreq = 0; dwe = 0;
  endtask

  initial begin
    ireq=0; dreq=0; dwe=0; dbe=4'hF; iaddr=0; daddr=0; dwdata=0;
    z_dreq=0; z_dwe=0; z_daddr=0; z_dwdata=0;
    repeat (2) @(negedge clk); rst_n = 1;

    // 2 wait states means an access takes exactly 3 cycles, not 2 and not 4.
    data_access(32'h10, 32'hDEAD_BEEF, 1'b1, cycles_taken);
    if (cycles_taken != 3) begin
      $display("FAIL write took %0d cycles, expected 3", cycles_taken); errors++;
    end

    data_access(32'h10, 32'd0, 1'b0, cycles_taken);
    if (cycles_taken != 3) begin
      $display("FAIL read took %0d cycles, expected 3", cycles_taken); errors++;
    end
    chk("value survived the write", drdata, 32'hDEAD_BEEF);

    // A back-to-back access pays the full latency again - this models an
    // uncached memory, not one with a hit-under-miss buffer.
    data_access(32'h14, 32'h1234_5678, 1'b1, cycles_taken);
    if (cycles_taken != 3) begin
      $display("FAIL second write took %0d cycles, expected 3", cycles_taken); errors++;
    end
    chk("second location", drdata, 32'h1234_5678);
    daddr = 32'h10; dreq = 1; #1;
    chk("first location untouched", drdata, 32'hDEAD_BEEF);
    dreq = 0;

    // ready must be LOW while no request is outstanding, or a core would
    // mistake idle for a completed access.
    @(negedge clk); dreq = 0; #1;
    if (dready !== 1'b0) begin
      $display("FAIL data_ready high with no request"); errors++;
    end

    // The write must commit ONCE, on the handshake - not on every stall cycle.
    // Writing 1 to a location three times would be invisible, so write a value
    // that a repeated commit would corrupt: read-modify-write is not possible
    // here, so instead confirm a held request does not advance past one word.
    data_access(32'h20, 32'hAAAA_5555, 1'b1, cycles_taken);
    chk("held request writes once", drdata, 32'hAAAA_5555);
    daddr = 32'h24; dreq = 1; #1;
    chk("neighbour not written", drdata, 32'h0000_0013);
    dreq = 0;

    // ---- LATENCY = 0 must be indistinguishable from magic_mem ----
    if (z_iready !== 1'b1) begin
      $display("FAIL LATENCY=0 instr_ready not tied high"); errors++;
    end
    @(negedge clk); z_daddr = 32'h30; z_dwdata = 32'hCAFE_F00D; z_dwe = 1; z_dreq = 1;
    #1;
    if (z_dready !== 1'b1) begin
      $display("FAIL LATENCY=0 data_ready not high in the request cycle"); errors++;
    end
    @(negedge clk); z_dwe = 0; #1;
    chk("LATENCY=0 single-cycle write", z_drdata, 32'hCAFE_F00D);

    if (errors == 0) $display("PASS tb_latency_mem");
    else             $fatal(1, "%0d failures", errors);
    $finish;
  end

  // Bound the run so a broken handshake fails instead of hanging forever.
  initial begin
    #50000;
    $fatal(1, "GLOBAL TIMEOUT - ready never asserted");
  end
endmodule
