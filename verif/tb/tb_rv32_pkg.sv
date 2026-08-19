// Compile-and-value check for the ISA constants package. Catches typos in
// opcode encodings, which are otherwise silent and cause bizarre decode bugs.
module tb_rv32_pkg;
  import rv32_pkg::*;

  int errors = 0;

  task automatic chk(string name, logic [31:0] got, logic [31:0] exp);
    if (got !== exp) begin
      $display("FAIL %s: got 0x%08x expected 0x%08x", name, got, exp);
      errors++;
    end
  endtask

  initial begin
    chk("XLEN",         XLEN,            32);
    chk("OP_LUI",       OP_LUI,          7'b0110111);
    chk("OP_AUIPC",     OP_AUIPC,        7'b0010111);
    chk("OP_JAL",       OP_JAL,          7'b1101111);
    chk("OP_JALR",      OP_JALR,         7'b1100111);
    chk("OP_BRANCH",    OP_BRANCH,       7'b1100011);
    chk("OP_LOAD",      OP_LOAD,         7'b0000011);
    chk("OP_STORE",     OP_STORE,        7'b0100011);
    chk("OP_IMM",       OP_IMM,          7'b0010011);
    chk("OP_REG",       OP_REG,          7'b0110011);
    chk("OP_SYSTEM",    OP_SYSTEM,       7'b1110011);
    chk("CSR_MSTATUS",  CSR_MSTATUS,     12'h300);
    chk("CSR_MTVEC",    CSR_MTVEC,       12'h305);
    chk("CSR_MEPC",     CSR_MEPC,        12'h341);
    chk("CSR_MCAUSE",   CSR_MCAUSE,      12'h342);
    chk("EXC_ILLEGAL",  EXC_ILLEGAL_INSN, 32'd2);
    chk("EXC_ECALL_M",  EXC_ECALL_M,      32'd11);

    // ---- misc parameters / remaining opcode ----
    chk("NRET",         NRET,            1);
    chk("OP_FENCE",     OP_FENCE,        7'b0001111);

    // ---- funct3: arithmetic/logic (R-type and OP-IMM) ----
    chk("F3_ADD_SUB",   F3_ADD_SUB,      3'b000);
    chk("F3_SLL",       F3_SLL,          3'b001);
    chk("F3_SLT",       F3_SLT,          3'b010);
    chk("F3_SLTU",      F3_SLTU,         3'b011);
    chk("F3_XOR",       F3_XOR,          3'b100);
    chk("F3_SR",        F3_SR,           3'b101);
    chk("F3_OR",        F3_OR,           3'b110);
    chk("F3_AND",       F3_AND,          3'b111);

    // ---- funct3: branches ----
    chk("F3_BEQ",       F3_BEQ,          3'b000);
    chk("F3_BNE",       F3_BNE,          3'b001);
    chk("F3_BLT",       F3_BLT,          3'b100);
    chk("F3_BGE",       F3_BGE,          3'b101);
    chk("F3_BLTU",      F3_BLTU,         3'b110);
    chk("F3_BGEU",      F3_BGEU,         3'b111);

    // ---- funct3: loads ----
    chk("F3_LB",        F3_LB,           3'b000);
    chk("F3_LH",        F3_LH,           3'b001);
    chk("F3_LW",        F3_LW,           3'b010);
    chk("F3_LBU",       F3_LBU,          3'b100);
    chk("F3_LHU",       F3_LHU,          3'b101);

    // ---- funct3: stores ----
    chk("F3_SB",        F3_SB,           3'b000);
    chk("F3_SH",        F3_SH,           3'b001);
    chk("F3_SW",        F3_SW,           3'b010);

    // ---- funct3: Zicsr (SYSTEM opcode) ----
    chk("F3_PRIV",      F3_PRIV,         3'b000);
    chk("F3_CSRRW",     F3_CSRRW,        3'b001);
    chk("F3_CSRRS",     F3_CSRRS,        3'b010);
    chk("F3_CSRRC",     F3_CSRRC,        3'b011);
    chk("F3_CSRRWI",    F3_CSRRWI,       3'b101);
    chk("F3_CSRRSI",    F3_CSRRSI,       3'b110);
    chk("F3_CSRRCI",    F3_CSRRCI,       3'b111);

    // ---- funct3: M extension (with funct7 = F7_MULDIV) ----
    chk("F3_MUL",       F3_MUL,          3'b000);
    chk("F3_MULH",      F3_MULH,         3'b001);
    chk("F3_MULHSU",    F3_MULHSU,       3'b010);
    chk("F3_MULHU",     F3_MULHU,        3'b011);
    chk("F3_DIV",       F3_DIV,          3'b100);
    chk("F3_DIVU",      F3_DIVU,         3'b101);
    chk("F3_REM",       F3_REM,          3'b110);
    chk("F3_REMU",      F3_REMU,         3'b111);

    // ---- funct7 ----
    chk("F7_ZERO",      F7_ZERO,         7'b0000000);
    chk("F7_SUB_SRA",   F7_SUB_SRA,      7'b0100000);
    chk("F7_MULDIV",    F7_MULDIV,       7'b0000001);

    // ---- SYSTEM instr[31:20] ----
    chk("SYS_ECALL",    SYS_ECALL,       12'h000);
    chk("SYS_EBREAK",   SYS_EBREAK,      12'h001);
    chk("SYS_MRET",     SYS_MRET,        12'h302);

    // ---- machine-mode CSR addresses (remaining) ----
    chk("CSR_MISA",      CSR_MISA,      12'h301);
    chk("CSR_MIE",       CSR_MIE,       12'h304);
    chk("CSR_MSCRATCH",  CSR_MSCRATCH,  12'h340);
    chk("CSR_MTVAL",     CSR_MTVAL,     12'h343);
    chk("CSR_MIP",       CSR_MIP,       12'h344);
    chk("CSR_MCYCLE",    CSR_MCYCLE,    12'hB00);
    chk("CSR_MINSTRET",  CSR_MINSTRET,  12'hB02);
    chk("CSR_MVENDORID", CSR_MVENDORID, 12'hF11);
    chk("CSR_MARCHID",   CSR_MARCHID,   12'hF12);
    chk("CSR_MIMPID",    CSR_MIMPID,    12'hF13);
    chk("CSR_MHARTID",   CSR_MHARTID,   12'hF14);

    // ---- exception causes (remaining) ----
    chk("EXC_INSN_MISALIGNED",  EXC_INSN_MISALIGNED,  32'd0);
    chk("EXC_BREAKPOINT",       EXC_BREAKPOINT,        32'd3);
    chk("EXC_LOAD_MISALIGNED",  EXC_LOAD_MISALIGNED,   32'd4);
    chk("EXC_STORE_MISALIGNED", EXC_STORE_MISALIGNED,  32'd6);

    // ---- alu_op_e ordinals (catches silent reordering of the enum) ----
    chk("ALU_ADD",     ALU_ADD,     4'd0);
    chk("ALU_SUB",     ALU_SUB,     4'd1);
    chk("ALU_SLL",     ALU_SLL,     4'd2);
    chk("ALU_SLT",     ALU_SLT,     4'd3);
    chk("ALU_SLTU",    ALU_SLTU,    4'd4);
    chk("ALU_XOR",     ALU_XOR,     4'd5);
    chk("ALU_SRL",     ALU_SRL,     4'd6);
    chk("ALU_SRA",     ALU_SRA,     4'd7);
    chk("ALU_OR",      ALU_OR,      4'd8);
    chk("ALU_AND",     ALU_AND,     4'd9);
    chk("ALU_PASS_B",  ALU_PASS_B,  4'd10);

    chk("CSR_MCOUNTINHIBIT", CSR_MCOUNTINHIBIT, 12'h320);
    chk("CSR_MCYCLEH",   CSR_MCYCLEH,   12'hB80);
    chk("CSR_MINSTRETH", CSR_MINSTRETH, 12'hB82);
    chk("CSR_PMPCFG0",   CSR_PMPCFG0,   12'h3A0);
    chk("CSR_PMPCFG3",   CSR_PMPCFG3,   12'h3A3);
    chk("CSR_PMPADDR0",  CSR_PMPADDR0,  12'h3B0);
    chk("CSR_PMPADDR15", CSR_PMPADDR15, 12'h3BF);

    if (errors == 0) $display("PASS tb_rv32_pkg");
    else             $fatal(1, "%0d failures", errors);
    $finish;
  end
endmodule
