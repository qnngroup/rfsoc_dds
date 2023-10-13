// width converter
module axis_width_converter #(
  parameter int DWIDTH_IN = 16,
  parameter int DWIDTH_OUT = 128
) (
  input wire clk, reset,
  Axis_If.Slave_Full data_in,
  Axis_If.Master_Full data_out
);

generate
  if (DWIDTH_IN > DWIDTH_OUT) begin
    // downsizer
  end else begin
    // upsizer
  end
endgenerate

endmodule
