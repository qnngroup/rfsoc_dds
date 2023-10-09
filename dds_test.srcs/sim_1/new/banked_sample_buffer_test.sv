`timescale 1ns / 1ps
module buffer_bank_test ();

logic clk = 0;
localparam CLK_RATE_HZ = 100_000_000;
always #(0.5s/CLK_RATE_HZ) clk = ~clk;

logic reset;

logic start, stop;
logic full;

Axis_If #(.DWIDTH(16), .PARALLEL_CHANNELS(1)) data_in ();
Axis_If #(.DWIDTH(16), .PARALLEL_CHANNELS(1)) data_out ();

buffer_bank #(
  .BUFFER_DEPTH(1024),
  .PARALLEL_SAMPLES(2),
  .SAMPLE_WIDTH(16)
) dut_i (
  .clk,
  .reset,
  .data_in,
  .data_out,
  .start,
  .stop,
  .full
);

int sample_count;
logic [15:0] data_sent [$];
logic [15:0] data_received [$];

always @(posedge clk) begin
  if (reset) begin
    sample_count <= 0;
    data_in.data <= '0;
  end else begin
    // send data
    if (data_in.valid && data_in.ready) begin
      sample_count <= sample_count + 1;
      data_in.data <= $urandom_range(1<<16);
    end
    // save data that was sent
    if (data_in.valid) begin
      data_sent.push_front(data_in.data);
    end
    if (data_out.valid && data_out.ready) begin
      data_received.push_front(data_out.data);
    end
  end
end

task send_samples(input int n_samples, input int delay);
  repeat (n_samples) begin
    data_in.valid <= 1'b1;
    @(posedge clk);
    data_in.valid <= 1'b0;
    repeat (delay) @(posedge clk);
  end
endtask

task do_readout(input bit wait_for_last);
  data_out.ready <= 1'b0;
  stop <= 1'b1;
  @(posedge clk);
  stop <= 1'b0;
  repeat (500) @(posedge clk);
  data_out.ready <= 1'b1;
  repeat ($urandom_range(2,4)) @(posedge clk);
  data_out.ready <= 1'b0;
  repeat ($urandom_range(1,3)) @(posedge clk);
  data_out.ready <= 1'b1;
  if (wait_for_last) begin
    while (!data_out.last) @(posedge clk);
  end else begin
    repeat (500) @(posedge clk);
  end
  @(posedge clk);
endtask

task check_results();
  $display("data_sent.size() = %0d", data_sent.size());
  $display("data_received.size() = %0d", data_received.size());
  if ((data_sent.size() + 1) != data_received.size()) begin
    $warning("mismatch in amount of sent/received data");
  end
  if (data_received[$] != data_sent.size()) begin
    $warning("incorrect sample count reported by buffer");
  end
  data_received.pop_back(); // remove sample count
  while (data_sent.size() > 0 && data_received.size() > 0) begin
    // data from channel 0 can be reordered with data from channel 2
    if (data_sent[$] != data_received[$]) begin
      $warning("data mismatch error (received %x, sent %x)", data_received[$], data_sent[$]);
    end
    data_sent.pop_back();
    data_received.pop_back();
  end
endtask

initial begin
  reset <= 1'b1;
  start <= 1'b0;
  stop <= 1'b0;
  data_in.valid <= '0;
  repeat (100) @(posedge clk);
  reset <= 1'b0;
  repeat (50) @(posedge clk);
  // start
  start <= 1'b1;
  @(posedge clk);
  start <= 1'b0;
  repeat (100) @(posedge clk);
  // send samples
  send_samples(128, 3);
  repeat (50) @(posedge clk);
  do_readout(1'b1);
  $display("######################################################");
  $display("# checking results for test with a few samples       #");
  $display("######################################################");
  check_results();
  // do more tests

  // test with one sample
  // start
  start <= 1'b1;
  @(posedge clk);
  start <= 1'b0;
  repeat (100) @(posedge clk);
  // send samples
  send_samples(1, 4);
  repeat (50) @(posedge clk);
  do_readout(1'b0); // don't wait for last signal
  $display("######################################################");
  $display("# checking results for test with one sample          #");
  $display("######################################################");
  check_results();

  // test with no samples
  // start
  start <= 1'b1;
  @(posedge clk);
  start <= 1'b0;
  repeat (100) @(posedge clk);
  // don't send samples
  repeat (50) @(posedge clk);
  do_readout(1'b0); // don't wait for last signal
  $display("######################################################");
  $display("# checking results for test with no samples          #");
  $display("######################################################");
  check_results();

  // fill up buffer
  // start
  start <= 1'b1;
  @(posedge clk);
  start <= 1'b0;
  repeat (100) @(posedge clk);
  // send samples
  send_samples(1024, 1);
  repeat (50) @(posedge clk);
  do_readout(1'b1);
  $display("######################################################");
  $display("# checking results for test with 1024 samples        #");
  $display("######################################################");
  check_results();
  repeat (500) @(posedge clk);
  $finish;

end

endmodule
