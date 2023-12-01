`timescale 1ns / 1ps
module axis_x2_test();


int error_count = 0;

logic reset;
logic clk = 0;
localparam CLK_RATE_HZ = 100_000_000;
always #(0.5s/CLK_RATE_HZ) clk = ~clk;

localparam int SAMPLE_WIDTH = 16;
localparam int PARALLEL_SAMPLES = 2;
localparam int SAMPLE_FRAC_BITS = 14;
localparam int SAMPLE_INT_BITS = SAMPLE_WIDTH - SAMPLE_FRAC_BITS;

Axis_If #(.DWIDTH(SAMPLE_WIDTH*PARALLEL_SAMPLES)) data_out_if();
Axis_If #(.DWIDTH(SAMPLE_WIDTH*PARALLEL_SAMPLES)) data_in_if();

typedef logic signed [SAMPLE_WIDTH-1:0] int_t;
real d_in;
int_t received[$];
int_t expected[$];

sim_util_pkg::generic #(int_t) util;

always @(posedge clk) begin
  if (reset) begin
    data_in_if.data <= '0;
  end else begin
    // send data
    if (data_in_if.ok) begin
      for (int i = 0; i < PARALLEL_SAMPLES; i++) begin
        data_in_if.data[i*SAMPLE_WIDTH+:SAMPLE_WIDTH] <= $urandom_range({SAMPLE_WIDTH{1'b1}});
        d_in = real'(int_t'(data_in_if.data[i*SAMPLE_WIDTH+:SAMPLE_WIDTH]));
        expected.push_front(int_t'(((d_in/(2.0**SAMPLE_FRAC_BITS))**2) * 2.0**(SAMPLE_WIDTH - 2*SAMPLE_INT_BITS)));
      end
    end
    // receive data
    if (data_out_if.ok) begin
      for (int i = 0; i < PARALLEL_SAMPLES; i++) begin
        received.push_front(int_t'(data_out_if.data[i*SAMPLE_WIDTH+:SAMPLE_WIDTH]));
      end
    end
  end
end

task check_results();
  $display("received.size() = %0d", received.size());
  $display("expected.size() = %0d", expected.size());
  if (received.size() != expected.size()) begin
    $warning("mismatched sizes; got a different number of samples than expected");
    error_count = error_count + 1;
  end
  // check the values match
  // casting to uint_t seems to perform a rounding operation, so the test data may be slightly too large
  while (received.size() > 0 && expected.size() > 0) begin
    if (util.abs(expected[$] - received[$]) > 1) begin
      $warning("mismatch: got %x, expected %x", received[$], expected[$]);
      error_count = error_count + 1;
    end
    received.pop_back();
    expected.pop_back();
  end
endtask

axis_x2 #(
  .SAMPLE_WIDTH(SAMPLE_WIDTH),
  .PARALLEL_SAMPLES(PARALLEL_SAMPLES),
  .SAMPLE_FRAC_BITS(SAMPLE_FRAC_BITS)
) dut_i (
  .clk,
  .reset,
  .data_in(data_in_if),
  .data_out(data_out_if)
);

initial begin
  reset <= 1'b1;
  data_in_if.valid <= 1'b0;
  data_out_if.ready <= 1'b1;
  repeat (100) @(posedge clk);
  reset <= 1'b0;
  repeat (2000) begin
    @(posedge clk);
    data_in_if.valid <= $urandom() & 1'b1;
    data_out_if.ready <= $urandom() & 1'b1;
  end
  @(posedge clk);
  data_out_if.ready <= 1'b1;
  data_in_if.valid <= 1'b0;
  repeat (10) @(posedge clk);
  check_results();
  $info("error_count = %d", error_count);
  $finish;
end
endmodule
