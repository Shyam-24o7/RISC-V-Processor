// RV32I instruction decoder. Pure combinational: instruction word in, control
// bundle plus sign-extended immediate out.
//
// The register fields sit at fixed positions in EVERY format - rs1 at [19:15],
// rs2 at [24:20], rd at [11:7] - which is what lets the register file start
// reading before decode has finished. The price is that the immediates are
// shredded across whatever bits are left over, reassembled below.
module decoder
  import rv32_pkg::*;
(
  input  logic [31:0] insn_i,
  output decoded_t    dec_o
);

  // A declaration initialiser at module scope (`logic x = expr;`) runs ONCE at
  // time zero like an initial block - it is not a continuous assignment. These
  // must be explicit assigns or the decoder would decode instruction 0 forever.
  logic [6:0] opcode;
  logic [2:0] funct3;
  logic [6:0] funct7;
  assign opcode = insn_i[6:0];
  assign funct3 = insn_i[14:12];
  assign funct7 = insn_i[31:25];

  // Every immediate sign-extends from insn[31]. B and J have an implicit zero
  // LSB because branch and jump targets are 2-byte aligned, so that bit is
  // never encoded - which is why their immediates look scrambled.
  logic [31:0] imm_i_type, imm_s_type, imm_b_type, imm_u_type, imm_j_type, imm_csr;
  assign imm_i_type = {{20{insn_i[31]}}, insn_i[31:20]};
  assign imm_s_type = {{20{insn_i[31]}}, insn_i[31:25], insn_i[11:7]};
  assign imm_b_type = {{19{insn_i[31]}}, insn_i[31], insn_i[7],
                       insn_i[30:25], insn_i[11:8], 1'b0};
  assign imm_u_type = {insn_i[31:12], 12'b0};
  assign imm_j_type = {{11{insn_i[31]}}, insn_i[31], insn_i[19:12],
                       insn_i[20], insn_i[30:21], 1'b0};
  assign imm_csr    = {20'b0, insn_i[31:20]};   // CSR address, zero-extended

  // funct7 bit 5 selects SUB from ADD and SRA from SRL. For OP_IMM there is no
  // SUBI, so only the shift ops consult it.
  alu_op_e alu_arith;
  always_comb begin
    unique case (funct3)
      F3_ADD_SUB: alu_arith = (opcode == OP_REG && funct7[5]) ? ALU_SUB : ALU_ADD;
      F3_SLL:     alu_arith = ALU_SLL;
      F3_SLT:     alu_arith = ALU_SLT;
      F3_SLTU:    alu_arith = ALU_SLTU;
      F3_XOR:     alu_arith = ALU_XOR;
      F3_SR:      alu_arith = funct7[5] ? ALU_SRA : ALU_SRL;
      F3_OR:      alu_arith = ALU_OR;
      F3_AND:     alu_arith = ALU_AND;
      default:    alu_arith = ALU_ADD;
    endcase
  end

  always_comb begin
    dec_o          = '0;
    dec_o.rs1_addr = insn_i[19:15];
    dec_o.rs2_addr = insn_i[24:20];
    dec_o.rd_addr  = insn_i[11:7];
    dec_o.funct3   = funct3;
    dec_o.alu_op   = ALU_ADD;

    unique case (opcode)
      OP_LUI: begin
        dec_o.imm = imm_u_type; dec_o.rd_we = 1'b1;
        dec_o.alu_op = ALU_PASS_B; dec_o.alu_b_imm = 1'b1;
      end
      OP_AUIPC: begin
        dec_o.imm = imm_u_type; dec_o.rd_we = 1'b1;
        dec_o.alu_op = ALU_ADD; dec_o.alu_a_pc = 1'b1; dec_o.alu_b_imm = 1'b1;
      end
      OP_JAL: begin
        dec_o.imm = imm_j_type; dec_o.rd_we = 1'b1; dec_o.is_jal = 1'b1;
      end
      OP_JALR: begin
        dec_o.imm = imm_i_type; dec_o.rd_we = 1'b1; dec_o.is_jalr = 1'b1;
        dec_o.illegal = (funct3 != 3'b000);
      end
      OP_BRANCH: begin
        dec_o.imm = imm_b_type; dec_o.is_branch = 1'b1;
        // funct3 010 and 011 are reserved in the branch encoding.
        dec_o.illegal = (funct3 == 3'b010) || (funct3 == 3'b011);
      end
      OP_LOAD: begin
        dec_o.imm = imm_i_type; dec_o.rd_we = 1'b1; dec_o.is_load = 1'b1;
        dec_o.alu_b_imm = 1'b1;
        // 011 (LD), 110 and 111 do not exist in RV32.
        dec_o.illegal = (funct3 == 3'b011) || (funct3 == 3'b110) || (funct3 == 3'b111);
      end
      OP_STORE: begin
        dec_o.imm = imm_s_type; dec_o.is_store = 1'b1; dec_o.alu_b_imm = 1'b1;
        dec_o.illegal = (funct3 > F3_SW);
      end
      OP_IMM: begin
        dec_o.imm = imm_i_type; dec_o.rd_we = 1'b1; dec_o.alu_b_imm = 1'b1;
        dec_o.alu_op = alu_arith;
        // Shift-immediate carries the shift amount in rs2 and must have an
        // otherwise-clean funct7.
        dec_o.illegal = ((funct3 == F3_SLL) && (funct7 != F7_ZERO)) ||
                        ((funct3 == F3_SR)  && (funct7 != F7_ZERO)
                                            && (funct7 != F7_SUB_SRA));
      end
      OP_REG: begin
        dec_o.rd_we  = 1'b1;
        dec_o.alu_op = alu_arith;
        // RV32I: any funct7 other than 0000000, or 0100000 for SUB/SRA, is
        // illegal - including 0000001, the M extension's MUL/DIV.
        dec_o.illegal = (funct7 != F7_ZERO) &&
                        !((funct7 == F7_SUB_SRA) &&
                          (funct3 == F3_ADD_SUB || funct3 == F3_SR));
      end
      OP_FENCE: begin
        // FENCE and FENCE.I retire as NOPs on a single-hart in-order core:
        // there is nothing to order against.
      end
      OP_SYSTEM: begin
        if (funct3 == F3_PRIV) begin
          unique case (insn_i[31:20])
            SYS_ECALL:  dec_o.is_ecall  = 1'b1;
            SYS_EBREAK: dec_o.is_ebreak = 1'b1;
            SYS_MRET:   dec_o.is_mret   = 1'b1;
            default:    dec_o.illegal   = 1'b1;
          endcase
        end else begin
          dec_o.is_csr = 1'b1;
          dec_o.imm    = imm_csr;
          dec_o.rd_we  = 1'b1;
        end
      end
      default: dec_o.illegal = 1'b1;
    endcase
  end

endmodule
