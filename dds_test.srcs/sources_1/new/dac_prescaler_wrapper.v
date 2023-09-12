module dac_prescaler_wrapper (
  input wire clk, reset_n,
  output [255:0] m_axis_tdata,
  output m_axis_tvalid,
  input m_axis_tready,
  input [255:0] s_axis_tdata,
  input s_axis_tvalid,
  output s_axis_tready,
  input [17:0] scale_factor // 2Q16 (2's complement)
);

dac_prescaler_sv_wrapper dac_prescaler_sv_wrapper_i (
  .clk(clk),
  .reset(~reset_n),
  .data_out(m_axis_tdata),
  .data_out_valid(m_axis_tvalid),
  .data_out_ready(m_axis_tready),
  .data_in(s_axis_tdata),
  .data_in_valid(s_axis_tvalid),
  .data_in_ready(s_axis_tready),
  .scale_factor(scale_factor)
);


endmodule
