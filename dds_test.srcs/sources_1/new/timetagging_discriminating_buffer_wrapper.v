module timetagging_discriminating_buffer_wrapper #(
  parameter N_CHANNELS = 2,
  parameter TSTAMP_BUFFER_DEPTH = 1024,
  parameter DATA_BUFFER_DEPTH = 32768,
  parameter AXI_MM_WIDTH = 128,
  parameter PARALLEL_SAMPLES = 1,
  parameter SAMPLE_WIDTH = 16
) (
  input wire clk, reset_n,

  input [SAMPLE_WIDTH*PARALLEL_SAMPLES-1:0] s00_axis_tdata,
  input s00_axis_tvalid,
  output s00_axis_tready,

  input [SAMPLE_WIDTH*PARALLEL_SAMPLES-1:0] s01_axis_tdata,
  input s01_axis_tvalid,
  output s01_axis_tready,

  output [AXI_MM_WIDTH-1:0] m_axis_tdata,
  output m_axis_tvalid,
  input m_axis_tready,

  input [$clog2($clog2(N_CHANNELS)+1)+2-1:0] cfg_buf_axis_tdata,
  input cfg_buf_axis_tvalid,
  output cfg_buf_axis_tready,

  input [2*2*SAMPLE_WIDTH-1:0] cfg_disc_axis_tdata,
  input cfg_disc_axis_tvalid,
  output cfg_disc_axis_tready,

  output capture_started
);

banked_sample_buffer_sv #(
  .N_CHANNELS(N_CHANNELS),
  .BUFFER_DEPTH(BUFFER_DEPTH),
  .PARALLEL_SAMPLES(PARALLEL_SAMPLES),
  .SAMPLE_WIDTH(SAMPLE_WIDTH)
) buffer_i (
  .clk(clk),
  .reset(~reset_n),
  .s00_axis_tdata(s00_axis_tdata),
  .s00_axis_tvalid(s00_axis_tvalid),
  .s00_axis_tready(s00_axis_tready),
  .s01_axis_tdata(s01_axis_tdata),
  .s01_axis_tvalid(s01_axis_tvalid),
  .s01_axis_tready(s01_axis_tready),
  .m_axis_tdata(m_axis_tdata),
  .m_axis_tvalid(m_axis_tvalid),
  .m_axis_tlast(m_axis_tlast),
  .m_axis_tready(m_axis_tready),
  .cfg_axis_tdata(cfg_axis_tdata),
  .cfg_axis_tvalid(cfg_axis_tvalid),
  .cfg_axis_tready(cfg_axis_tready),
  .capture_started(capture_started)
);

endmodule
