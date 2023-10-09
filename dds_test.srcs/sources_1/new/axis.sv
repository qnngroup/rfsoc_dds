// axi-stream interface
interface Axis_If #(
  parameter DWIDTH = 32,
  parameter PARALLEL_CHANNELS = 1
);

logic [PARALLEL_CHANNELS-1:0][DWIDTH - 1:0]  data;
logic [PARALLEL_CHANNELS-1:0]                ready;
logic [PARALLEL_CHANNELS-1:0]                valid;
logic [PARALLEL_CHANNELS-1:0]                last;

modport Master_Full (
  input   ready,
  output  valid,
  output  data,
  output  last
);

modport Slave_Full (
  output  ready,
  input   valid,
  input   data,
  input   last
);

modport Master_Simple (
  input   ready,
  output  valid,
  output  data
);

modport Slave_Simple (
  output  ready,
  input   valid,
  input   data
);

endinterface
