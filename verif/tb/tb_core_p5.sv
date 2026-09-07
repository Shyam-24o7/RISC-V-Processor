// Runs a program to completion and writes an RVFI trace for comparison against
// Spike's commit log. Termination is the tohost handshake.
module tb_core_p5;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;

  logic [31:0] iaddr, irdata, daddr, dwdata, drdata;
  logic        dwe;
  logic [3:0]  dbe;

  logic        rvfi_valid, rvfi_trap;
  logic [63:0] rvfi_order;
  logic [31:0] rvfi_insn, rvfi_rd_wdata, rvfi_pc_rdata, rvfi_pc_wdata;
  logic [4:0]  rvfi_rd_addr;

  string hex_file, trace_file;
  int    max_cycles, fd, cycles = 0;

  // Overridable: our own link.ld fixes tohost at 0x80010000, but riscv-tests
  // binaries use their own linker script and place it elsewhere.
  logic [31:0] tohost_addr = 32'h8001_0000;

  // Programs link at 0x80000000, Spike's DRAM base. magic_mem decodes only the
  // low bits so this aliases into the array, identically on both ports.
  localparam logic [31:0] BOOT = 32'h8000_0000;

  core_rv32i_p5 #(.BOOT_ADDR(BOOT)) dut (
    .clk_i(clk), .rst_ni(rst_n),
    .instr_addr_o(iaddr), .instr_rdata_i(irdata),
    .data_addr_o(daddr), .data_we_o(dwe), .data_be_o(dbe),
    .data_wdata_o(dwdata), .data_rdata_i(drdata),
    .rvfi_valid_o(rvfi_valid), .rvfi_order_o(rvfi_order), .rvfi_insn_o(rvfi_insn),
    .rvfi_trap_o(rvfi_trap), .rvfi_rd_addr_o(rvfi_rd_addr),
    .rvfi_rd_wdata_o(rvfi_rd_wdata), .rvfi_pc_rdata_o(rvfi_pc_rdata),
    .rvfi_pc_wdata_o(rvfi_pc_wdata)
  );

  magic_mem #(.WORDS(65536)) mem (
    .clk_i(clk),
    .instr_addr_i(iaddr), .instr_rdata_o(irdata),
    .data_addr_i(daddr), .data_we_i(dwe), .data_be_i(dbe),
    .data_wdata_i(dwdata), .data_rdata_o(drdata)
  );

  initial begin
    if (!$value$plusargs("hex=%s",   hex_file))   $fatal(1, "need +hex=<file>");
    if (!$value$plusargs("trace=%s", trace_file)) $fatal(1, "need +trace=<file>");
    if (!$value$plusargs("max_cycles=%d", max_cycles)) max_cycles = 1000000;
    void'($value$plusargs("tohost=%h", tohost_addr));

    $readmemh(hex_file, mem.mem);
    fd = $fopen(trace_file, "w");
    if (fd == 0) $fatal(1, "cannot open %s", trace_file);

    repeat (2) @(negedge clk);
    rst_n = 1;
  end

  // One line per retired instruction, in compare_trace.py's format.
  //
  // Trapping instructions are omitted deliberately, because Spike's commit log
  // omits them too: it prints a disassembly line and an "exception" line, but
  // no commit record. This does not weaken trap checking - if the core trapped
  // where Spike did not, our trace would be short a record, and if it failed to
  // trap where Spike did, we would emit an extra one. Either way it diverges.
  always_ff @(posedge clk) begin
    if (rst_n && rvfi_valid && !rvfi_trap) begin
      $fwrite(fd, "%0d %08x %08x %02x %08x\n",
              rvfi_order, rvfi_pc_rdata, rvfi_insn, rvfi_rd_addr, rvfi_rd_wdata);
    end
  end

  // The tohost store commits at MEM, but on a pipelined core the storing
  // instruction does not RETIRE until WB. Finishing the moment the store
  // appears would cut the trace short by the depth of the pipeline, so drain
  // first and only then report. Harmless on a single-cycle core, where store
  // and retirement are the same cycle.
  localparam int DRAIN_CYCLES = 8;
  int          drain = -1;
  logic [31:0] tohost_val;
  int          done_cycles;
  // Captured at the store, not after the drain, so IPC is not skewed by the
  // extra cycles spent letting the pipeline empty.
  logic [63:0] done_retired;

  always_ff @(posedge clk) begin
    if (rst_n) begin
      cycles <= cycles + 1;
      if ((drain < 0) && dwe && (daddr == tohost_addr)) begin
        // riscv-tests encodes its result here: 1 passes, any other odd value is
        // (failing_test << 1) | 1.
        tohost_val   <= dwdata;
        done_cycles  <= cycles;
        done_retired <= rvfi_order;
        drain       <= DRAIN_CYCLES;
      end else if (drain > 0) begin
        drain <= drain - 1;
      end else if (drain == 0) begin
        $display("PROGRAM DONE tohost=0x%08x cycles=%0d retired=%0d",
                 tohost_val, done_cycles, done_retired);
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
