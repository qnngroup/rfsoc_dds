`timescale 1ns / 1ps
module axis_x2_test();

int error_count = 0;

logic reset;
logic clk = 0;
localparam CLK_RATE_HZ = 100_000_000;
always #(0.5s/CLK_RATE_HZ) clk = ~clk;

localparam int SAMPLE_WIDTH = 16;
localparam int PARALLEL_SAMPLES = 2;

Axis_If #(.DWIDTH(SAMPLE_WIDTH*PARALLEL_SAMPLES)) data_out_if();
Axis_If #(.DWIDTH(SAMPLE_WIDTH*PARALLEL_SAMPLES)) data_in_if();

localparam int LATENCY = 4;
logic [SAMPLE_WIDTH*PARALLEL_SAMPLES-1:0] data_out_test [LATENCY];

assign data_out_if.ready = 1;

initial begin
  reset <= 1'b1;
  data_in_if.valid <= 1'b0;
  repeat (100) @(posedge clk);
  reset <= 1'b0;
  repeat (500) @(posedge clk);
  data_in_if.valid <= 1'b1;
  repeat (500) @(posedge clk);
  data_in_if.valid <= 1'b0;
  repeat (10) @(posedge clk);
  data_in_if.valid <= 1'b1;
  repeat (1000) @(posedge clk);
  $info("error_count = %d", error_count);
  $finish;
end

typedef logic [SAMPLE_WIDTH-1:0] uint_t;

always @(posedge clk) begin
  if (reset) begin
    data_in_if.data <= '0;
  end else if (data_in_if.ready && data_in_if.valid) begin
    for (int i = 0; i < PARALLEL_SAMPLES; i++) begin
      data_in_if.data[i*SAMPLE_WIDTH+:SAMPLE_WIDTH] <= $urandom_range({SAMPLE_WIDTH{1'b1}});
    end
    for (int j = 0; j < LATENCY-1; j++) begin
      data_out_test[j] <= data_out_test[j+1];
    end
    for (int i = 0; i < PARALLEL_SAMPLES; i++) begin
      data_out_test[LATENCY-1][i*SAMPLE_WIDTH+:SAMPLE_WIDTH] <= uint_t'(((real'(data_in_if.data[i*SAMPLE_WIDTH+:SAMPLE_WIDTH])/(2.0**15))**2) * 2.0**14);
    end
  end
end

always @(posedge clk) begin
  if (data_out_if.valid && data_out_if.ready) begin
    // compare output
    for (int i = 0; i < PARALLEL_SAMPLES; i++) begin
      // casting to uint_t seems to perform a rounding operation, so the test data may be slightly too large
      if ((data_out_test[0][i*SAMPLE_WIDTH+:SAMPLE_WIDTH] - data_out_if.data[i*SAMPLE_WIDTH+:SAMPLE_WIDTH]) > 1) begin
        $warning("mismatch on sample %d: got %x, expected %x", i, data_out_if.data[i*SAMPLE_WIDTH+:SAMPLE_WIDTH], data_out_test[0][i*SAMPLE_WIDTH+:SAMPLE_WIDTH]);
        error_count = error_count + 1;
      end
    end
  end
end


axis_x2 #(
  .SAMPLE_WIDTH(SAMPLE_WIDTH),
  .PARALLEL_SAMPLES(PARALLEL_SAMPLES)
) dut_i (
  .clk,
  .reset,
  .data_in(data_in_if),
  .data_out(data_out_if)
);
endmodule
