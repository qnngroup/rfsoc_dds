`timescale 1ns / 1ps
module sample_discriminator_test();

logic clk = 0;
localparam CLK_RATE_HZ = 100_000_000;
always #(0.5s/CLK_RATE_HZ) clk = ~clk;

logic reset;
logic [15:0] threshold_high, threshold_low;

Axis_If #(.DWIDTH(32)) config_in_if();
Axis_If #(.DWIDTH(16)) data_in_if();
Axis_If #(.DWIDTH(16)) data_out_if();

assign config_in_if.data = {threshold_high, threshold_low};

sample_discriminator #(
  .SAMPLE_WIDTH(16),
  .CLOCK_WIDTH(56)
) dut_i (
  .clk,
  .reset,
  .data_in(data_in_if),
  .data_out(data_out_if),
  .config_in(config_in_if)
);

logic [15:0] data_sent [$];
logic [55:0] timestamps_sent [$];
logic [15:0] data_received [$];
logic [15:0] timestamps_received [$];

logic [55:0] sample_count;
logic [15:0] data_in_d;
logic data_in_valid_d;
logic is_high, is_high_d;
logic new_is_high;

assign new_is_high = is_high & (!is_high_d);

logic [15:0] data_range_low, data_range_high;

always @(posedge clk) begin
  if (reset) begin
    sample_count <= '0;
    data_in_if.data <= '0;
    is_high_d <= '0;
    is_high <= '0;
  end else begin
    data_in_valid_d <= data_in_if.valid;
    if (data_in_if.valid && data_in_if.ready) begin
      data_in_d <= data_in_if.data;
      is_high_d <= is_high;
      if (data_in_if.data > threshold_high) begin
        is_high <= 1'b1;
      end else if (data_in_if.data < threshold_low) begin
        is_high <= 1'b0;
      end
      sample_count <= sample_count + 1'b1;
      data_in_if.data <= $urandom_range(data_range_low, data_range_high);
    end
    if (data_in_valid_d) begin
      if (is_high) begin
        data_sent.push_front(data_in_d & 16'hfff8);
      end
      if (new_is_high) begin
        timestamps_sent.push_front(sample_count);
      end
    end
    if (data_out_if.valid && data_out_if.ready) begin
      if (data_out_if.data[1]) begin
        // timestamp
        timestamps_received.push_front(data_out_if.data & 16'hfffc);
      end else begin
        // data
        data_received.push_front(data_out_if.data & 16'hfff8);
      end
    end
  end
end

// not 100% activity on output
always @(posedge clk) begin
  data_out_if.ready <= $urandom_range(0,1);
end

task send_samples(input int n_samples);
  repeat (n_samples) begin
    data_in_if.valid <= 1'b1;
    @(posedge clk);
    data_in_if.valid <= 1'b0;
    repeat (4) @(posedge clk);
  end
endtask

task check_results();
  logic [55:0] tstamp_temp;
  $display("data_sent.size() = %0d", data_sent.size());
  $display("data_received.size() = %0d", data_received.size());
  if (data_sent.size() != data_received.size()) begin
    $display("mismatch in amount of sent/received data");
    for (int i = data_sent.size() - 1; i >= 0; i--) begin
      $display("data_sent[%0d] = %x", i, data_sent[i]);
    end
    for (int i = data_received.size() - 1; i >= 0; i--) begin
      $display("data_received[%0d] = %x", i, data_received[i]);
    end
  end
  $display("timestamps_sent.size() = %0d", timestamps_sent.size());
  $display("timestamps_received.size() = %0d", timestamps_received.size());
  if (timestamps_sent.size()*4 != timestamps_received.size()) begin
    $display("mismatch in amount of sent/received timestamps");
    for (int i = timestamps_sent.size() - 1; i >= 0; i--) begin
      $display("timestamps_sent[%0d] = %x", i, timestamps_sent[i]);
    end
    for (int i = timestamps_received.size() - 1; i >= 0; i--) begin
      $display("timestamps_received[%0d] = %x", i, timestamps_received[i]);
    end
  end
  while (data_sent.size() > 0 && data_received.size() > 0) begin
    if (data_sent[$] != data_received[$]) begin
      $display("data mismatch error (received %x, sent %x)", data_received[$], data_sent[$]);
    end
    data_sent.pop_back();
    data_received.pop_back();
  end
  while (timestamps_sent.size() > 0 && timestamps_received.size() > 0) begin
    for (int i = 0; i < 4; i++) begin
      tstamp_temp[i*14+:14] = timestamps_received.pop_back() >> 2;
    end
    if (timestamps_sent[$] != tstamp_temp) begin
      $display("timestamp mismatch error (received %x, sent %x)", tstamp_temp, timestamps_sent[$]);
    end
    timestamps_sent.pop_back();
  end
endtask

initial begin
  reset <= 1'b1;
  data_range_low <= 16'h0000;
  data_range_high <= 16'hffff;
  threshold_low <= '0;
  threshold_high <= '0;
  data_in_if.valid <= '0;
  repeat (100) @(posedge clk);
  reset <= 1'b0;
  repeat (50) @(posedge clk);
  send_samples(50);
  repeat (50) @(posedge clk);
  // change amplitudes and threshold to check sample-rejection
  data_range_low <= 16'h00ff;
  data_range_high <= 16'h0fff;
  threshold_low <= 16'h03ff;
  threshold_high <= 16'h07ff;
  config_in_if.valid <= 1'b1;
  @(posedge clk);
  config_in_if.valid <= 1'b0;
  repeat (50) @(posedge clk);
  send_samples(200);
  repeat (50) @(posedge clk);
  check_results();
  $finish;
end

endmodule
