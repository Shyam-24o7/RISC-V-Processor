// L1 instruction cache: 2-way set-associative, 16-byte lines, read only.
//
// The core side speaks the fetch unit's protocol: a request is accepted on
// req_i && gnt_o, and exactly one response comes back per accepted request,
// in order. A hit answers the cycle after acceptance, and a new request can be
// accepted in that same cycle, so hits stream at one per cycle.
//
// A miss drops gnt_o, fetches the line and answers straight from it. A
// redirect never aborts a refill: the fetch unit already discards responses
// for an abandoned path, which is far simpler than cancelling a transfer.
//
// Valid and LRU bits are flip-flops, not RAM: reset and FENCE.I must clear
// them all at once, which block RAM cannot do.
module icache #(
  parameter int SETS = 128
) (
  input  logic         clk_i,
  input  logic         rst_ni,

  input  logic         req_i,
  input  logic [31:0]  addr_i,
  output logic         gnt_o,
  output logic         rvalid_o,
  output logic [31:0]  rdata_o,

  // FENCE.I. inv_done_o stays high until inv_req_i drops.
  input  logic         inv_req_i,
  output logic         inv_done_o,

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

  typedef enum logic [1:0] { S_RUN, S_REFILL, S_INV_DONE } state_e;
  state_e state_q;

  // The request accepted last cycle; the arrays are presenting its set now.
  logic          look_q;
  logic [31:0]   look_addr_q;
  logic [IW-1:0] look_idx;
  logic [TW-1:0] look_tag;
  assign look_idx = look_addr_q[4 +: IW];
  assign look_tag = look_addr_q[31 -: TW];

  logic [SETS-1:0] valid_q [2];
  logic [SETS-1:0] lru_q;                 // per set: the way to replace next
  logic            victim_q;

  logic fill;                             // refill completes this cycle
  assign fill = (state_q == S_REFILL) && mem_ready_i;

  // ---- arrays, read every cycle at the presented address ----
  logic [TW-1:0] tag_rd  [2];
  logic [127:0]  data_rd [2];

  for (genvar w = 0; w < 2; w++) begin : g_way
    logic wr;
    assign wr = fill && (victim_q == 1'(w));
    sram_1r1w #(.DEPTH(SETS), .WIDTH(TW), .LANES(1)) u_tag (
      .clk_i(clk_i), .rd_addr_i(addr_i[4 +: IW]), .rd_data_o(tag_rd[w]),
      .wr_en_i(wr), .wr_addr_i(look_idx), .wr_lanes_i(1'b1), .wr_data_i(look_tag));
    sram_1r1w #(.DEPTH(SETS), .WIDTH(128), .LANES(16)) u_data (
      .clk_i(clk_i), .rd_addr_i(addr_i[4 +: IW]), .rd_data_o(data_rd[w]),
      .wr_en_i(wr), .wr_addr_i(look_idx), .wr_lanes_i(16'hFFFF), .wr_data_i(mem_rdata_i));
  end

  // ---- lookup ----
  logic [1:0] hit_way;
  assign hit_way[0] = valid_q[0][look_idx] && (tag_rd[0] == look_tag);
  assign hit_way[1] = valid_q[1][look_idx] && (tag_rd[1] == look_tag);

  logic lookup_hit, lookup_miss;
  assign lookup_hit  = (state_q == S_RUN) && look_q &&  (|hit_way);
  assign lookup_miss = (state_q == S_RUN) && look_q && !(|hit_way);

  assign gnt_o = (state_q == S_RUN) && !lookup_miss && !inv_req_i;

  function automatic logic [31:0] word_of(logic [127:0] line, logic [1:0] w);
    return line[{w, 5'b0} +: 32];
  endfunction

  assign rvalid_o = lookup_hit || fill;
  assign rdata_o  = fill ? word_of(mem_rdata_i, look_addr_q[3:2])
                         : word_of(hit_way[1] ? data_rd[1] : data_rd[0], look_addr_q[3:2]);

  assign mem_req_o   = (state_q == S_REFILL);
  assign mem_we_o    = 1'b0;
  assign mem_addr_o  = look_addr_q[31:4];
  assign mem_wdata_o = '0;

  assign inv_done_o  = (state_q == S_INV_DONE);
  assign stat_hit_o  = lookup_hit;
  assign stat_miss_o = lookup_miss;

  logic unused_ok;
  assign unused_ok = ^look_addr_q[1:0];

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q     <= S_RUN;
      look_q      <= 1'b0;
      look_addr_q <= '0;
      valid_q[0]  <= '0;
      valid_q[1]  <= '0;
      lru_q       <= '0;
      victim_q    <= 1'b0;
    end else begin
      unique case (state_q)
        S_RUN: begin
          if (lookup_miss) begin
            // Prefer an empty way; otherwise the least recently used one.
            victim_q <= !valid_q[0][look_idx] ? 1'b0 :
                        !valid_q[1][look_idx] ? 1'b1 : lru_q[look_idx];
            state_q  <= S_REFILL;
          end else begin
            if (lookup_hit) lru_q[look_idx] <= ~hit_way[1];
            look_q <= req_i && gnt_o;
            if (req_i && gnt_o) look_addr_q <= addr_i;
            // Invalidate only with no lookup outstanding, so the response
            // owed for it is delivered first.
            if (inv_req_i && !look_q) begin
              valid_q[0] <= '0;
              valid_q[1] <= '0;
              state_q    <= S_INV_DONE;
            end
          end
        end
        S_REFILL: begin
          if (mem_ready_i) begin
            valid_q[victim_q][look_idx] <= 1'b1;
            lru_q[look_idx]             <= ~victim_q;
            look_q                      <= 1'b0;   // answered from the line
            state_q                     <= S_RUN;
          end
        end
        S_INV_DONE: begin
          if (!inv_req_i) state_q <= S_RUN;
        end
        default: state_q <= S_RUN;
      endcase
    end
  end

endmodule
