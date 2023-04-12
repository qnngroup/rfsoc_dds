module adc_axis_mux (
  input wire clk, reset,
  input [127:0] afe_adc_data,
  input afe_adc_valid,
  output afe_adc_ready,

  input [127:0] loopback_adc_data,
  input loopback_adc_valid,
  output loopback_adc_ready,

  input sel,
  output logic [127:0] adc_data,
  output logic adc_valid,
  input adc_ready
);

assign afe_adc_ready = adc_ready;
assign loopback_adc_ready = adc_ready;

always_ff @(posedge clk) begin
  if (reset) begin
    adc_data <= '0;
    adc_valid <= 1'b0;
  end else begin
    if (adc_ready) begin
      adc_valid <= sel ? loopback_adc_valid : afe_adc_valid;
      adc_data <= sel ? loopback_adc_data : afe_adc_data;
    end
  end
end
endmodule
