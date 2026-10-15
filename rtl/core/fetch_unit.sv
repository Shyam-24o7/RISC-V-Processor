// Decoupled instruction fetch with a prefetch buffer.
//
// The problem this solves: without it, an instruction-fetch stall freezes the
// entire pipeline, so fetch latency is paid once per instruction exactly as on
// a single-cycle core. Measured on hello.c, that left the pipelined core 29%
// WORSE in cycles at every non-zero memory latency - separate pipeline stages
// cannot overlap what the front end refuses to decouple.
//
// Two things together fix it, and neither works alone:
//   - the memory accepts a request every cycle and returns responses in order
//     LATENCY cycles later (latency_mem with PIPELINED_FETCH)
//   - this unit runs the fetch address ahead and parks arriving instructions in
//     a buffer, so the back end draws from the buffer instead of waiting
//
// The core never needs to know the memory latency. Requests are tracked by a
// queue of in-flight PCs; a response is matched to the oldest one.
module fetch_unit #(
  parameter int          DEPTH     = 4,   // in-flight plus buffered instructions
  parameter logic [31:0] BOOT_ADDR = 32'h0000_0000
) (
  input  logic        clk_i,
  input  logic        rst_ni,

  // Redirect from the back end (branch, trap, mret)
  input  logic        redirect_i,
  input  logic [31:0] redirect_pc_i,

  // Memory side
  output logic        instr_req_o,
  output logic [31:0] instr_addr_o,
  input  logic        instr_gnt_i,     // the memory accepts the request this cycle
  input  logic [31:0] instr_rdata_i,
  input  logic        instr_ready_i,   // a response is valid this cycle

  // Decode side
  output logic        insn_valid_o,
  output logic [31:0] insn_pc_o,
  output logic [31:0] insn_o,
  input  logic        insn_ready_i     // decode consumes the head this cycle
);

  localparam int CW = $clog2(DEPTH + 1);
  localparam int IW = $clog2(DEPTH);   // index width; counts need one bit more

  logic [31:0] fetch_pc_q;

  // In-flight request PCs, oldest at index 0.
  logic [31:0] pcq_q   [DEPTH];
  logic [CW-1:0] pcq_cnt_q;

  // Instructions received and waiting for decode, oldest at index 0.
  logic [31:0] ibuf_pc_q [DEPTH];
  logic [31:0] ibuf_in_q [DEPTH];
  logic [CW-1:0] ibuf_cnt_q;

  // Responses still owed for requests issued before a redirect. They must be
  // thrown away: they belong to a path the core is no longer taking. Without
  // this the buffer fills with instructions from the wrong control flow.
  logic [CW-1:0] discard_q;

  // Issue while there is room for the response. Anything already in flight or
  // already buffered occupies a slot.
  logic can_issue;
  assign can_issue    = ((pcq_cnt_q + ibuf_cnt_q) < CW'(DEPTH)) && !redirect_i;
  assign instr_req_o  = can_issue;
  assign instr_addr_o = fetch_pc_q;

  // A request only counts once the memory has accepted it. Until then the
  // address is simply presented again; nothing is queued as in flight.
  logic issue;
  assign issue = can_issue && instr_gnt_i;

  logic resp, resp_keep, resp_drop, pop;
  assign resp      = instr_ready_i;
  assign resp_drop = resp && (discard_q != 0);
  assign resp_keep = resp && (discard_q == 0) && (pcq_cnt_q != 0);
  assign pop       = insn_valid_o && insn_ready_i;

  assign insn_valid_o = (ibuf_cnt_q != 0);
  assign insn_pc_o    = ibuf_pc_q[0];
  assign insn_o       = ibuf_in_q[0];

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      fetch_pc_q <= BOOT_ADDR;
      pcq_cnt_q  <= '0;
      ibuf_cnt_q <= '0;
      discard_q  <= '0;
      for (int k = 0; k < DEPTH; k++) begin
        pcq_q[k]     <= '0;
        ibuf_pc_q[k] <= '0;
        ibuf_in_q[k] <= '0;
      end
    end else if (redirect_i) begin
      // Drop everything buffered, and remember how many responses are still
      // owed so they can be discarded as they arrive. A response landing in
      // this very cycle is already accounted for and must not be counted again.
      fetch_pc_q <= redirect_pc_i;
      ibuf_cnt_q <= '0;
      pcq_cnt_q  <= '0;
      discard_q  <= (resp && (pcq_cnt_q != 0)) ? (pcq_cnt_q - CW'(1)) : pcq_cnt_q;
    end else begin
      // ---- response ----
      if (resp_drop) begin
        discard_q <= discard_q - CW'(1);
      end

      // ---- in-flight PC queue ----
      // Order matters. A response and a new request can occur in the SAME
      // cycle, and the response shifts the queue down - so a request written
      // at index pcq_cnt_q before the shift gets overwritten by it, and the
      // entry is lost. Shift first, then write the new request at its
      // post-shift index.
      if (resp_keep) begin
        for (int k = 0; k < DEPTH-1; k++) pcq_q[k] <= pcq_q[k+1];
      end
      if (issue) begin
        pcq_q[IW'(resp_keep ? (pcq_cnt_q - CW'(1)) : pcq_cnt_q)] <= fetch_pc_q;
        fetch_pc_q <= fetch_pc_q + 32'd4;
      end

      // The count moves by the difference when both happen at once.
      if (issue && resp_keep)      pcq_cnt_q <= pcq_cnt_q;
      else if (issue)              pcq_cnt_q <= pcq_cnt_q + CW'(1);
      else if (resp_keep)          pcq_cnt_q <= pcq_cnt_q - CW'(1);

      // ---- instruction buffer ----
      if (resp_keep && pop) begin
        // One in, one out: shift down and place the new entry at the tail of
        // the shortened buffer.
        for (int k = 0; k < DEPTH-1; k++) begin
          ibuf_pc_q[k] <= ibuf_pc_q[k+1];
          ibuf_in_q[k] <= ibuf_in_q[k+1];
        end
        ibuf_pc_q[IW'(ibuf_cnt_q - CW'(1))] <= pcq_q[0];
        ibuf_in_q[IW'(ibuf_cnt_q - CW'(1))] <= instr_rdata_i;
      end else if (resp_keep) begin
        ibuf_pc_q[IW'(ibuf_cnt_q)] <= pcq_q[0];
        ibuf_in_q[IW'(ibuf_cnt_q)] <= instr_rdata_i;
        ibuf_cnt_q            <= ibuf_cnt_q + CW'(1);
      end else if (pop) begin
        for (int k = 0; k < DEPTH-1; k++) begin
          ibuf_pc_q[k] <= ibuf_pc_q[k+1];
          ibuf_in_q[k] <= ibuf_in_q[k+1];
        end
        ibuf_cnt_q <= ibuf_cnt_q - CW'(1);
      end
    end
  end

`ifndef SYNTHESIS
  // The truncating casts above are safe only because of this: a request is
  // issued only while in-flight plus buffered entries are below DEPTH, so no
  // write index can reach DEPTH. If this ever fires, entry 0 is being
  // overwritten.
  always_ff @(posedge clk_i) begin
    if (rst_ni) begin
      assert ((32'(pcq_cnt_q) + 32'(ibuf_cnt_q)) <= DEPTH)
        else $error("fetch_unit occupancy %0d+%0d exceeds DEPTH", pcq_cnt_q, ibuf_cnt_q);
    end
  end
`endif

endmodule
