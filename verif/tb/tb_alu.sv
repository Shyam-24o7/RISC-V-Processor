module tb_alu;
  import rv32_pkg::*;

  alu_op_e     op;
  logic [31:0] a, b, result;
  int          errors = 0;

  alu dut (.op_i(op), .a_i(a), .b_i(b), .result_o(result));

  task automatic chk(string name, alu_op_e o, logic [31:0] x, y, exp);
    op = o; a = x; b = y;
    #1;
    if (result !== exp) begin
      $display("FAIL %s: op=%0d(0x%08x, 0x%08x) = 0x%08x, expected 0x%08x",
               name, o, x, y, result, exp);
      errors++;
    end
  endtask

  initial begin
    chk("add",          ALU_ADD,    32'd5,         32'd7,         32'd12);
    chk("add wraps",    ALU_ADD,    32'hFFFF_FFFF, 32'd1,         32'd0);
    chk("sub",          ALU_SUB,    32'd7,         32'd5,         32'd2);
    chk("sub negative", ALU_SUB,    32'd5,         32'd7,         32'hFFFF_FFFE);
    chk("sll",          ALU_SLL,    32'd1,         32'd31,        32'h8000_0000);
    chk("sll masks",    ALU_SLL,    32'd1,         32'd33,        32'd2);
    chk("srl",          ALU_SRL,    32'h8000_0000, 32'd31,        32'd1);
    chk("srl masks",    ALU_SRL,    32'h8000_0000, 32'd32,        32'h8000_0000);
    chk("sra sign ext", ALU_SRA,    32'h8000_0000, 32'd31,        32'hFFFF_FFFF);
    chk("sra positive", ALU_SRA,    32'h4000_0000, 32'd30,        32'd1);
    chk("slt neg<pos",  ALU_SLT,    32'hFFFF_FFFF, 32'd1,         32'd1);
    chk("slt pos<neg",  ALU_SLT,    32'd1,         32'hFFFF_FFFF, 32'd0);
    chk("slt equal",    ALU_SLT,    32'd5,         32'd5,         32'd0);
    chk("sltu no sign", ALU_SLTU,   32'hFFFF_FFFF, 32'd1,         32'd0);
    chk("xor",          ALU_XOR,    32'hF0F0_F0F0, 32'h0F0F_0F0F, 32'hFFFF_FFFF);
    chk("or",           ALU_OR,     32'hF0F0_F0F0, 32'h0F0F_0F0F, 32'hFFFF_FFFF);
    chk("and",          ALU_AND,    32'hFF00_FF00, 32'h0FF0_0FF0, 32'h0F00_0F00);
    chk("pass_b",       ALU_PASS_B, 32'hDEAD_BEEF, 32'h1234_5678, 32'h1234_5678);

    if (errors == 0) $display("PASS tb_alu");
    else             $fatal(1, "%0d failures", errors);
    $finish;
  end
endmodule
