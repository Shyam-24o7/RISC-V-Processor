// Smoke test: run a short hand-assembled program and check the architectural
// registers. Reaches into the register file hierarchically, which gives a far
// clearer failure than a trace diff at this stage.
module tb_core_p5_smoke;
  logic clk = 0, rst_n = 0;
  int   errors = 0;
  always #5 clk = ~clk;

  logic [31:0] iaddr, irdata, daddr, dwdata, drdata;
  logic        dwe;
  logic [3:0]  dbe;
  logic        rvfi_valid, rvfi_trap;
  logic [63:0] rvfi_order;
  logic [31:0] rvfi_insn, rvfi_rd_wdata, rvfi_pc_rdata, rvfi_pc_wdata;
  logic [4:0]  rvfi_rd_addr;

  core_rv32i_p5 dut (
    .clk_i(clk), .rst_ni(rst_n),
    .instr_req_o(), .instr_addr_o(iaddr), .instr_rdata_i(irdata),
    .instr_ready_i(1'b1),
    .data_req_o(), .data_addr_o(daddr), .data_we_o(dwe), .data_be_o(dbe),
    .data_wdata_o(dwdata), .data_rdata_i(drdata), .data_ready_i(1'b1),
    .rvfi_valid_o(rvfi_valid), .rvfi_order_o(rvfi_order), .rvfi_insn_o(rvfi_insn),
    .rvfi_trap_o(rvfi_trap), .rvfi_rd_addr_o(rvfi_rd_addr),
    .rvfi_rd_wdata_o(rvfi_rd_wdata), .rvfi_pc_rdata_o(rvfi_pc_rdata),
    .rvfi_pc_wdata_o(rvfi_pc_wdata)
  );

  magic_mem #(.WORDS(1024), .INIT_HEX("verif/prog/smoke.hex")) mem (
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

  initial begin
    repeat (2) @(negedge clk); rst_n = 1;
    repeat (60) @(negedge clk);   // deeper: pipeline fill, stalls and flushes

    chk("x1  = 5          addi", dut.u_regfile.mem[1],  32'd5);
    chk("x2  = 7          addi", dut.u_regfile.mem[2],  32'd7);
    chk("x3  = 12         add",  dut.u_regfile.mem[3],  32'd12);
    chk("x4  = -2         sub",  dut.u_regfile.mem[4],  32'hFFFF_FFFE);
    chk("x5  = 5          and",  dut.u_regfile.mem[5],  32'd5);
    chk("x6  = 7          or",   dut.u_regfile.mem[6],  32'd7);
    chk("x7  = 2          xor",  dut.u_regfile.mem[7],  32'd2);
    chk("x9  = 1          slt",  dut.u_regfile.mem[9],  32'd1);
    // -2 as unsigned is 0xFFFFFFFE, which is NOT below 5.
    chk("x10 = 0          sltu", dut.u_regfile.mem[10], 32'd0);
    chk("x11 = 0x12345000 lui",  dut.u_regfile.mem[11], 32'h1234_5000);
    // srai keeps the sign: -2 >> 1 = -1, where srli would give 0x7FFFFFFF.
    chk("x12 = -1         srai", dut.u_regfile.mem[12], 32'hFFFF_FFFF);
    chk("x8  = 12         sw/lw",dut.u_regfile.mem[8],  32'd12);
    chk("x14 = 5          sb/lbu",dut.u_regfile.mem[14],32'd5);
    // The skipped instruction would have written 99.
    chk("x15 = 42         beq",  dut.u_regfile.mem[15], 32'd42);
    chk("x17 = 0          jal",  dut.u_regfile.mem[17], 32'd0);
    chk("x18 = 7          jal",  dut.u_regfile.mem[18], 32'd7);

    if (errors == 0) $display("PASS tb_core_p5_smoke");
    else             $fatal(1, "%0d failures", errors);
    $finish;
  end
endmodule
