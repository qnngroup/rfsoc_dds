// noise event tracker
// performs real-time compression of incoming noise signal
// if noise level is above some threshold, then record the noise level at
// full rate (2MS/s), until it goes below some threshold, then record at low
// rate (e.g. 200S/s, no filtering before decimation, so any high frequency
// variation (e.g. 100Hz-1MHz in the noise power will alias)
// optionally, for mode = 0, always record data at the full rate
module noise_event_tracker #(
  parameter int BUFFER_DEPTH = 1024, // size will be BUFFER_DEPTH x AXI_MM_WIDTH
  parameter int SAMPLE_WIDTH = 16,
  parameter int AXI_MM_WIDTH = 128,
  parameter int DECIMATION_BELOW_THRESH = 10000 // 200S/s
) (
  input wire clk, reset
  Axis_If.Master_Full data_out, // packed collection of samples
  Axis_If.Slave_Simple data_in_00, // least significant bit of each sample will be trimmed off
  Axis_If.Slave_Simple data_in_02,
  Axis_If.Slave_Simple config_in // {mode, start, stop, threshold_high, threshold_low}
);

assign config_in.ready = 1'b1;
assign data_in_00.ready = 1'b1;
assign data_in_02.ready = 1'b1;

enum {IDLE, CAPTURE, TRANSFER} state;

logic [SAMPLE_WIDTH-1:0] threshold_low, threshold_high;
logic mode; // 1 for rate compression, 0 for always full rate

logic [AXI_MM_WIDTH-1:0] buffer [BUFFER_DEPTH];
logic [$clog2(BUFFER_DEPTH)-1:0] write_addr, read_addr;
logic data_out_valid;
logic data_out_last;

logic [AXI_MM_WIDTH-1:0] write_word; // write samples to a single wide reg, then

// process config_in updates
localparam int WORD_SIZE = 2**($clog2(SAMPLE_WIDTH));
localparam int WORD_SELECT_BITS = $clog2(AXI_MM_WIDTH) - $clog2(SAMPLE_WIDTH);

logic [WORD_SELECT_BITS-1:0] write_word_select;

// update mode and thresholds from config interface
always_ff @(posedge clk) begin
  if (reset) begin
    mode <= 1'b0; // by default record at full-rate
    threshold_low <= '1;
    threshold_high <= '0;
  end else begin
    if (config_in.ready && config_in.valid) begin
      mode <= config_in.data[2*SAMPLE_WIDTH+2:2*SAMPLE_WIDTH+2];
      threshold_high <= config_in.data[2*SAMPLE_WIDTH-1:SAMPLE_WIDTH];
      threshold_low <= config_in.data[SAMPLE_WIDTH-1:0];
    end
  end
end

// state machine update
always_ff @(posedge clk) begin
  if (reset) begin
  end else begin
end

endmodule

module noise_event_tracker_sv_wrapper #(
  parameter int BUFFER_DEPTH = 1024,
  parameter int SAMPLE_WIDTH = 16,
  parameter int AXI_MM_WIDTH = 128
) (
  input wire clk, reset,

  output [AXI_MM_WIDTH-1:0] data_out,
  output data_out_valid,
  output data_out_last,
  input data_out_ready,

  input [SAMPLE_WIDTH-1:0] data_in_00,
  input data_in_00_valid,
  output data_in_00_ready,

  input [SAMPLE_WIDTH-1:0] data_in_02,
  input data_in_02_valid,
  output data_in_02_ready,

  input config_in,
  input config_in_valid,
  output config_in_ready
);

Axis_If #(.DWIDTH(SAMPLE_WIDTH)) data_in_00_if();
Axis_If #(.DWIDTH(SAMPLE_WIDTH)) data_in_02_if();
Axis_If #(.DWIDTH(AXI_MM_WIDTH)) data_out_if();
Axis_If #(.DWIDTH(3+2*SAMPLE_WIDTH)) config_in_if();

noise_event_tracker #(
  .BUFFER_DEPTH(BUFFER_DEPTH),
  .SAMPLE_WIDTH(SAMPLE_WIDTH),
  .AXI_MM_WIDTH(AXI_MM_WIDTH)
) noise_event_tracker_i (
  .clk,
  .reset,
  .data_out(data_out_if),
  .data_in_00(data_in_00_if),
  .data_in_02(data_in_02_if),
  .config_in(config_in_if)
);

assign data_out = data_out_if.data;
assign data_out_valid = data_out_if.valid;
assign data_out_last = data_out_if.last;
assign data_out_if.ready = data_out_ready;

assign data_in_00_if.data = data_in_00;
assign data_in_00_if.valid = data_in_00_valid;
assign data_in_00_ready = data_in_00_if.ready;

assign data_in_02_if.data = data_in_02;
assign data_in_02_if.valid = data_in_02_valid;
assign data_in_02_ready = data_in_02_if.ready;

assign config_in_if.data = config_in;
assign config_in_if.valid = config_in_valid;
assign config_in_ready = config_in_if.ready;

endmodule
