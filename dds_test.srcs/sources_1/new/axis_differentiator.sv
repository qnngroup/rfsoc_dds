// axis_differentiator - Reed Foster
// computes first-order finite difference to approximate time derivative of
// input signal
module axis_differentiator #(
  parameter int SAMPLE_WIDTH = 16,
  parameter int PARALLEL_SAMPLES = 2
) (
  input wire clk, reset,
  Axis_If.Slave_Simple data_in,
  Axis_If.Master_Simple data_out
);

// register signals to infer DSPs
// can't do packed arrays because of signed type
logic signed [SAMPLE_WIDTH-1:0] data_in_reg [PARALLEL_SAMPLES]; // 0Q16, 2Q14
logic signed [SAMPLE_WIDTH-1:0] data_in_reg_d; // 0Q16, 2Q14
logic signed [SAMPLE_WIDTH:0] diff [PARALLEL_SAMPLES]; // 0Q16+0Q16 = 1Q16, 2Q14+2Q14 = 3Q14
logic signed [SAMPLE_WIDTH-1:0] diff_d [PARALLEL_SAMPLES]; // 1Q15, 3Q13
logic [3:0] valid_d;

always_ff @(posedge clk) begin
  if (reset) begin
    valid_d <= '0;
    data_in_reg_d <= '0;
    for (int i = 0; i < PARALLEL_SAMPLES; i++) begin
      data_in_reg[i] <= '0;
    end
  end else begin
    if (data_in.ok) begin
      for (int i = 0; i < PARALLEL_SAMPLES; i++) begin
        data_in_reg[i] <= data_in.data[i*SAMPLE_WIDTH+:SAMPLE_WIDTH]; // 0Q16, 2Q14
      end
      data_in_reg_d <= data_in_reg[PARALLEL_SAMPLES-1]; // 0Q16, 2Q14
    end
    if (data_out.ready || (!data_out.valid)) begin
      for (int i = 0; i < PARALLEL_SAMPLES; i++) begin
        diff[i] <= data_in_reg[i] - ((i == 0) ? data_in_reg_d : data_in_reg[i-1]); // 1Q16
        diff_d[i] <= diff[i][SAMPLE_WIDTH-:SAMPLE_WIDTH]; // 1Q15
        data_out.data[i*SAMPLE_WIDTH+:SAMPLE_WIDTH] <= diff_d[i];
      end
      valid_d <= {valid_d[2:0], data_in.ok};
    end
  end
end

assign data_out.valid = valid_d[3];
assign data_in.ready = data_out.ready;

endmodule
