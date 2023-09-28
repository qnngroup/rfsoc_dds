`timescale 1ns / 1ps
module fifo_test();

int error_count = 0;

logic reset;
logic clk = 0;
localparam CLK_RATE_HZ = 100_000_000;
always #(0.5s/CLK_RATE_HZ) clk = ~clk;

localparam int DATA_WIDTH = 16;
localparam int ADDR_WIDTH = 5;

Axis_If #(.DWIDTH(DATA_WIDTH)) data_out_if();
Axis_If #(.DWIDTH(DATA_WIDTH)) data_in_if();

initial begin
  reset <= 1'b1;
  data_in_if.valid <= 1'b0;
  data_out_if.ready <= 1'b0;
  repeat (100) @(posedge clk);
  reset <= 1'b0;
  repeat (50) @(posedge clk);

  ///////////////////////////////////
  // completely fill, then completely
  // empty the fifo (i.e. no overlapping
  // reads/writes)
  ///////////////////////////////////

  // fill up the fifo
  data_in_if.valid <= 1'b1;
  data_out_if.ready <= 1'b0;
  repeat (50) @(posedge clk);

  // wait
  data_in_if.valid <= 1'b0;
  repeat (50) @(posedge clk);

  // clear the fifo
  data_out_if.ready <= 1'b1;
  repeat (50) @(posedge clk);

  // wait
  data_out_if.ready <= 1'b0;
  repeat (50) @(posedge clk);

  ///////////////////////////////////
  // overlapped reading and writing
  ///////////////////////////////////
  data_in_if.valid <= 1'b1;
  repeat (20) @(posedge clk);
  data_out_if.ready <= 1'b1;
  repeat (15) @(posedge clk);

  // stop writing
  data_in_if.valid <= 1'b0;
  repeat (15) @(posedge clk);

  // stop reading and start writing
  data_out_if.ready <= 1'b0;
  data_in_if.valid <= 1'b1;
  repeat (20) @(posedge clk);
  data_out_if.ready <= 1'b1;
  repeat (20) @(posedge clk);
  $info("error_count = %d", error_count);
  $finish;
end

logic [DATA_WIDTH-1:0] queue [$];
logic [DATA_WIDTH-1:0] input_sample = '0, output_sample = '0;

always @(posedge clk) begin
  if (reset) begin
    data_in_if.data <= '0;
    input_sample <= '0;
  end else if (data_in_if.ready && data_in_if.valid) begin
    input_sample = $urandom_range({DATA_WIDTH{1'b1}});
    queue.push_front(input_sample);
    data_in_if.data <= input_sample;
  end
end

//logic [DATA_WIDTH-1:0] data_out;
always @(posedge clk) begin
  if (data_out_if.valid && data_out_if.ready) begin
    //data_out <= data_out_if.data;
    // compare output
    output_sample <= queue.pop_back();
    if (output_sample !== data_out_if.data) begin
      $warning("mismatch: got %x, expected %x", data_out_if.data, output_sample);
      error_count = error_count + 1;
    end
  end
end

fifo #(
  .DATA_WIDTH(DATA_WIDTH),
  .ADDR_WIDTH(ADDR_WIDTH)
) dut_i (
  .clk,
  .reset,
  .data_in(data_in_if),
  .data_out(data_out_if)
);
endmodule
