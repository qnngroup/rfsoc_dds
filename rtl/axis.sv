// axi-stream interface
interface Axis_If #(
  parameter DWIDTH = 32
);

logic [DWIDTH - 1:0]  data;
logic                 ready;
logic                 valid;
logic                 last;

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
