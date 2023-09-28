module noise_event_tracker_wrapper (
  input wire clk, reset_n,

  output [127:0] m_axis_tdata,
  output [15:0] m_axis_tkeep,
  output m_axis_tvalid, m_axis_tlast,
  input m_axis_tready,

  input [15:0] s00_axis_tdata,
  input s00_axis_tvalid,
  output s00_axis_tready,

  input [15:0] s02_axis_tdata,
  input s02_axis_tvalid,
  output s02_axis_tready,

  input [34:0] s_axis_config_tdata,
  input s_axis_config_tvalid,
  output s_axis_config_tready
);

assign m_axis_tkeep = 16'hffff;

noise_event_tracker_sv_wrapper #(
  .BUFFER_DEPTH(8192),
  .INPUT_SAMPLE_WIDTH(16),
  .OUTPUT_SAMPLE_WIDTH(16),
  .AXI_MM_WIDTH(128)
) noise_event_tracker_sv_wrapper_i (
  .clk(clk),
  .reset(~reset_n),
  .data_out(m_axis_tdata),
  .data_out_valid(m_axis_tvalid),
  .data_out_ready(m_axis_tready),
  .data_out_last(m_axis_tlast),
  .data_in_00(s00_axis_tdata),
  .data_in_00_valid(s00_axis_tvalid),
  .data_in_00_ready(s00_axis_tready),
  .data_in_02(s02_axis_tdata),
  .data_in_02_valid(s02_axis_tvalid),
  .data_in_02_ready(s02_axis_tready),
  .config_in(s_axis_config_tdata),
  .config_in_valid(s_axis_config_tvalid),
  .config_in_ready(s_axis_config_tready)
);

endmodule
