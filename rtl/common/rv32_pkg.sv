// Single source of truth for RV32IM_Zicsr encodings. Every core in every phase
// imports this package; nothing else may define these constants.
package rv32_pkg;

  parameter int XLEN = 32;
  parameter int NRET = 1;   // RVFI retirement channels; becomes 2 at Phase 3

  // ---- Opcodes (instr[6:0]) ----
  parameter logic [6:0] OP_LUI    = 7'b0110111;
  parameter logic [6:0] OP_AUIPC  = 7'b0010111;
  parameter logic [6:0] OP_JAL    = 7'b1101111;
  parameter logic [6:0] OP_JALR   = 7'b1100111;
  parameter logic [6:0] OP_BRANCH = 7'b1100011;
  parameter logic [6:0] OP_LOAD   = 7'b0000011;
  parameter logic [6:0] OP_STORE  = 7'b0100011;
  parameter logic [6:0] OP_IMM    = 7'b0010011;
  parameter logic [6:0] OP_REG    = 7'b0110011;
  parameter logic [6:0] OP_FENCE  = 7'b0001111;
  parameter logic [6:0] OP_SYSTEM = 7'b1110011;

  // ---- funct3 ----
  parameter logic [2:0] F3_ADD_SUB = 3'b000, F3_SLL = 3'b001, F3_SLT = 3'b010,
                        F3_SLTU    = 3'b011, F3_XOR = 3'b100, F3_SR  = 3'b101,
                        F3_OR      = 3'b110, F3_AND = 3'b111;
  parameter logic [2:0] F3_BEQ = 3'b000, F3_BNE = 3'b001, F3_BLT = 3'b100,
                        F3_BGE = 3'b101, F3_BLTU= 3'b110, F3_BGEU= 3'b111;
  parameter logic [2:0] F3_LB = 3'b000, F3_LH = 3'b001, F3_LW = 3'b010,
                        F3_LBU= 3'b100, F3_LHU= 3'b101;
  parameter logic [2:0] F3_SB = 3'b000, F3_SH = 3'b001, F3_SW = 3'b010;
  // Zicsr
  parameter logic [2:0] F3_PRIV = 3'b000,
                        F3_CSRRW=3'b001, F3_CSRRS=3'b010, F3_CSRRC=3'b011,
                        F3_CSRRWI=3'b101,F3_CSRRSI=3'b110,F3_CSRRCI=3'b111;
  // M extension
  parameter logic [2:0] F3_MUL=3'b000, F3_MULH=3'b001, F3_MULHSU=3'b010,
                        F3_MULHU=3'b011, F3_DIV=3'b100, F3_DIVU=3'b101,
                        F3_REM=3'b110, F3_REMU=3'b111;

  // ---- funct7 ----
  parameter logic [6:0] F7_ZERO = 7'b0000000;
  parameter logic [6:0] F7_SUB_SRA = 7'b0100000;
  parameter logic [6:0] F7_MULDIV  = 7'b0000001;

  // ---- SYSTEM instr[31:20] ----
  parameter logic [11:0] SYS_ECALL  = 12'h000;
  parameter logic [11:0] SYS_EBREAK = 12'h001;
  parameter logic [11:0] SYS_MRET   = 12'h302;

  // ---- ALU operations ----
  typedef enum logic [3:0] {
    ALU_ADD, ALU_SUB, ALU_SLL, ALU_SLT, ALU_SLTU,
    ALU_XOR, ALU_SRL, ALU_SRA, ALU_OR,  ALU_AND, ALU_PASS_B
  } alu_op_e;
  // NOTE: alu_op_e is a microarchitecture choice, not part of the ISA. It is
  // kept because it is broadly useful, but a new datapath is free to redefine
  // it - just update the ordinal assertions in tb_rv32_pkg.sv to match.

  // ---- Machine-mode CSR addresses ----
  parameter logic [11:0] CSR_MSTATUS  = 12'h300;
  parameter logic [11:0] CSR_MISA     = 12'h301;
  parameter logic [11:0] CSR_MIE      = 12'h304;
  parameter logic [11:0] CSR_MTVEC    = 12'h305;
  parameter logic [11:0] CSR_MSCRATCH = 12'h340;
  parameter logic [11:0] CSR_MEPC     = 12'h341;
  parameter logic [11:0] CSR_MCAUSE   = 12'h342;
  parameter logic [11:0] CSR_MTVAL    = 12'h343;
  parameter logic [11:0] CSR_MIP      = 12'h344;
  parameter logic [11:0] CSR_MCYCLE   = 12'hB00;
  parameter logic [11:0] CSR_MINSTRET = 12'hB02;
  // RV32 splits the 64-bit counters across two CSRs; without the high halves
  // software cannot read a consistent 64-bit value.
  // Lets software stop individual hardware counters. riscv-tests uses it to
  // hold minstret still while checking overflow behaviour.
  parameter logic [11:0] CSR_MCOUNTINHIBIT = 12'h320;
  parameter logic [11:0] CSR_MCYCLEH   = 12'hB80;
  parameter logic [11:0] CSR_MINSTRETH = 12'hB82;
  // Unprivileged counters (Zicntr). Read-only shadows of the machine counters;
  // there is no separate timer, so time mirrors cycle.
  parameter logic [11:0] CSR_CYCLE    = 12'hC00;
  parameter logic [11:0] CSR_TIME     = 12'hC01;
  parameter logic [11:0] CSR_INSTRET  = 12'hC02;
  parameter logic [11:0] CSR_CYCLEH   = 12'hC80;
  parameter logic [11:0] CSR_TIMEH    = 12'hC81;
  parameter logic [11:0] CSR_INSTRETH = 12'hC82;

  parameter logic [11:0] CSR_MVENDORID= 12'hF11;
  parameter logic [11:0] CSR_MARCHID  = 12'hF12;
  parameter logic [11:0] CSR_MIMPID   = 12'hF13;
  parameter logic [11:0] CSR_MHARTID  = 12'hF14;

  // Physical Memory Protection. This core implements ZERO PMP entries, but the
  // CSRs must still be accessible and read as zero rather than trapping -- an
  // implementation with no entries hardwires them, it does not remove them.
  // riscv-tests' common prologue writes pmpaddr0/pmpcfg0 unconditionally, so
  // trapping here diverges from any reference model on every single test.
  parameter logic [11:0] CSR_PMPCFG0   = 12'h3A0;
  parameter logic [11:0] CSR_PMPCFG3   = 12'h3A3;
  parameter logic [11:0] CSR_PMPADDR0  = 12'h3B0;
  parameter logic [11:0] CSR_PMPADDR15 = 12'h3BF;

  // ---- Exception causes (mcause, interrupt bit clear) ----
  parameter logic [31:0] EXC_INSN_MISALIGNED = 32'd0;
  parameter logic [31:0] EXC_ILLEGAL_INSN    = 32'd2;
  parameter logic [31:0] EXC_BREAKPOINT      = 32'd3;
  parameter logic [31:0] EXC_LOAD_MISALIGNED = 32'd4;
  parameter logic [31:0] EXC_STORE_MISALIGNED= 32'd6;
  parameter logic [31:0] EXC_ECALL_M         = 32'd11;

  // Control bundle produced by the decoder and consumed by the datapath.
  // This is a microarchitecture interface, not an ISA definition - it exists
  // so the decoder has exactly one output rather than twenty loose signals.
  typedef struct packed {
    logic [4:0]  rs1_addr;
    logic [4:0]  rs2_addr;
    logic [4:0]  rd_addr;
    logic        rd_we;
    logic [31:0] imm;
    alu_op_e     alu_op;
    logic        alu_a_pc;     // operand A is the PC (AUIPC)
    logic        alu_b_imm;    // operand B is the immediate
    logic        is_branch;
    logic        is_jal;
    logic        is_jalr;
    logic        is_load;
    logic        is_store;
    logic        is_csr;
    logic        is_ecall;
    logic        is_ebreak;
    logic        is_mret;
    logic        illegal;
    logic [2:0]  funct3;
  } decoded_t;

endpackage
