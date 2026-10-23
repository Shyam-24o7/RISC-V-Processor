// Checks the predictor's contract: nothing is predicted until a branch has
// been seen taken; jumps are always predicted taken; conditional branches
// follow the 2-bit counter, which needs two mispredictions to flip and
// saturates at both ends; a different PC mapping to the same entry misses.
module tb_branch_predictor;
  logic clk = 0, rst_n = 0;
  int   errors = 0;
  always #5 clk = ~clk;

  logic [31:0] lpc, ptgt, upc, utgt;
  logic        ptaken, upd, ucond, utaken;

  branch_predictor #(.BTB_ENTRIES(64), .BHT_ENTRIES(256)) dut (
    .clk_i(clk), .rst_ni(rst_n),
    .lookup_pc_i(lpc), .pred_taken_o(ptaken), .pred_target_o(ptgt),
    .update_i(upd), .update_pc_i(upc), .update_is_cond_i(ucond),
    .update_taken_i(utaken), .update_target_i(utgt)
  );

  task automatic chk(string name, logic [31:0] got, exp);
    if (got !== exp) begin
      $display("FAIL %s: got 0x%08x expected 0x%08x", name, got, exp);
      errors++;
    end
  endtask

  // Train with one resolved instruction.
  task automatic train(logic [31:0] pc, logic cond, logic taken, logic [31:0] tgt);
    @(negedge clk); upd = 1; upc = pc; ucond = cond; utaken = taken; utgt = tgt;
    @(negedge clk); upd = 0;
  endtask

  task automatic predict(logic [31:0] pc, logic exp_taken, logic [31:0] exp_tgt,
                         string name);
    lpc = pc; #1;
    chk({name, " taken"}, 32'(ptaken), 32'(exp_taken));
    if (exp_taken) chk({name, " target"}, ptgt, exp_tgt);
  endtask

  localparam logic [31:0] BR  = 32'h8000_0104;   // a loop branch
  localparam logic [31:0] TGT = 32'h8000_00C0;
  localparam logic [31:0] J   = 32'h8000_0200;   // a jump
  localparam logic [31:0] JT  = 32'h8000_0800;

  initial begin
    upd = 0; upc = 0; ucond = 0; utaken = 0; utgt = 0; lpc = 0;
    repeat (2) @(negedge clk); rst_n = 1;

    predict(BR, 0, 0, "cold: nothing predicted");

    // ---- jumps: one sighting is enough, always taken ----
    train(J, 0, 1, JT);
    predict(J, 1, JT, "jump after one sighting");

    // ---- conditional branch through the 2-bit counter ----
    // Counters start weakly not-taken (01). A taken branch allocates the BTB
    // entry and moves the counter to 10: predicted taken.
    train(BR, 1, 1, TGT);
    predict(BR, 1, TGT, "taken once -> weakly taken");
    train(BR, 1, 1, TGT);                       // 11, strongly taken
    train(BR, 1, 1, TGT);                       // saturates at 11
    train(BR, 1, 0, TGT);                       // one not-taken (loop exit): 10
    predict(BR, 1, TGT, "one miss does not flip a strongly taken branch");
    train(BR, 1, 0, TGT);                       // 01
    predict(BR, 0, 0, "second miss flips to not-taken");
    train(BR, 1, 0, TGT);                       // 00
    train(BR, 1, 0, TGT);                       // saturates at 00
    train(BR, 1, 1, TGT);                       // 01, still not-taken
    predict(BR, 0, 0, "one taken does not flip a strongly not-taken branch");
    train(BR, 1, 1, TGT);                       // 10
    predict(BR, 1, TGT, "second taken flips to taken");

    // ---- the target follows the most recent taken outcome ----
    train(J, 0, 1, 32'h8000_0900);
    predict(J, 1, 32'h8000_0900, "jump target updated");

    // ---- a different PC with the same BTB index misses (tag check) ----
    predict(J + 32'h0000_0100, 0, 0, "aliasing PC misses");

    // ---- reset clears everything ----
    @(negedge clk); rst_n = 0; @(negedge clk); rst_n = 1;
    predict(J, 0, 0, "reset clears the BTB");

    if (errors == 0) $display("PASS tb_branch_predictor");
    else             $fatal(1, "%0d failures", errors);
    $finish;
  end
endmodule
