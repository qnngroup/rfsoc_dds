`timescale 1ns / 1ps
module noise_event_tracker_test();

logic clk = 0;
localparam CLK_RATE_HZ = 100_000_000;
always #(0.5s/CLK_RATE_HZ) clk = ~clk;

logic reset;
logic start, stop;
logic [15:0] threshold_high, threshold_low;

Axis_If #(.DWIDTH(34)) config_in_if();
Axis_If #(.DWIDTH(16)) data_in_00_if();
Axis_If #(.DWIDTH(16)) data_in_02_if();
Axis_If #(.DWIDTH(128)) data_out_if();

assign config_in_if.data = {start, stop, threshold_high, threshold_low};

noise_event_tracker #(
  .BUFFER_DEPTH(1024),
  .SAMPLE_WIDTH(16),
  .AXI_MM_WIDTH(128),
  .CLOCK_WIDTH(56)
) dut_i (
  .clk,
  .reset,
  .data_in_00(data_in_00_if),
  .data_in_02(data_in_02_if),
  .data_out(data_out_if),
  .config_in(config_in_if)
);

logic [15:0] data_sent [$];
logic [15:0] timestamps_sent [$];
logic [15:0] data_received [$];
logic [15:0] timestamps_received [$];

logic [1:0][55:0] sample_count;
logic [1:0][15:0] data_in_d;
logic [1:0] data_in_valid_d;
logic [1:0] is_high, is_high_d;
logic [1:0] new_is_high;

assign new_is_high = is_high & (~is_high_d);

logic [15:0] data_range_low, data_range_high;

always @(posedge clk) begin
  if (reset) begin
    sample_count <= '0;
    data_in_00_if.data <= '0;
    data_in_02_if.data <= '0;
    is_high_d <= '0;
    is_high <= '0;
  end else begin
    data_in_valid_d <= {data_in_02_if.valid, data_in_00_if.valid};
    if (data_in_00_if.valid && data_in_00_if.ready) begin
      data_in_d[0] <= data_in_00_if.data;
      is_high_d[0] <= is_high[0];
      if (data_in_00_if.data > threshold_high) begin
        is_high[0] <= 1'b1;
      end else if (data_in_00_if.data < threshold_low) begin
        is_high[0] <= 1'b0;
      end
      sample_count[0] <= sample_count[0] + 1'b1;
      data_in_00_if.data <= $urandom_range(data_range_low, data_range_high);
    end
    if (data_in_02_if.valid && data_in_02_if.ready) begin
      data_in_d[1] <= data_in_02_if.data;
      is_high_d[1] <= is_high[1];
      if (data_in_02_if.data > threshold_high) begin
        is_high[1] <= 1'b1;
      end else if (data_in_02_if.data < threshold_low) begin
        is_high[1] <= 1'b0;
      end
      sample_count[1] <= sample_count[1] + 1'b1;
      data_in_02_if.data <= $urandom_range(data_range_low, data_range_high);
    end
    // save data that was sent
    for (int i = 0; i < 2; i++) begin
      if (data_in_valid_d[i]) begin
        if (is_high[i]) begin
          data_sent.push_front({data_in_d[i][15:3], new_is_high[i], 1'b0, 1'(i)});
        end
        if (new_is_high[i]) begin
          for (int j = 0; j < 4; j++) begin
            timestamps_sent.push_front({sample_count[i][14*j+:14], 1'b1, 1'(i)});
          end
        end
      end
    end
    if (data_out_if.valid && data_out_if.ready) begin
      for (int i = 0; i < 8; i++) begin
        if (data_out_if.data[16*i+1]) begin
          // timestamp
          timestamps_received.push_front(data_out_if.data[16*i+:16]);
        end else begin
          // data
          data_received.push_front(data_out_if.data[16*i+:16]);
        end
      end
    end
  end
end

task send_samples_together(input int n_samples);
  repeat (n_samples) begin
    data_in_00_if.valid <= 1'b1;
    data_in_02_if.valid <= 1'b1;
    @(posedge clk);
    data_in_00_if.valid <= 1'b0;
    data_in_02_if.valid <= 1'b0;
    repeat (4) @(posedge clk);
  end
endtask

task send_samples_separate(input int n_samples);
  repeat (n_samples) begin
    if ($urandom_range(0,1) < 1) begin
      data_in_00_if.valid <= 1'b1;
      @(posedge clk);
      data_in_00_if.valid <= 1'b0;
      repeat (2) @(posedge clk);
      data_in_02_if.valid <= 1'b1;
      @(posedge clk);
      data_in_02_if.valid <= 1'b0;
      repeat (2) @(posedge clk);
    end else begin
      data_in_02_if.valid <= 1'b1;
      @(posedge clk);
      data_in_02_if.valid <= 1'b0;
      repeat (2) @(posedge clk);
      data_in_00_if.valid <= 1'b1;
      @(posedge clk);
      data_in_00_if.valid <= 1'b0;
      repeat (2) @(posedge clk);
    end
  end
endtask

task do_readout();
  data_out_if.ready <= 1'b0;
  stop <= 1'b1;
  config_in_if.valid <= 1'b1;
  @(posedge clk);
  stop <= 1'b0;
  config_in_if.valid <= 1'b0;
  repeat (500) @(posedge clk);
  data_out_if.ready <= 1'b1;
  repeat ($urandom_range(10,50)) @(posedge clk);
  data_out_if.ready <= 1'b0;
  repeat ($urandom_range(5,15)) @(posedge clk);
  data_out_if.ready <= 1'b1;
  while (!data_out_if.last) @(posedge clk);
endtask

task check_results();
  logic current_channel;
  logic [15:0] temp_q [$];
  $display("data_sent.size() = %0d", data_sent.size());
  $display("data_received.size() = %0d", data_received.size());
  if (data_sent.size() != data_received.size()) begin
    $display("mismatch in amount of sent/received data");
    // for (int i = data_sent.size() - 1; i >= 0; i--) begin
    //   $display("data_sent[%0d] = %x", i, data_sent[i]);
    // end
    // for (int i = data_received.size() - 1; i >= 0; i--) begin
    //   $display("data_received[%0d] = %x", i, data_received[i]);
    // end
  end
  $display("timestamps_sent.size() = %0d", timestamps_sent.size());
  $display("timestamps_received.size() = %0d", timestamps_received.size());
  if (timestamps_sent.size() != timestamps_received.size()) begin
    $display("mismatch in amount of sent/received timestamps");
    // for (int i = timestamps_sent.size() - 1; i >= 0; i--) begin
    //   $display("timestamps_sent[%0d] = %x", i, timestamps_sent[i]);
    // end
    // for (int i = timestamps_received.size() - 1; i >= 0; i--) begin
    //   $display("timestamps_received[%0d] = %x", i, timestamps_received[i]);
    // end
  end
  while (data_sent.size() > 0 && data_received.size() > 0) begin
    // data from channel 0 can be reordered with data from channel 2
    if (data_sent[$] != data_received[$]) begin
      $display("data mismatch error (received %x, sent %x)", data_received[$], data_sent[$]);
    end
    data_sent.pop_back();
    data_received.pop_back();
  end
  while (timestamps_sent.size() > 0 && timestamps_received.size() > 0) begin
    if (timestamps_sent[$] != timestamps_received[$]) begin
      $display("timestamp mismatch error (received %x, sent %x)", timestamps_received[$], timestamps_sent[$]);
    end
    timestamps_sent.pop_back();
    timestamps_received.pop_back();
  end
endtask

initial begin
  reset <= 1'b1;
  start <= 1'b0;
  stop <= 1'b0;
  data_range_low <= 16'h0000;
  data_range_high <= 16'hffff;
  threshold_low <= '0;
  threshold_high <= '0;
  data_in_00_if.valid <= '0;
  data_in_02_if.valid <= '0;
  repeat (100) @(posedge clk);
  reset <= 1'b0;
  repeat (50) @(posedge clk);
  // start
  start <= 1'b1;
  config_in_if.valid <= 1'b1;
  @(posedge clk);
  start <= 1'b0;
  config_in_if.valid <= 1'b0;
  repeat (100) @(posedge clk);
  // send samples
  send_samples_together(50);
  repeat (50) @(posedge clk);
  send_samples_separate(30);
  repeat (50) @(posedge clk);
  do_readout();
  $display("######################################################");
  $display("# checking results for test with constant noise      #");
  $display("######################################################");
  check_results();
  // change amplitudes and threshold to check sample-rejection
  data_range_low <= 16'h00ff;
  data_range_high <= 16'h0fff;
  threshold_low <= 16'h03ff;
  threshold_high <= 16'h07ff;
  config_in_if.valid <= 1'b1;
  @(posedge clk);
  config_in_if.valid <= 1'b0;
  repeat (100) @(posedge clk);
  // start
  start <= 1'b1;
  config_in_if.valid <= 1'b1;
  @(posedge clk);
  start <= 1'b0;
  config_in_if.valid <= 1'b0;
  repeat (50) @(posedge clk);
  send_samples_together(200);
  repeat (50) @(posedge clk);
  send_samples_separate(200);
  do_readout();
  $display("######################################################");
  $display("# checking results for test with intermittent noise  #");
  $display("######################################################");
  check_results();
  $finish;
end

endmodule
