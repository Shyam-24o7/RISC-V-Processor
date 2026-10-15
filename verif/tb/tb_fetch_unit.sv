// Exercises the fetch unit against a model of a pipelined instruction memory.
// The interesting cases are all about a redirect landing while requests are
// still in flight - that is where a prefetch buffer silently delivers
// instructions from the path the core has abandoned.
module tb_fetch_unit;
  localparam int LAT   = 2;      // response arrives LAT cycles after the request
  localparam int DEPTH = 4;

  logic clk = 0, rst_n = 0;
  int   errors = 0;
  always #5 clk = ~clk;

  logic        redirect;
  logic [31:0] redirect_pc;
  logic        ireq, iready;
  logic        gnt;
  logic [31:0] iaddr, irdata;
  logic        ivalid, iaccept;
  logic [31:0] ipc, iinsn;

  fetch_unit #(.DEPTH(DEPTH)) dut (
    .clk_i(clk), .rst_ni(rst_n),
    .redirect_i(redirect), .redirect_pc_i(redirect_pc),
    .instr_req_o(ireq), .instr_addr_o(iaddr),
    .instr_gnt_i(gnt),
    .instr_rdata_i(irdata), .instr_ready_i(iready),
    .insn_valid_o(ivalid), .insn_pc_o(ipc), .insn_o(iinsn),
    .insn_ready_i(iaccept)
  );

  // Pipelined memory model: accepts a request every cycle, returns the data
  // LAT cycles later, in order. "Data" is just the address, so every response
  // is self-identifying and a mismatched pairing is immediately visible.
  logic        vpipe [LAT];
  logic [31:0] dpipe [LAT];
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int k = 0; k < LAT; k++) begin vpipe[k] <= 0; dpipe[k] <= 0; end
    end else begin
      vpipe[0] <= ireq && gnt;
      dpipe[0] <= iaddr;
      for (int k = 1; k < LAT; k++) begin
        vpipe[k] <= vpipe[k-1];
        dpipe[k] <= dpipe[k-1];
      end
    end
  end
  assign iready = vpipe[LAT-1];
  assign irdata = dpipe[LAT-1];

  // Back-pressure: the memory refuses a quarter of all cycles, as a cache does
  // while it refills. A refused request must not be counted as in flight.
  always @(negedge clk) gnt = ($urandom_range(0, 3) != 0);

  task automatic chk(string name, logic [31:0] got, exp);
    if (got !== exp) begin
      $display("FAIL %s: got 0x%08x expected 0x%08x", name, got, exp);
      errors++;
    end
  endtask

  // Consume one instruction and check both its PC and its payload.
  task automatic take(logic [31:0] exp_pc);
    int guard;
    guard = 0;
    while (!ivalid) begin
      @(negedge clk);
      guard++;
      if (guard > 100) begin
        $display("FAIL timed out waiting for pc 0x%08x", exp_pc);
        errors++; return;
      end
    end
    chk("insn_pc", ipc, exp_pc);
    // The memory returns the address as data, so this catches a response
    // paired with the wrong in-flight PC.
    chk("insn payload matches its own pc", iinsn, exp_pc);
    @(negedge clk); iaccept = 1;
    @(negedge clk); iaccept = 0;
  endtask

  initial begin
    gnt = 1; redirect = 0; redirect_pc = 0; iaccept = 0;
    repeat (2) @(negedge clk); rst_n = 1;

    // ---- sequential fetch ----
    take(32'h0000_0000);
    take(32'h0000_0004);
    take(32'h0000_0008);

    // ---- the buffer must actually prefetch ----
    // Stop consuming, let it fill, then confirm several are available
    // back-to-back with no waiting.
    repeat (12) @(negedge clk);
    if (!ivalid) begin
      $display("FAIL buffer did not prefetch while decode was idle"); errors++;
    end

    // ---- redirect while requests are in flight ----
    // This is the case that matters: several requests are outstanding for the
    // sequential path, and the core jumps elsewhere. Every one of those
    // responses must be discarded, not delivered.
    @(negedge clk); redirect = 1; redirect_pc = 32'h0000_1000;
    @(negedge clk); redirect = 0;

    take(32'h0000_1000);
    take(32'h0000_1004);
    take(32'h0000_1008);

    // ---- a second redirect immediately after the first ----
    @(negedge clk); redirect = 1; redirect_pc = 32'h0000_2000;
    @(negedge clk); redirect = 0;
    @(negedge clk); redirect = 1; redirect_pc = 32'h0000_3000;
    @(negedge clk); redirect = 0;

    take(32'h0000_3000);
    take(32'h0000_3004);

    // ---- redirect with the buffer full ----
    repeat (12) @(negedge clk);
    @(negedge clk); redirect = 1; redirect_pc = 32'h0000_4000;
    @(negedge clk); redirect = 0;
    take(32'h0000_4000);
    take(32'h0000_4004);

    if (errors == 0) $display("PASS tb_fetch_unit");
    else             $fatal(1, "%0d failures", errors);
    $finish;
  end

  initial begin
    #200000;
    $fatal(1, "GLOBAL TIMEOUT");
  end
endmodule
