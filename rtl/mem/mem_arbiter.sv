// Shares one line port between the two L1 caches.
//
// The data cache wins a tie: a pending data access stalls the whole pipeline,
// while the fetch buffer can ride out a short delay. Once granted, a side
// keeps the port until its transaction completes, so a line transfer is never
// interleaved with the other side's. An idle arbiter adds no latency - the
// winning request reaches the memory in the same cycle.
//
// An L2 would sit on the downstream side, presenting the same responder
// interface main_mem does.
module mem_arbiter (
  input  logic         clk_i,
  input  logic         rst_ni,

  input  logic         i_req_i,
  input  logic         i_we_i,
  input  logic [27:0]  i_addr_i,
  input  logic [127:0] i_wdata_i,
  output logic         i_ready_o,
  output logic [127:0] i_rdata_o,

  input  logic         d_req_i,
  input  logic         d_we_i,
  input  logic [27:0]  d_addr_i,
  input  logic [127:0] d_wdata_i,
  output logic         d_ready_o,
  output logic [127:0] d_rdata_o,

  output logic         m_req_o,
  output logic         m_we_o,
  output logic [27:0]  m_addr_o,
  output logic [127:0] m_wdata_o,
  input  logic         m_ready_i,
  input  logic [127:0] m_rdata_i
);

  typedef enum logic [1:0] { OWN_NONE, OWN_I, OWN_D } own_e;
  own_e own_q, sel;

  always_comb begin
    if      (own_q != OWN_NONE) sel = own_q;
    else if (d_req_i)           sel = OWN_D;
    else if (i_req_i)           sel = OWN_I;
    else                        sel = OWN_NONE;
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni)        own_q <= OWN_NONE;
    else if (m_ready_i) own_q <= OWN_NONE;     // transaction complete
    else                own_q <= sel;          // lock in, or stay idle
  end

  always_comb begin
    unique case (sel)
      OWN_D: begin
        m_req_o = d_req_i; m_we_o = d_we_i; m_addr_o = d_addr_i; m_wdata_o = d_wdata_i;
      end
      OWN_I: begin
        m_req_o = i_req_i; m_we_o = i_we_i; m_addr_o = i_addr_i; m_wdata_o = i_wdata_i;
      end
      default: begin
        m_req_o = 1'b0; m_we_o = 1'b0; m_addr_o = '0; m_wdata_o = '0;
      end
    endcase
  end

  assign d_ready_o = (sel == OWN_D) && m_ready_i;
  assign i_ready_o = (sel == OWN_I) && m_ready_i;
  assign d_rdata_o = m_rdata_i;
  assign i_rdata_o = m_rdata_i;

endmodule
