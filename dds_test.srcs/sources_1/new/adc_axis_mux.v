module adc_axis_mux_wrapper (
  input [127:0] afe_adc_data,
  input [127:0] loopback_adc_data,
  input afe_adc_valid,
  input loopback_adc_valid,
  output afe_adc_ready,
  output loopback_adc_ready,

  input sel,
  output [127:0] adc_data,
  output adc_valid,
  input adc_ready
);

assign afe_adc_ready = adc_ready;
assign loopback_adc_ready = adc_ready;

assign adc_data = sel ? loopback_adc_data ? afe_adc_data;
assign adc_valid = sel ? loopback_adc_valid ? afe_adc_valid;

endmodule
