module tb_csr_file;
  import rv32_pkg::*;

  logic        clk = 0, rst_n = 0;
  logic [11:0] addr;
  logic [31:0] wdata, rdata;
  logic        we, illegal;
  logic        trap, mret, retired, stall;
  logic [31:0] trap_cause, trap_pc, trap_val, tvec, epc, before_val;
  int          errors = 0;

  always #5 clk = ~clk;

  csr_file dut (
    .clk_i(clk), .rst_ni(rst_n),
    .addr_i(addr), .wdata_i(wdata), .we_i(we),
    .rdata_o(rdata), .illegal_o(illegal),
    .trap_i(trap), .trap_cause_i(trap_cause), .trap_pc_i(trap_pc),
    .trap_val_i(trap_val), .mret_i(mret),
    .tvec_o(tvec), .epc_o(epc), .insn_retired_i(retired), .stall_i(stall)
  );

  task automatic wr(logic [11:0] a, logic [31:0] d);
    @(negedge clk); addr = a; wdata = d; we = 1;
    @(negedge clk); we = 0;
  endtask

  task automatic chk(string name, logic [31:0] got, exp);
    if (got !== exp) begin
      $display("FAIL %s: got 0x%08x expected 0x%08x", name, got, exp);
      errors++;
    end
  endtask

  initial begin
    we=0; trap=0; mret=0; retired=0; addr=0; wdata=0; stall=0;
    trap_cause=0; trap_pc=0; trap_val=0;
    repeat (2) @(negedge clk); rst_n = 1;

    // ---- basic read/write ----
    wr(CSR_MTVEC, 32'h8000_0100);
    addr = CSR_MTVEC; #1;
    chk("mtvec readback", rdata, 32'h8000_0100);
    chk("tvec output",    tvec,  32'h8000_0100);

    // mtvec[1:0] selects the mode; only direct is supported so they mask off.
    wr(CSR_MTVEC, 32'h8000_0103);
    addr = CSR_MTVEC; #1;
    chk("mtvec mode bits masked", rdata, 32'h8000_0100);

    wr(CSR_MSCRATCH, 32'hCAFE_BABE);
    addr = CSR_MSCRATCH; #1;
    chk("mscratch", rdata, 32'hCAFE_BABE);

    // ---- taking a trap ----
    @(negedge clk);
    trap=1; trap_cause=EXC_ILLEGAL_INSN; trap_pc=32'h8000_0040; trap_val=32'hDEAD;
    @(negedge clk); trap = 0;
    addr = CSR_MEPC;   #1; chk("mepc latched",   rdata, 32'h8000_0040);
    addr = CSR_MCAUSE; #1; chk("mcause latched", rdata, EXC_ILLEGAL_INSN);
    addr = CSR_MTVAL;  #1; chk("mtval latched",  rdata, 32'hDEAD);
    chk("epc output", epc, 32'h8000_0040);

    // MPP must read as machine mode on an M-only core.
    addr = CSR_MSTATUS; #1;
    chk("mstatus.MPP reads 3", rdata[12:11], 2'b11);
    if (rdata[MIE_BIT_TB] !== 1'b0) begin
      $display("FAIL mstatus.MIE not cleared on trap: 0x%08x", rdata); errors++;
    end

    // ---- mret restores the interrupt enable ----
    @(negedge clk); mret = 1;
    @(negedge clk); mret = 0;
    addr = CSR_MSTATUS; #1;
    if (rdata[7] !== 1'b1) begin
      $display("FAIL mstatus.MPIE not set after mret: 0x%08x", rdata); errors++;
    end

    // ---- a trap in the same cycle as a CSR write must win ----
    @(negedge clk);
    addr = CSR_MEPC; wdata = 32'h1234_5678; we = 1;
    trap = 1; trap_cause = EXC_ECALL_M; trap_pc = 32'h8000_0080; trap_val = 32'd0;
    @(negedge clk); we = 0; trap = 0;
    addr = CSR_MEPC; #1;
    chk("trap beats concurrent write", rdata, 32'h8000_0080);

    // ---- counters ----
    addr = CSR_MINSTRET; #1; before_val = rdata;
    @(negedge clk); retired = 1;
    @(negedge clk); retired = 0;
    addr = CSR_MINSTRET; #1;
    chk("minstret counts", rdata, before_val + 32'd1);

    // mcountinhibit.IR must actually stop it.
    wr(CSR_MCOUNTINHIBIT, 32'h0000_0004);
    addr = CSR_MINSTRET; #1; before_val = rdata;
    @(negedge clk); retired = 1;
    @(negedge clk); retired = 0;
    addr = CSR_MINSTRET; #1;
    chk("mcountinhibit.IR halts minstret", rdata, before_val);
    wr(CSR_MCOUNTINHIBIT, 32'd0);

    // ---- PMP is accessible and reads zero, it must NOT trap ----
    @(negedge clk); addr = CSR_PMPADDR0; wdata = 32'h7FFF_FFFF; we = 1; #1;
    if (illegal !== 1'b0) begin
      $display("FAIL pmpaddr0 write flagged illegal - would break every riscv-test");
      errors++;
    end
    @(negedge clk); we = 0;
    addr = CSR_PMPADDR0; #1; chk("pmpaddr0 reads zero", rdata, 32'd0);
    addr = CSR_PMPCFG0;  #1; chk("pmpcfg0 reads zero",  rdata, 32'd0);

    // ---- illegal access detection ----
    @(negedge clk); addr = CSR_MVENDORID; wdata = 32'd1; we = 1; #1;
    if (illegal !== 1'b1) begin
      $display("FAIL write to read-only CSR not illegal"); errors++;
    end
    @(negedge clk); we = 0;
    addr = 12'h7FF; we = 0; #1;
    if (illegal !== 1'b1) begin
      $display("FAIL nonexistent CSR not illegal"); errors++;
    end
    addr = CSR_MSCRATCH; we = 0; #1;
    if (illegal !== 1'b0) begin
      $display("FAIL valid CSR read wrongly illegal"); errors++;
    end

    // ---- misa must NOT advertise the M extension ----
    addr = CSR_MISA; #1;
    if (rdata[12] !== 1'b0) begin
      $display("FAIL misa advertises M on an RV32I core: 0x%08x", rdata); errors++;
    end
    if (rdata[8] !== 1'b1) begin
      $display("FAIL misa does not advertise I: 0x%08x", rdata); errors++;
    end

    // ---- stall suppresses every update, never legality ----
    wr(CSR_MSCRATCH, 32'h1111_1111);
    @(negedge clk); addr = CSR_MSCRATCH; wdata = 32'h2222_2222; we = 1; stall = 1;
    #1 chk("illegal_o ignores stall", illegal, 1'b0);
    @(negedge clk); we = 0; stall = 0;
    #1 chk("write during stall suppressed", rdata, 32'h1111_1111);

    @(negedge clk); addr = CSR_MVENDORID; wdata = 32'h1; we = 1; stall = 1;
    #1 chk("read-only write is illegal even when stalled", illegal, 1'b1);
    @(negedge clk); we = 0; stall = 0;

    before_val = epc;
    @(negedge clk); trap = 1; trap_pc = 32'hABCD_0000; trap_cause = 32'd2; stall = 1;
    @(negedge clk); trap = 0; stall = 0;
    #1 chk("trap during stall suppressed", epc, before_val);

    if (errors == 0) $display("PASS tb_csr_file");
    else             $fatal(1, "%0d failures", errors);
    $finish;
  end

  localparam int MIE_BIT_TB = 3;
endmodule
