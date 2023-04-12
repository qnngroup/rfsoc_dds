module adc_axis_mux_wrapper (
  input clk, reset_n,

  input [127:0] afe_adc_data,
  input afe_adc_valid,
  output afe_adc_ready,

  input [127:0] loopback_adc_data,
  input loopback_adc_valid,
  output loopback_adc_ready,

  input sel,
  output [127:0] adc_data,
  output adc_valid,
  input adc_ready
);

adc_axis_mux (
  .clk(clk),
  .reset(~reset_n),
  .afe_adc_data(afe_adc_data),
  .afe_adc_valid(afe_adc_valid),
  .afe_adc_ready(afe_adc_ready),
  .loopback_adc_data(loopback_adc_data),
  .loopback_adc_valid(loopback_adc_valid),
  .loopback_adc_ready(loopback_adc_ready),
  .sel(sel),
  .adc_data(adc_data),
  .adc_valid(adc_valid),
  .adc_ready(adc_ready)
);

endmodule
