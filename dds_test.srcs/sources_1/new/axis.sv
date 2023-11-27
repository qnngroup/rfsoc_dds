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
    if (ok) begin
      samples_sent = samples_sent + 1'b1;
    end
    if (rand_arrivals) begin
      valid <= $urandom() & 1'b1;
    end // else do nothing; intf.valid is already 1'b1
    @(posedge clk);
  end
  if (reset_valid) begin
    valid <= '0;
    @(posedge clk);
  end
endtask

endinterface
