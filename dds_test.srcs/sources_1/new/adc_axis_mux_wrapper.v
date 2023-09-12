module adc_axis_mux_wrapper (
  input clk, reset_n,

  input [127:0] afe_adc_tdata,
  input afe_adc_tvalid,
  output afe_adc_tready,

  input [127:0] loopback_adc_tdata,
  input loopback_adc_tvalid,
  output loopback_adc_tready,

  input sel,
  output [127:0] adc_tdata,
  output adc_tvalid,
  input adc_tready
);

adc_axis_mux (
  .clk(clk),
  .reset(~reset_n),
  .afe_adc_data(afe_adc_tdata),
  .afe_adc_valid(afe_adc_tvalid),
  .afe_adc_ready(afe_adc_tready),
  .loopback_adc_data(loopback_adc_tdata),
  .loopback_adc_valid(loopback_adc_tvalid),
  .loopback_adc_ready(loopback_adc_tready),
  .sel(sel),
  .adc_data(adc_tdata),
  .adc_valid(adc_tvalid),
  .adc_ready(adc_tready)
);

endmodule
