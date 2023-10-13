module sample_discriminator_wrapper #(
  parameter SAMPLE_WIDTH = 16,
  parameter PARALLEL_SAMPLES = 1,
  parameter SAMPLE_INDEX_WIDTH = 14,
  parameter CLOCK_WIDTH = 50
) (
  input wire clk, reset_n,

  input [SAMPLE_WIDTH*PARALLEL_SAMPLES-1:0] s00_axis_tdata,
  input s00_axis_tvalid,
  output s00_axis_tready,

  input [SAMPLE_WIDTH*PARALLEL_SAMPLES-1:0] s01_axis_tdata,
  input s01_axis_tvalid,
  output s01_axis_tready,

  output [SAMPLE_WIDTH*PARALLEL_SAMPLES-1:0] m00_data_axis_tdata,
  output m00_data_axis_tvalid,
  input m00_data_axis_tready,

  output [SAMPLE_WIDTH*PARALLEL_SAMPLES-1:0] m01_data_axis_tdata,
  output m01_data_axis_tvalid,
  input m01_data_axis_tready,

  output [SAMPLE_INDEX_WIDTH+CLOCK_WIDTH-1:0] m00_tstamp_axis_tdata,
  output m00_tstamp_axis_tvalid,
  input m00_tstamp_axis_tready,

  output [SAMPLE_INDEX_WIDTH+CLOCK_WIDTH-1:0] m01_tstamp_axis_tdata,
  output m01_tstamp_axis_tvalid,
  input m01_tstamp_axis_tready,

  input [2*2*SAMPLE_WIDTH-1:0] cfg_axis_tdata,
  input cfg_axis_tvalid,
  output cfg_axis_tready,

  input sample_index_reset
);

sample_discriminator_sv #(
  .SAMPLE_WIDTH(SAMPLE_WIDTH),
  .PARALLEL_SAMPLES(PARALLEL_SAMPLES),
  .SAMPLE_INDEX_WIDTH(SAMPLE_INDEX_WIDTH),
  .CLOCK_WIDTH(CLOCK_WIDTH)
) (
  .clk(clk),
  .reset(~reset_n),

  .s00_axis_tdata(s00_axis_tdata),
  .s00_axis_tvalid(s00_axis_tvalid),
  .s00_axis_tready(s00_axis_tready),

  .s01_axis_tdata(s01_axis_tdata),
  .s01_axis_tvalid(s01_axis_tvalid),
  .s01_axis_tready(s01_axis_tready),

  .m00_data_axis_tdata(m00_data_axis_tdata),
  .m00_data_axis_tvalid(m00_data_axis_tvalid),
  .m00_data_axis_tready(m00_data_axis_tready),

  .m01_data_axis_tdata(m01_data_axis_tdata),
  .m01_data_axis_tvalid(m01_data_axis_tvalid),
  .m01_data_axis_tready(m01_data_axis_tready),

  .m00_tstamp_axis_tdata(m00_tstamp_axis_tdata),
  .m00_tstamp_axis_tvalid(m00_tstamp_axis_tvalid),
  .m00_tstamp_axis_tready(m00_tstamp_axis_tready),

  .m01_tstamp_axis_tdata(m01_tstamp_axis_tdata),
  .m01_tstamp_axis_tvalid(m01_tstamp_axis_tvalid),
  .m01_tstamp_axis_tready(m01_tstamp_axis_tready),

  .cfg_axis_tdata(cfg_axis_tdata),
  .cfg_axis_tvalid(cfg_axis_tvalid),
  .cfg_axis_tready(cfg_axis_tready),

  .sample_index_reset(sample_index_reset)
);

endmodule
