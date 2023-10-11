`timescale 1ns / 1ps
module banked_sample_buffer_test ();

logic clk = 0;
localparam CLK_RATE_HZ = 100_000_000;
always #(0.5s/CLK_RATE_HZ) clk = ~clk;

logic reset;

logic start, stop;
logic [2:0] banking_mode;

assign config_in.data = {banking_mode, start, stop};

Axis_Parallel_If #(.DWIDTH(16), .PARALLEL_CHANNELS(8)) data_in ();
Axis_If #(.DWIDTH(16)) data_out ();
Axis_If #(.DWIDTH(4)) config_in ();

banked_sample_buffer #(
  .N_CHANNELS(8),
  .BUFFER_DEPTH(1024),
  .PARALLEL_SAMPLES(1),
  .SAMPLE_WIDTH(16)
) dut_i (
  .clk,
  .reset,
  .data_in,
  .data_out,
  .config_in
);


int sample_count [8];
logic [15:0] data_sent [8][$];
logic [15:0] data_received [$];

always @(posedge clk) begin
  for (int i = 0; i < 8; i++) begin
    if (reset) begin
      sample_count[i] <= 0;
      data_in.data[i] <= '0;
    end else begin
      if (data_in.ok[i]) begin
        // send new data
        sample_count[i] <= sample_count[i] + 1;
        data_in.data[i] <= $urandom_range(1<<16);
        // save data that was sent
        data_sent[i].push_front(data_in.data[i]);
      end
    end
  end
  // save all data in the same buffer and postprocess it later
  if (data_out.ok) begin
    data_received.push_front(data_out.data);
  end
end

task send_samples_full_rate(input int n_samples);
  data_in.valid <= '1;
  repeat (n_samples) begin
    @(posedge clk);
  end
  data_in.valid <= '0;
endtask

task send_samples_rand_arrivals(input int n_cycles);
  repeat (n_cycles) begin
    data_in.valid <= $urandom_range(1<<8);
    @(posedge clk);
  end
endtask

task do_readout(input bit wait_for_last, input int wait_cycles);
  data_out.ready <= 1'b0;
  stop <= 1'b1;
  config_in.valid <= 1'b1;
  @(posedge clk);
  stop <= 1'b0;
  config_in.valid <= 1'b0;
  repeat (500) @(posedge clk);
  data_out.ready <= 1'b1;
  repeat ($urandom_range(2,4)) @(posedge clk);
  data_out.ready <= 1'b0;
  repeat ($urandom_range(1,3)) @(posedge clk);
  data_out.ready <= 1'b1;
  if (wait_for_last) begin
    while (!data_out.last) @(posedge clk);
  end else begin
    repeat (wait_cycles) @(posedge clk);
  end
  @(posedge clk);
endtask

task check_results();
  logic [15:0] temp_sample;
  int current_channel, n_samples;
  for (int i = 0; i < 8; i++) begin
    $display("data_sent[%0d].size() = %0d", i, data_sent[i].size());
  end
  $display("data_received.size() = %0d", data_received.size());
  while (data_received.size() > 0) begin
    temp_sample = data_received.pop_back();
    current_channel = temp_sample & 3'h7;
    n_samples = temp_sample >> 3;
    $display("processing new bank with %0d samples from channel %0d", n_samples, current_channel);
    for (int i = 0; i < n_samples; i++) begin
      if (data_sent[current_channel][$] != data_received[$]) begin
        $display("data mismatch error (channel = %0d, sample = %0d, received %x, sent %x)", current_channel, i, data_received[$], data_sent[current_channel][$]);
      end
      data_sent[current_channel].pop_back();
      data_received.pop_back();
    end
  end
  for (int i = 0; i < 8; i++) begin
    // flush out any remaining samples in data_sent queue
    // TODO actually implement a check to make sure we got everything we sent
    while (data_sent[i].size() > 0) data_sent[i].pop_back();
  end
endtask

initial begin
  reset <= 1'b1;
  start <= 1'b0;
  stop <= 1'b0;
  banking_mode <= '0; // only enable channel 0
  data_in.valid <= '0;
  repeat (100) @(posedge clk);
  reset <= 1'b0;
  repeat (50) @(posedge clk);
  // start
  start <= 1'b1;
  config_in.valid <= 1'b1;
  @(posedge clk);
  start <= 1'b0;
  config_in.valid <= 1'b0;
  repeat (100) @(posedge clk);
  // send samples
  send_samples_full_rate(3);
  repeat (50) @(posedge clk);
  do_readout(1'b1, 500);
  $display("######################################################");
  $display("# checking results for test with a few samples at    #");
  $display("# full rate, with only channel 0 enabled             #");
  $display("######################################################");
  check_results();
  // do more tests

  // start
  start <= 1'b1;
  config_in.valid <= 1'b1;
  @(posedge clk);
  start <= 1'b0;
  config_in.valid <= 1'b0;
  repeat (100) @(posedge clk);
  // send samples
  send_samples_full_rate(1024*7+24);
  repeat (50) @(posedge clk);
  do_readout(1'b1, 500);
  $display("######################################################");
  $display("# checking results for test with many samples at     #");
  $display("# full rate, with only channel 0 enabled             #");
  $display("######################################################");
  check_results();

  // start
  start <= 1'b1;
  banking_mode <= 3'b1;
  config_in.valid <= 1'b1;
  @(posedge clk);
  start <= 1'b0;
  config_in.valid <= 1'b0;
  repeat (100) @(posedge clk);
  // send samples
  send_samples_full_rate(25);
  repeat (50) @(posedge clk);
  do_readout(1'b1, 500);
  $display("######################################################");
  $display("# checking results for test with a few samples at    #");
  $display("# full rate, with channels 0 and 1 enabled           #");
  $display("######################################################");
  check_results();

  // start
  start <= 1'b1;
  banking_mode <= 3'b1;
  config_in.valid <= 1'b1;
  @(posedge clk);
  start <= 1'b0;
  config_in.valid <= 1'b0;
  repeat (100) @(posedge clk);
  // send samples
  send_samples_full_rate(512*7+12);
  repeat (50) @(posedge clk);
  do_readout(1'b1, 500);
  $display("######################################################");
  $display("# checking results for test with many samples at     #");
  $display("# full rate, with channels 0 and 1 enabled           #");
  $display("######################################################");
  check_results();

  // start
  start <= 1'b1;
  banking_mode <= 3'b10;
  config_in.valid <= 1'b1;
  @(posedge clk);
  start <= 1'b0;
  config_in.valid <= 1'b0;
  repeat (100) @(posedge clk);
  // send samples
  send_samples_full_rate(4);
  repeat (50) @(posedge clk);
  do_readout(1'b1, 500);
  $display("######################################################");
  $display("# checking results for test with a few samples at    #");
  $display("# full rate, with channels 0-3 enabled               #");
  $display("######################################################");
  check_results();

  // start
  start <= 1'b1;
  banking_mode <= 3'b10;
  config_in.valid <= 1'b1;
  @(posedge clk);
  start <= 1'b0;
  config_in.valid <= 1'b0;
  repeat (100) @(posedge clk);
  // send samples
  send_samples_full_rate(256*7+6);
  repeat (50) @(posedge clk);
  do_readout(1'b1, 500);
  $display("######################################################");
  $display("# checking results for test with many samples at     #");
  $display("# full rate, with channels 0-3 enabled               #");
  $display("######################################################");
  check_results();

  // start
  start <= 1'b1;
  banking_mode <= 3'b11;
  config_in.valid <= 1'b1;
  @(posedge clk);
  start <= 1'b0;
  config_in.valid <= 1'b0;
  repeat (100) @(posedge clk);
  // send samples
  send_samples_full_rate(49);
  repeat (50) @(posedge clk);
  do_readout(1'b1, 500);
  $display("######################################################");
  $display("# checking results for test with a few samples at    #");
  $display("# full rate, with all channels enabled               #");
  $display("######################################################");
  check_results();

  // start
  start <= 1'b1;
  banking_mode <= 3'b11;
  config_in.valid <= 1'b1;
  @(posedge clk);
  start <= 1'b0;
  config_in.valid <= 1'b0;
  repeat (100) @(posedge clk);
  // send samples
  send_samples_full_rate(128*7+3);
  repeat (50) @(posedge clk);
  do_readout(1'b1, 500);
  $display("######################################################");
  $display("# checking results for test with many samples at     #");
  $display("# full rate, with all channels enabled               #");
  $display("######################################################");
  check_results();
  $finish;
end

endmodule

// test for the individual banks
`timescale 1ns / 1ps
module buffer_bank_test ();

logic clk = 0;
localparam CLK_RATE_HZ = 100_000_000;
always #(0.5s/CLK_RATE_HZ) clk = ~clk;

logic reset;

logic start, stop;
logic full;

Axis_If #(.DWIDTH(16)) data_in ();
Axis_If #(.DWIDTH(16)) data_out ();

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
