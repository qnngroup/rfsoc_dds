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

endinterface
