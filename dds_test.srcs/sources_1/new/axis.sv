// multiple axi-stream interfaces in parallel
interface Axis_Parallel_If #(
  parameter DWIDTH = 32,
  parameter PARALLEL_CHANNELS = 1
);

logic [PARALLEL_CHANNELS-1:0][DWIDTH - 1:0]  data;
logic [PARALLEL_CHANNELS-1:0]                ready;
logic [PARALLEL_CHANNELS-1:0]                valid;
logic [PARALLEL_CHANNELS-1:0]                last;
logic [PARALLEL_CHANNELS-1:0]                ok;

assign ok = ready & valid;

modport Master_Full (
  input   ready,
  output  valid,
  output  data,
  output  last,
  output  ok
);

modport Slave_Full (
  output  ready,
  input   valid,
  input   data,
  input   last,
  output  ok
);

modport Master_Simple (
  input   ready,
  output  valid,
  output  data,
  output  ok
);

modport Slave_Simple (
  output  ready,
  input   valid,
  input   data,
  output  ok
);

task automatic send_samples(
  ref clk,
  input int n_samples,
  input bit rand_arrivals,
  input bit reset_valid
);
  int samples_sent [PARALLEL_CHANNELS];
  logic [PARALLEL_CHANNELS-1:0] done;
  // reset
  done = '0;
  for (int i = 0; i < PARALLEL_CHANNELS; i++) begin
    samples_sent[i] = 0;
  end
  valid <= '1; // enable all channels
  while (~done) begin
    @(posedge clk);
    for (int i = 0; i < PARALLEL_CHANNELS; i++) begin
      if (ok[i]) begin
        if (samples_sent[i] == n_samples - 1) begin
          done[i] = 1'b1;
        end else begin
          samples_sent[i] = samples_sent[i] + 1;
        end
      end
    end
    if (rand_arrivals) begin
      valid <= $urandom_range((1 << PARALLEL_CHANNELS) - 1) & (~done);
    end
  end
  if (reset_valid) begin
    valid <= '0;
    @(posedge clk);
  end
endtask

endinterface

// single axi-stream interface
interface Axis_If #(
  parameter DWIDTH = 32
);

logic [DWIDTH - 1:0]  data;
logic                 ready;
logic                 valid;
logic                 last;
logic                 ok;

assign ok = ready & valid;

modport Master_Full (
  input   ready,
  output  valid,
  output  data,
  output  last,
  output  ok
);

modport Slave_Full (
  output  ready,
  input   valid,
  input   data,
  input   last,
  output  ok
);

modport Master_Simple (
  input   ready,
  output  valid,
  output  data,
  output  ok
);

modport Slave_Simple (
  output  ready,
  input   valid,
  input   data,
  output  ok
);

task automatic send_samples(
  ref clk,
  input int n_samples,
  input bit rand_arrivals,
  input bit reset_valid
);
  int samples_sent;
  // reset
  samples_sent = 0;
  valid <= 1'b1;
  while (samples_sent < n_samples) begin
    @(posedge clk);
    if (ok) begin
      samples_sent = samples_sent + 1'b1;
    end
    if (rand_arrivals) begin
      valid <= $urandom() & 1'b1;
    end // else do nothing; intf.valid is already 1'b1
  end
  if (reset_valid) begin
    valid <= '0;
    @(posedge clk);
  end
endtask

task automatic do_readout(
  ref clk,
  input bit rand_ready,
  input int timeout
);
  int cycle_count;
  cycle_count = 0;
  ready <= 1'b0;
  // wait a bit before actually doing the readout
  repeat (500) @(posedge clk);
  ready <= 1'b1;
  // give up after timeout clock cycles if last is not achieved
  while ((!(last & ok)) & (cycle_count < timeout)) begin
    @(posedge clk);
    cycle_count = cycle_count + 1;
    if (rand_ready) begin
      ready <= $urandom() & 1'b1;
    end
  end
  @(posedge clk);
  ready <= 1'b0;
endtask

endinterface
