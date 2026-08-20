module tb_decoder;
  import rv32_pkg::*;

  logic [31:0] insn;
  decoded_t    dec;
  int          errors = 0;

  decoder dut (.insn_i(insn), .dec_o(dec));

  task automatic chk(string name, logic [31:0] got, exp);
    if (got !== exp) begin
      $display("FAIL %s: got 0x%08x expected 0x%08x", name, got, exp);
      errors++;
    end
  endtask

  initial begin
    // ---- I-type: addi x1, x2, 5 ----
    insn = 32'h00510093; #1;
    chk("addi rd",    dec.rd_addr,   5'd1);
    chk("addi rs1",   dec.rs1_addr,  5'd2);
    chk("addi imm",   dec.imm,       32'd5);
    chk("addi rd_we", dec.rd_we,     1'b1);
    chk("addi b=imm", dec.alu_b_imm, 1'b1);
    chk("addi op",    dec.alu_op,    ALU_ADD);

    // Sign extension from bit 31: addi x1, x2, -1
    insn = 32'hFFF10093; #1;
    chk("addi sign-extends", dec.imm, 32'hFFFF_FFFF);

    // ---- R-type ----
    insn = 32'h002081B3; #1;                       // add x3, x1, x2
    chk("add op",     dec.alu_op,    ALU_ADD);
    chk("add uses rs2", dec.alu_b_imm, 1'b0);
    chk("add rs2",    dec.rs2_addr,  5'd2);
    insn = 32'h402081B3; #1;                       // sub x3, x1, x2
    chk("sub via funct7", dec.alu_op, ALU_SUB);
    insn = 32'h4020D1B3; #1;                       // sra x3, x1, x2
    chk("sra via funct7", dec.alu_op, ALU_SRA);
    insn = 32'h0020D1B3; #1;                       // srl x3, x1, x2
    chk("srl", dec.alu_op, ALU_SRL);

    // ---- RV32I: the M extension must decode as ILLEGAL ----
    insn = 32'h022081B3; #1; chk("mul is illegal",  dec.illegal, 1'b1);
    insn = 32'h0220C1B3; #1; chk("div is illegal",  dec.illegal, 1'b1);
    insn = 32'h0220E1B3; #1; chk("rem is illegal",  dec.illegal, 1'b1);
    insn = 32'h022091B3; #1; chk("mulh is illegal", dec.illegal, 1'b1);

    // ---- Loads and stores ----
    insn = 32'h00832283; #1;                       // lw x5, 8(x6)
    chk("lw is_load", dec.is_load, 1'b1);
    chk("lw imm",     dec.imm,     32'd8);
    chk("lw rd_we",   dec.rd_we,   1'b1);
    insn = 32'h00532423; #1;                       // sw x5, 8(x6)  S-type imm
    chk("sw is_store", dec.is_store, 1'b1);
    chk("sw S-imm",    dec.imm,      32'd8);
    chk("sw no rd_we", dec.rd_we,    1'b0);

    // ---- Branch: B-type immediate, implicit zero LSB ----
    insn = 32'h00208463; #1;                       // beq x1, x2, +8
    chk("beq is_branch", dec.is_branch, 1'b1);
    chk("beq B-imm",     dec.imm,       32'd8);
    chk("beq no rd_we",  dec.rd_we,     1'b0);
    insn = 32'hFE208EE3; #1;                       // beq x1, x2, -4
    chk("beq negative B-imm", dec.imm, 32'hFFFF_FFFC);

    // ---- U-type ----
    insn = 32'h123450B7; #1;                       // lui x1, 0x12345
    chk("lui imm", dec.imm,    32'h1234_5000);
    chk("lui op",  dec.alu_op, ALU_PASS_B);
    insn = 32'h12345097; #1;                       // auipc x1, 0x12345
    chk("auipc uses PC", dec.alu_a_pc, 1'b1);

    // ---- J-type ----
    insn = 32'h008000EF; #1;                       // jal x1, +8
    chk("jal is_jal", dec.is_jal, 1'b1);
    chk("jal J-imm",  dec.imm,    32'd8);
    insn = 32'h000080E7; #1;                       // jalr x1, 0(x1)
    chk("jalr is_jalr", dec.is_jalr, 1'b1);

    // ---- SYSTEM ----
    insn = 32'h00000073; #1; chk("ecall",  dec.is_ecall,  1'b1);
    insn = 32'h00100073; #1; chk("ebreak", dec.is_ebreak, 1'b1);
    insn = 32'h30200073; #1; chk("mret",   dec.is_mret,   1'b1);
    insn = 32'h30511073; #1;                       // csrrw x0, mtvec, x2
    chk("csrrw is_csr",  dec.is_csr,     1'b1);
    chk("csrrw address", dec.imm[11:0],  CSR_MTVEC);

    // ---- Reserved encodings must trap ----
    insn = 32'h00003063; #1; chk("branch f3=011 illegal", dec.illegal, 1'b1);
    insn = 32'h00003283; #1; chk("load f3=011 illegal",   dec.illegal, 1'b1);
    insn = 32'hFFFFFFFF; #1; chk("garbage illegal",       dec.illegal, 1'b1);
    insn = 32'h00000013; #1; chk("nop is legal",          dec.illegal, 1'b0);

    if (errors == 0) $display("PASS tb_decoder");
    else             $fatal(1, "%0d failures", errors);
    $finish;
  end
endmodule
