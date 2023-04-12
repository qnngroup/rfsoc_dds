module sample_interleaver (
  input [255:0] adc_data,
  input [255:0] dac_feedthrough,
  output [511:0] interleaved_data
);

genvar i;
generate
  for (i = 0; i < 16; i = i + 1) begin
    assign interleaved_data[32*i+:16] = adc_data[16*i+:16];
    assign interleaved_data[32*i+16+:16] = dac_feedthrough[16*i+:16];
  end
endgenerate

endmodule
