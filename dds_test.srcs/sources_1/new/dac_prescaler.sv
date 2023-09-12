// dac prescaler
module dac_prescaler #(
  parameter int SAMPLE_WIDTH = 16,
  parameter int PARALLEL_SAMPLES = 16
) (
  input wire clk, reset,
  Axis_If.Master_Simple data_out,
  Axis_If.Slave_Simple data_in,
  input [17:0] scale_factor
);

logic [SAMPLE_WIDTH-1:0] data_in_reg [PARALLEL_SAMPLES]; // 1Q15
logic [17:0] scale_factor_reg; // 2Q16
logic [33:0] product [PARALLEL_SAMPLES]; // 3Q31
logic [SAMPLE_WIDTH-1:0] product_d [PARALLEL_SAMPLES]; // 1Q15
logic [3:0] valid_d;

always_ff @(posedge clk) begin
  if (reset) begin
    valid_d <= '0;
  end
  scale_factor_reg <= scale_factor; // always update scale factor
  if (data_in.valid && data_in.ready) begin
    for (int i = 0; i < PARALLEL_SAMPLES; i++) begin
      data_in_reg[i] <= data_in.data[i*SAMPLE_WIDTH+:SAMPLE_WIDTH]; // 1Q15*2Q16 = 3Q31
      product[i] <= data_in_reg[i]*scale_factor_reg; // 3Q31
      product_d[i] <= product[i][31-:SAMPLE_WIDTH]; // 1Q15
      data_out.data[i*SAMPLE_WIDTH+:SAMPLE_WIDTH] <= product_d[i];
    end
    valid_d <= {valid_d[2:0], data_in.valid};
  end
end

assign data_out.valid = valid_d[3];
assign data_in.ready = data_out.ready;

endmodule

module dac_prescaler_sv_wrapper #(
  parameter int SAMPLE_WIDTH = 16,
  parameter int PARALLEL_SAMPLES = 16
) (
  input wire clk, reset,
  output [SAMPLE_WIDTH*PARALLEL_SAMPLES-1:0] data_out,
  output data_out_valid,
  input data_out_ready,
  input [SAMPLE_WIDTH*PARALLEL_SAMPLES-1:0] data_in,
  input data_in_valid,
  output data_in_ready,
  input [17:0] scale_factor // 2Q16 (2's complement)
);

Axis_If #(.DWIDTH(SAMPLE_WIDTH*PARALLEL_SAMPLES)) data_out_if();
Axis_If #(.DWIDTH(SAMPLE_WIDTH*PARALLEL_SAMPLES)) data_in_if();

dac_prescaler #(
  .SAMPLE_WIDTH(SAMPLE_WIDTH),
  .PARALLEL_SAMPLES(PARALLEL_SAMPLES)
) dac_prescaler_i (
  .clk,
  .reset,
  .data_out(data_out_if),
  .data_in(data_in_if),
  .scale_factor(scale_factor)
);

assign data_out = data_out_if.data;
assign data_out_valid = data_out_if.valid;
assign data_out_if.ready = data_out_ready;

assign data_in_if.data = data_in;
assign data_in_if.valid = data_in_valid;
assign data_in_ready = data_in_if.ready;

endmodule

