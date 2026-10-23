// Runs a program on the cached system and writes an RVFI trace for comparison
// against Spike. Same contract as tb_core_p5_lat, so cosim, cosim-lat and
// regress drive it unchanged; main_mem's LATENCY is set with -GLATENCY=N.
module tb_soc #(
  parameter int LATENCY = 4
);
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;

  logic         m_req, m_we, m_ready;
  logic [27:0]  m_addr;
  logic [127:0] m_wdata, m_rdata;
  logic         ic_hit, ic_miss, dc_hit, dc_miss, bp_branch, bp_miss;

  logic        rvfi_valid, rvfi_trap;
  logic [63:0] rvfi_order;
  logic [31:0] rvfi_insn, rvfi_rd_wdata, rvfi_pc_rdata, rvfi_pc_wdata;
  logic [4:0]  rvfi_rd_addr;

  string hex_file, trace_file;
  int    max_cycles, fd, cycles = 0;
  logic [31:0] tohost_addr = 32'h8001_0000;

  localparam logic [31:0] BOOT = 32'h8000_0000;

  rv32_soc #(.BOOT_ADDR(BOOT)) dut (
    .clk_i(clk), .rst_ni(rst_n),
    .mem_req_o(m_req), .mem_we_o(m_we), .mem_addr_o(m_addr), .mem_wdata_o(m_wdata),
    .mem_ready_i(m_ready), .mem_rdata_i(m_rdata),
    .rvfi_valid_o(rvfi_valid), .rvfi_order_o(rvfi_order), .rvfi_insn_o(rvfi_insn),
    .rvfi_trap_o(rvfi_trap), .rvfi_rd_addr_o(rvfi_rd_addr),
    .rvfi_rd_wdata_o(rvfi_rd_wdata), .rvfi_pc_rdata_o(rvfi_pc_rdata),
    .rvfi_pc_wdata_o(rvfi_pc_wdata),
    .ic_hit_o(ic_hit), .ic_miss_o(ic_miss), .dc_hit_o(dc_hit), .dc_miss_o(dc_miss),
    .bp_branch_o(bp_branch), .bp_mispredict_o(bp_miss)
  );

  main_mem #(.WORDS(65536), .LATENCY(LATENCY)) mem (
    .clk_i(clk), .rst_ni(rst_n), .req_i(m_req), .we_i(m_we), .addr_i(m_addr),
    .wdata_i(m_wdata), .ready_o(m_ready), .rdata_o(m_rdata)
  );

  initial begin
    if (!$value$plusargs("hex=%s",   hex_file))   $fatal(1, "need +hex=<file>");
    if (!$value$plusargs("trace=%s", trace_file)) $fatal(1, "need +trace=<file>");
    if (!$value$plusargs("max_cycles=%d", max_cycles)) max_cycles = 2000000;
    void'($value$plusargs("tohost=%h", tohost_addr));

    #1;   // after main_mem's own initial fill
    $readmemh(hex_file, mem.mem);
    fd = $fopen(trace_file, "w");
    if (fd == 0) $fatal(1, "cannot open %s", trace_file);

    repeat (2) @(negedge clk);
    rst_n = 1;
  end

  // One line per retired instruction, in compare_trace.py's format. Trapping
  // instructions are omitted because Spike's commit log omits them too.
  always_ff @(posedge clk) begin
    if (rst_n && rvfi_valid && !rvfi_trap) begin
      $fwrite(fd, "%0d %08x %08x %02x %08x\n",
              rvfi_order, rvfi_pc_rdata, rvfi_insn, rvfi_rd_addr, rvfi_rd_wdata);
    end
  end

  int ihit = 0, imiss = 0, dhit = 0, dmiss = 0, nbranch = 0, nmispred = 0;
  always_ff @(posedge clk) begin
    if (ic_hit)  ihit  <= ihit + 1;
    if (ic_miss) imiss <= imiss + 1;
    if (dc_hit)  dhit  <= dhit + 1;
    if (dc_miss) dmiss <= dmiss + 1;
    if (bp_branch) nbranch <= nbranch + 1;
    if (bp_miss)   nmispred <= nmispred + 1;
  end

  // Completion is the tohost store's HANDSHAKE at the core's data port. With
  // a data cache the store can wait in MEM through a refill, so seeing the
  // request is not enough; the drain then lets it retire through WB.
  localparam int DRAIN_CYCLES = 8;
  int          drain = -1;
  logic [31:0] tohost_val;
  int          done_cycles;
  logic [63:0] done_retired;

  always_ff @(posedge clk) begin
    if (rst_n) begin
      cycles <= cycles + 1;
      if ((drain < 0) && dut.d_req && dut.d_we && dut.d_ready &&
          (dut.d_addr == tohost_addr)) begin
        tohost_val   <= dut.d_wdata;
        done_cycles  <= cycles;
        done_retired <= rvfi_order;
        drain        <= DRAIN_CYCLES;
      end else if (drain > 0) begin
        drain <= drain - 1;
      end else if (drain == 0) begin
        $display("PROGRAM DONE tohost=0x%08x cycles=%0d retired=%0d",
                 tohost_val, done_cycles, done_retired);
        $display("CACHE ihit=%0d imiss=%0d dhit=%0d dmiss=%0d", ihit, imiss, dhit, dmiss);
        $display("BPRED branches=%0d mispredicts=%0d", nbranch, nmispred);
        $fclose(fd);
        $finish;
      end
      if (cycles > max_cycles) begin
        $fclose(fd);
        $fatal(1, "TIMEOUT after %0d cycles", cycles);
      end
    end
  end
endmodule
