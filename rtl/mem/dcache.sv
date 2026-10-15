// L1 data cache: 2-way set-associative, 16-byte lines, write-back and
// write-allocate.
//
// A hit completes in MEM with no stall. That works because the arrays are
// read on the clock edge BEFORE the access reaches MEM, at pre_addr_i - the
// address the core says will be in MEM next. While the core is stalled it
// repeats the held address, so the arrays keep presenting the right set.
//
// Misses run a small state machine and end with a REPLAY cycle that re-reads
// the arrays, so the original access then completes through the normal hit
// path - hits, including store hits, are handled in exactly one place:
//
//   RUN -miss-> [victim dirty?] -yes-> WB -> REFILL -> REPLAY -> RUN
//                     '-no------------------> REFILL
//
// Two hazards are designed in:
//   - A store hit writes set S on the same edge that reads the next access's
//     set. If that is also S, the read returns stale data, so the next access
//     is held one cycle and reads again (reread_q). No bypass network.
//   - A stall during a pending read is covered by the pre_addr contract.
//
// FENCE.I walks every line and writes back the dirty ones.
module dcache #(
  parameter int SETS = 128
) (
  input  logic         clk_i,
  input  logic         rst_ni,

  input  logic         req_i,
  input  logic [31:0]  addr_i,
  input  logic         we_i,
  input  logic [3:0]   be_i,
  input  logic [31:0]  wdata_i,      // already replicated across lanes
  output logic         ready_o,
  output logic [31:0]  rdata_o,      // whole aligned word

  input  logic [31:0]  pre_addr_i,   // the access in MEM next cycle

  input  logic         flush_req_i,
  output logic         flush_done_o,

  output logic         mem_req_o,
  output logic         mem_we_o,
  output logic [27:0]  mem_addr_o,
  output logic [127:0] mem_wdata_o,
  input  logic         mem_ready_i,
  input  logic [127:0] mem_rdata_i,

  output logic         stat_hit_o,
  output logic         stat_miss_o
);

  localparam int IW = $clog2(SETS);
  localparam int TW = 28 - IW;            // tag = addr[31:4+IW]
  localparam int CW = IW + 1;             // flush counter: {set, way}

  typedef enum logic [2:0] {
    S_RUN, S_WB, S_REFILL, S_REPLAY, S_FL_CHECK, S_FL_READ, S_FL_WB, S_FL_DONE
  } state_e;
  state_e state_q;

  logic [IW-1:0] idx;
  logic [TW-1:0] tag;
  assign idx = addr_i[4 +: IW];
  assign tag = addr_i[31 -: TW];

  logic [SETS-1:0] valid_q [2];
  logic [SETS-1:0] dirty_q [2];
  logic [SETS-1:0] lru_q;                 // per set: the way to replace next
  logic            victim_q;
  logic [TW-1:0]   vtag_q;                // line being written back
  logic [127:0]    vdata_q;
  logic            reread_q;
  logic            replay_q;              // last cycle was REPLAY
  logic [CW-1:0]   fl_cnt_q;

  logic [IW-1:0] fl_set;
  logic          fl_way, fl_last;
  assign fl_set  = fl_cnt_q[IW:1];
  assign fl_way  = fl_cnt_q[0];
  assign fl_last = (fl_cnt_q == '1);

  logic flushing;
  assign flushing = (state_q == S_FL_CHECK) || (state_q == S_FL_READ) || (state_q == S_FL_WB);

  logic [IW-1:0] rd_idx;
  assign rd_idx = flushing ? fl_set : pre_addr_i[4 +: IW];

  // ---- lookup ----
  logic [TW-1:0] tag_rd  [2];
  logic [127:0]  data_rd [2];
  logic [1:0]    hit_way;
  assign hit_way[0] = valid_q[0][idx] && (tag_rd[0] == tag);
  assign hit_way[1] = valid_q[1][idx] && (tag_rd[1] == tag);

  logic lookup, hit, miss, hw;
  assign lookup = (state_q == S_RUN) && req_i && !reread_q;
  assign hit    = lookup &&  (|hit_way);
  assign miss   = lookup && !(|hit_way);
  assign hw     = hit_way[1];             // the way that hit

  // Prefer an empty way; otherwise the least recently used one.
  logic victim;
  assign victim = !valid_q[0][idx] ? 1'b0 :
                  !valid_q[1][idx] ? 1'b1 : lru_q[idx];

  // ---- array writes: store hits and refills ----
  logic        st, fill;
  logic [15:0] st_lanes;
  assign st       = hit && we_i;
  assign fill     = (state_q == S_REFILL) && mem_ready_i;
  assign st_lanes = 16'(be_i) << {addr_i[3:2], 2'b00};

  for (genvar w = 0; w < 2; w++) begin : g_way
    logic tag_we, data_we;
    assign tag_we  = fill && (victim_q == 1'(w));
    assign data_we = tag_we || (st && (hw == 1'(w)));
    sram_1r1w #(.DEPTH(SETS), .WIDTH(TW), .LANES(1)) u_tag (
      .clk_i(clk_i), .rd_addr_i(rd_idx), .rd_data_o(tag_rd[w]),
      .wr_en_i(tag_we), .wr_addr_i(idx), .wr_lanes_i(1'b1), .wr_data_i(tag));
    sram_1r1w #(.DEPTH(SETS), .WIDTH(128), .LANES(16)) u_data (
      .clk_i(clk_i), .rd_addr_i(rd_idx), .rd_data_o(data_rd[w]),
      .wr_en_i(data_we), .wr_addr_i(idx),
      .wr_lanes_i(fill ? 16'hFFFF : st_lanes),
      .wr_data_i(fill ? mem_rdata_i : {4{wdata_i}}));
  end

  // ---- core side ----
  logic [127:0] hit_line;
  assign hit_line = hw ? data_rd[1] : data_rd[0];
  assign ready_o  = hit;
  assign rdata_o  = hit_line[{addr_i[3:2], 5'b0} +: 32];

  assign flush_done_o = (state_q == S_FL_DONE);
  // A miss completes through the hit path after REPLAY; that completion is
  // part of the miss, not a hit.
  assign stat_hit_o   = hit && !replay_q;
  assign stat_miss_o  = miss;

  // ---- line port ----
  always_comb begin
    mem_req_o   = 1'b0;
    mem_we_o    = 1'b0;
    mem_addr_o  = addr_i[31:4];
    mem_wdata_o = vdata_q;
    unique case (state_q)
      S_WB:     begin mem_req_o = 1'b1; mem_we_o = 1'b1; mem_addr_o = {vtag_q, idx};    end
      S_REFILL: begin mem_req_o = 1'b1;                                                  end
      S_FL_WB:  begin mem_req_o = 1'b1; mem_we_o = 1'b1; mem_addr_o = {vtag_q, fl_set}; end
      default: ;
    endcase
  end

  logic unused_ok;
  assign unused_ok = ^{pre_addr_i[31:4+IW], pre_addr_i[3:0], addr_i[1:0]};

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q    <= S_RUN;
      valid_q[0] <= '0;  valid_q[1] <= '0;
      dirty_q[0] <= '0;  dirty_q[1] <= '0;
      lru_q      <= '0;
      victim_q   <= 1'b0;
      vtag_q     <= '0;
      vdata_q    <= '0;
      reread_q   <= 1'b0;
      replay_q   <= 1'b0;
      fl_cnt_q   <= '0;
    end else begin
      reread_q <= 1'b0;
      replay_q <= (state_q == S_REPLAY);
      unique case (state_q)
        S_RUN: begin
          // Same-set collision between this store's write and the next read.
          reread_q <= st && (rd_idx == idx);
          if (hit) begin
            lru_q[idx] <= ~hw;
            if (we_i) dirty_q[hw][idx] <= 1'b1;
          end else if (miss) begin
            victim_q <= victim;
            vtag_q   <= tag_rd[victim];
            vdata_q  <= data_rd[victim];
            state_q  <= (valid_q[victim][idx] && dirty_q[victim][idx]) ? S_WB : S_REFILL;
          end else if (flush_req_i && !req_i) begin
            fl_cnt_q <= '0;
            state_q  <= S_FL_CHECK;
          end
        end
        S_WB: begin
          if (mem_ready_i) state_q <= S_REFILL;
        end
        S_REFILL: begin
          if (mem_ready_i) begin
            valid_q[victim_q][idx] <= 1'b1;
            dirty_q[victim_q][idx] <= 1'b0;
            lru_q[idx]             <= ~victim_q;
            state_q                <= S_REPLAY;
          end
        end
        S_REPLAY: begin
          // The arrays were written on the last edge; this cycle's read
          // returns the new line, and RUN then completes the access as a hit.
          state_q <= S_RUN;
        end
        S_FL_CHECK: begin
          if (valid_q[fl_way][fl_set] && dirty_q[fl_way][fl_set]) state_q <= S_FL_READ;
          else if (fl_last)                                         state_q <= S_FL_DONE;
          else                                                      fl_cnt_q <= fl_cnt_q + CW'(1);
        end
        S_FL_READ: begin
          vtag_q  <= tag_rd[fl_way];
          vdata_q <= data_rd[fl_way];
          state_q <= S_FL_WB;
        end
        S_FL_WB: begin
          if (mem_ready_i) begin
            dirty_q[fl_way][fl_set] <= 1'b0;
            if (fl_last) state_q <= S_FL_DONE;
            else begin
              fl_cnt_q <= fl_cnt_q + CW'(1);
              state_q  <= S_FL_CHECK;
            end
          end
        end
        S_FL_DONE: begin
          if (!flush_req_i) state_q <= S_RUN;
        end
        default: state_q <= S_RUN;
      endcase
    end
  end

`ifndef SYNTHESIS
  // The pre_addr contract is a correctness requirement: a lookup against the
  // wrong set can false-hit, or write back another set's line on a miss.
  // Check that every lookup sees the arrays read at its own set.
  logic [IW-1:0] rd_idx_q;
  always_ff @(posedge clk_i) begin
    rd_idx_q <= rd_idx;
    if (rst_ni && lookup)
      assert (rd_idx_q == idx)
        else $error("dcache: lookup set %0d but arrays were read at set %0d - pre_addr contract broken",
                    idx, rd_idx_q);
  end
`endif

endmodule
