// Combinational ALU for RV32I. No clock, no state: operands in, result out.
module alu
  import rv32_pkg::*;
(
  input  alu_op_e     op_i,
  input  logic [31:0] a_i,
  input  logic [31:0] b_i,
  output logic [31:0] result_o
);

  // RV32 shifts use only the low 5 bits of the shift operand, so a shift by 33
  // is a shift by 1. Passing the full 32-bit value to << would give 0 instead.
  logic [4:0] shamt;
  assign shamt = b_i[4:0];

  always_comb begin
    unique case (op_i)
      ALU_ADD:    result_o = a_i + b_i;
      ALU_SUB:    result_o = a_i - b_i;
      ALU_SLL:    result_o = a_i << shamt;
      // SLT is a SIGNED compare, SLTU unsigned. This one distinction is why
      // -1 < 1 holds but 0xFFFFFFFF < 1 does not.
      ALU_SLT:    result_o = {31'b0, ($signed(a_i) < $signed(b_i))};
      ALU_SLTU:   result_o = {31'b0, (a_i < b_i)};
      ALU_XOR:    result_o = a_i ^ b_i;
      ALU_SRL:    result_o = a_i >> shamt;
      // >>> is only an arithmetic shift when its operand is signed; on an
      // unsigned operand it behaves exactly like >>.
      ALU_SRA:    result_o = $unsigned($signed(a_i) >>> shamt);
      ALU_OR:     result_o = a_i | b_i;
      ALU_AND:    result_o = a_i & b_i;
      // Routes the immediate through untouched, which is how LUI writes its
      // upper immediate without a separate datapath.
      ALU_PASS_B: result_o = b_i;
      default:    result_o = '0;
    endcase
  end

endmodule
