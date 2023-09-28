module axis_x2_wrapper (
  input wire clk, reset_n,
  output [15:0] m_axis_tdata,
  output m_axis_tvalid,
  input m_axis_tready,
  input [15:0] s_axis_tdata,
  input s_axis_tvalid,
  output s_axis_tready
);

axis_x2_sv_wrapper #(
  .SAMPLE_WIDTH(16),
  .PARALLEL_SAMPLES(1)
) axis_x2_sv_wrapper_i (
  .clk(clk),
  .reset(~reset_n),
  .data_out(m_axis_tdata),
  .data_out_valid(m_axis_tvalid),
  .data_out_ready(m_axis_tready),
  .data_in(s_axis_tdata),
  .data_in_valid(s_axis_tvalid),
  .data_in_ready(s_axis_tready)
);


endmodule
