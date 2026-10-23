// Branch predictor: a branch target buffer (BTB) plus a bimodal direction
// predictor (a table of 2-bit saturating counters).
//
// The fetch unit looks up the PC it is about to request. On a BTB hit the
// instruction there is a known branch or jump, and the BTB supplies its last
// target. Jumps are always predicted taken; a conditional branch is predicted
// taken when its counter is in one of the two "taken" states. A correctly
// predicted taken branch then costs nothing: fetch goes straight to the
// target instead of waiting for the branch to resolve in EX.
//
// Prediction is only ever a hint. The pipeline checks every instruction's
// predicted next PC in EX and redirects on any difference, so a stale or
// aliased entry costs cycles, never correctness.
//
//   counter  00 strongly not-taken   01 weakly not-taken
//            10 weakly taken         11 strongly taken
//
// A branch must be mispredicted twice in a row before its prediction flips,
// so a loop branch mispredicts once per loop exit rather than twice.
module branch_predictor #(
  parameter int BTB_ENTRIES = 64,     // direct-mapped, indexed by pc[.. : 2]
  parameter int BHT_ENTRIES = 256     // 2-bit counters, indexed by pc[.. : 2]
) (
  input  logic        clk_i,
  input  logic        rst_ni,

  // Lookup (combinational), at fetch
  input  logic [31:0] lookup_pc_i,
  output logic        pred_taken_o,
  output logic [31:0] pred_target_o,

  // Update, once per resolved branch or jump leaving EX
  input  logic        update_i,
  input  logic [31:0] update_pc_i,
  input  logic        update_is_cond_i,   // conditional branch (else JAL/JALR)
  input  logic        update_taken_i,
  input  logic [31:0] update_target_i
);

  localparam int BI = $clog2(BTB_ENTRIES);
  localparam int HI = $clog2(BHT_ENTRIES);
  localparam int TW = 30 - BI;            // tag = pc[31:2+BI]

  logic [BTB_ENTRIES-1:0] btb_valid_q;
  logic [BTB_ENTRIES-1:0] btb_cond_q;     // entry is a conditional branch
  logic [TW-1:0]          btb_tag_q    [BTB_ENTRIES];
  logic [29:0]            btb_target_q [BTB_ENTRIES];   // word-aligned target
  logic [1:0]             bht_q        [BHT_ENTRIES];

  // ---- lookup ----
  logic [BI-1:0] l_idx;
  logic [HI-1:0] l_hidx;
  logic          l_hit;
  assign l_idx  = lookup_pc_i[2 +: BI];
  assign l_hidx = lookup_pc_i[2 +: HI];
  assign l_hit  = btb_valid_q[l_idx] && (btb_tag_q[l_idx] == lookup_pc_i[31 -: TW]);

  assign pred_taken_o  = l_hit && (!btb_cond_q[l_idx] || bht_q[l_hidx][1]);
  assign pred_target_o = {btb_target_q[l_idx], 2'b00};

  // ---- update ----
  logic [BI-1:0] u_idx;
  logic [HI-1:0] u_hidx;
  assign u_idx  = update_pc_i[2 +: BI];
  assign u_hidx = update_pc_i[2 +: HI];

  logic unused_ok;
  assign unused_ok = ^{lookup_pc_i[1:0], update_pc_i[1:0], update_target_i[1:0]};

  // Tags and targets need no reset - an entry is meaningless until its valid
  // bit is set - which lets them map to LUT memory instead of flip-flops.
  always_ff @(posedge clk_i) begin
    if (update_i && update_taken_i) begin
      btb_tag_q[u_idx]    <= update_pc_i[31 -: TW];
      btb_target_q[u_idx] <= update_target_i[31:2];
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      btb_valid_q <= '0;
      btb_cond_q  <= '0;
      for (int i = 0; i < BHT_ENTRIES; i++) bht_q[i] <= 2'b01;   // weakly not-taken
    end else if (update_i) begin
      // Direction: only conditional branches train the counters.
      if (update_is_cond_i) begin
        if (update_taken_i && bht_q[u_hidx] != 2'b11)  bht_q[u_hidx] <= bht_q[u_hidx] + 2'd1;
        if (!update_taken_i && bht_q[u_hidx] != 2'b00) bht_q[u_hidx] <= bht_q[u_hidx] - 2'd1;
      end
      // Target: remember every branch or jump that was taken. A branch that
      // falls through keeps its entry; its counter decides next time.
      if (update_taken_i) begin
        btb_valid_q[u_idx] <= 1'b1;
        btb_cond_q[u_idx]  <= update_is_cond_i;
      end
    end
  end

endmodule
