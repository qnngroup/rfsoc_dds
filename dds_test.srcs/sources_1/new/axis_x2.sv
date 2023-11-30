// axis_x2 - Reed Foster
// computes x^2 on axi-stream data
module axis_x2 #(
  parameter int SAMPLE_WIDTH = 16,
  parameter int PARALLEL_SAMPLES = 1,
  parameter int SAMPLE_FRAC_BITS = 16
) (
  input wire clk, reset,
  Axis_If.Slave_Simple data_in,
  Axis_If.Master_Simple data_out
);

// register signals to infer DSPs
// can't do packed arrays because of signed type
logic signed [SAMPLE_WIDTH-1:0] data_in_reg [PARALLEL_SAMPLES]; // 0Q16, 2Q14
logic signed [2*SAMPLE_WIDTH-1:0] product [PARALLEL_SAMPLES]; // 0Q32, 4Q28
logic signed [SAMPLE_WIDTH-1:0] product_d [PARALLEL_SAMPLES]; // 0Q16, 4Q12
logic [3:0] valid_d;

always_ff @(posedge clk) begin
  if (reset) begin
    valid_d <= '0;
  end else begin
    if (data_in.ok) begin
      for (int i = 0; i < PARALLEL_SAMPLES; i++) begin
        data_in_reg[i] <= data_in.data[i*SAMPLE_WIDTH+:SAMPLE_WIDTH]; // 0Q16, 2Q14
      end
    end
    if (data_out.ready || (!data_out.valid)) begin
      for (int i = 0; i < PARALLEL_SAMPLES; i++) begin
        product[i] <= data_in_reg[i]*data_in_reg[i]; // 0Q16*0Q16 = 0Q32, 2Q14*2Q14 = 4Q28
        product_d[i] <= product[i][2*SAMPLE_WIDTH-1-:SAMPLE_WIDTH]; // 0Q16, 4Q12
        data_out.data[i*SAMPLE_WIDTH+:SAMPLE_WIDTH] <= product_d[i];
      end
      valid_d <= {valid_d[2:0], data_in.ok};
    end
  end
end

assign data_out.valid = valid_d[3];
assign data_in.ready = data_out.ready;

endmodule

module axis_x2_sv_wrapper #(
  parameter int SAMPLE_WIDTH = 16,
  parameter int PARALLEL_SAMPLES = 1
) (
  input wire clk, reset,
  output [SAMPLE_WIDTH*PARALLEL_SAMPLES-1:0] data_out,
  output data_out_valid,
  input data_out_ready,
  input [SAMPLE_WIDTH*PARALLEL_SAMPLES-1:0] data_in,
  input data_in_valid,
  output data_in_ready
);

Axis_If #(.DWIDTH(SAMPLE_WIDTH*PARALLEL_SAMPLES)) data_out_if();
Axis_If #(.DWIDTH(SAMPLE_WIDTH*PARALLEL_SAMPLES)) data_in_if();

axis_x2 #(
  .SAMPLE_WIDTH(SAMPLE_WIDTH),
  .PARALLEL_SAMPLES(PARALLEL_SAMPLES)
) axis_x2_i (
  .clk,
  .reset,
  .data_out(data_out_if),
  .data_in(data_in_if)
);

assign data_out = data_out_if.data;
assign data_out_valid = data_out_if.valid;
assign data_out_if.ready = data_out_ready;

assign data_in_if.data = data_in;
assign data_in_if.valid = data_in_valid;
assign data_in_ready = data_in_if.ready;

endmodule

