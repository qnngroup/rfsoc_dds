import sim_util_pkg::*;

`timescale 1ns / 1ps
module sample_discriminator_test();

logic clk = 0;
localparam CLK_RATE_HZ = 100_000_000;
always #(0.5s/CLK_RATE_HZ) clk = ~clk;

logic reset;

int error_count = 0;

localparam int N_CHANNELS = 2;
localparam int SAMPLE_WIDTH = 16;
localparam int PARALLEL_SAMPLES = 4;
localparam int SAMPLE_INDEX_WIDTH = 14;
localparam int CLOCK_WIDTH = 50;

sim_util_pkg::sample_discriminator_util #(.SAMPLE_WIDTH(SAMPLE_WIDTH), .PARALLEL_SAMPLES(PARALLEL_SAMPLES)) util;

Axis_If #(.DWIDTH(N_CHANNELS*SAMPLE_WIDTH*2)) config_in();
Axis_Parallel_If #(.DWIDTH(SAMPLE_WIDTH*PARALLEL_SAMPLES), .PARALLEL_CHANNELS(N_CHANNELS)) data_in();
Axis_Parallel_If #(.DWIDTH(SAMPLE_WIDTH*PARALLEL_SAMPLES), .PARALLEL_CHANNELS(N_CHANNELS)) data_out();
Axis_Parallel_If #(.DWIDTH(SAMPLE_INDEX_WIDTH+CLOCK_WIDTH), .PARALLEL_CHANNELS(N_CHANNELS)) timestamps_out();

logic [N_CHANNELS-1:0][SAMPLE_WIDTH-1:0] threshold_high, threshold_low;
always_comb begin
  for (int i = 0; i < N_CHANNELS; i++) begin
    config_in.data[2*SAMPLE_WIDTH*i+:2*SAMPLE_WIDTH] = {threshold_high[i], threshold_low[i]};
  end
end

logic reset_state;

sample_discriminator #(
  .SAMPLE_WIDTH(SAMPLE_WIDTH),
  .PARALLEL_SAMPLES(PARALLEL_SAMPLES),
  .N_CHANNELS(N_CHANNELS),
  .SAMPLE_INDEX_WIDTH(SAMPLE_INDEX_WIDTH),
  .CLOCK_WIDTH(CLOCK_WIDTH)
) dut_i (
  .clk,
  .reset,
  .data_in,
  .data_out,
  .timestamps_out,
  .config_in,
  .reset_state
);

logic [SAMPLE_WIDTH*PARALLEL_SAMPLES-1:0] data_sent [N_CHANNELS][$];
logic [SAMPLE_WIDTH*PARALLEL_SAMPLES-1:0] data_received [N_CHANNELS][$];
logic [SAMPLE_INDEX_WIDTH+CLOCK_WIDTH-1:0] timestamps_received [N_CHANNELS][$];

logic [N_CHANNELS-1:0][SAMPLE_WIDTH-1:0] data_range_low, data_range_high;

// save data that was sent to DUT
always @(posedge clk) begin
  if (reset) begin
    data_in.data <= '0;
  end else begin
    for (int i = 0; i < N_CHANNELS; i++) begin
      if (data_in.ok[i]) begin
        data_sent[i].push_front(data_in.data[i]);
        for (int j = 0; j < PARALLEL_SAMPLES; j++) begin
          data_in.data[i][j*SAMPLE_WIDTH+:SAMPLE_WIDTH] <= $urandom_range(data_range_low[i], data_range_high[i]);
        end
      end
      if (data_out.ok[i]) begin
        data_received[i].push_front(data_out.data[i]);
      end
      if (timestamps_out.ok[i]) begin
        timestamps_received[i].push_front(timestamps_out.data[i]);
      end
    end
  end
end

// always accept data, which is the expected behavior of the sample buffer
// that will be connected to the sample discriminator
assign data_out.ready = '1;
assign timestamps_out.ready = '1;

task check_results (
  input logic [N_CHANNELS-1:0][SAMPLE_WIDTH-1:0] threshold_low,
  input logic [N_CHANNELS-1:0][SAMPLE_WIDTH-1:0] threshold_high,
  inout logic [N_CHANNELS-1:0][CLOCK_WIDTH-1:0] timer,
  inout logic [N_CHANNELS-1:0][SAMPLE_INDEX_WIDTH-1:0] sample_index,
  inout logic [N_CHANNELS-1:0] is_high
);
  for (int i = 0; i < N_CHANNELS; i++) begin
    // process each channel, first check that we received an appropriate amount of data
    $display("data_sent[%0d].size() = %0d", i, data_sent[i].size());
    $display("data_received[%0d].size() = %0d", i, data_received[i].size());
    $display("timestamps_received[%0d].size() = %0d", i, timestamps_received[i].size());
    if (data_sent[i].size() < data_received[i].size()) begin
      $error("more data received than sent. this is not possible");
      error_count = error_count + 1;
    end

    // now process the sent/received data to check the timestamps and check for any mismatched data
    while (data_sent[i].size() > 0) begin
      if (util.any_above_high(data_sent[i][$], threshold_high[i])) begin
        if (!is_high[i]) begin
          // new high, we should get a timestamp
          if (timestamps_received[i].size() > 0) begin
            if (timestamps_received[i][$] != {timer[i], sample_index[i]}) begin
              $warning("mismatched timestamp: got %x, expected %x", timestamps_received[i][$], {timer[i], sample_index[i]});
              error_count = error_count + 1;
            end
            timestamps_received[i].pop_back();
          end else begin
            $warning("expected a timestamp (with value %x), but no more timestamps left", {timer[i], sample_index[i]});
            error_count = error_count + 1;
          end
        end
        is_high[i] = 1'b1;
      end else if (util.all_below_low(data_sent[i][$], threshold_low[i])) begin
        is_high[i] = 1'b0;
      end
      if (is_high[i]) begin
        if (data_sent[i][$] != data_received[i][$]) begin
          $warning("mismatched data: got %x, expected %x", data_received[i][$], data_sent[i][$]);
          error_count = error_count + 1;
        end
        data_received[i].pop_back();
        sample_index[i] = sample_index[i] + 1'b1;
      end
      data_sent[i].pop_back();
      timer[i] = timer[i] + 1'b1;
    end
    $display("after processing:");
    $display("data_sent[%0d].size() = %0d", i, data_sent[i].size());
    $display("data_received[%0d].size() = %0d", i, data_received[i].size());
    $display("timestamps_received[%0d].size() = %0d", i, timestamps_received[i].size());
  end
endtask

logic [N_CHANNELS-1:0][CLOCK_WIDTH-1:0] timer;
logic [N_CHANNELS-1:0][SAMPLE_INDEX_WIDTH-1:0] sample_index;
logic [N_CHANNELS-1:0] is_high;

initial begin
  reset <= 1'b1;
  for (int i = 0; i < N_CHANNELS; i++) begin
    data_range_low[i] <= '0;
    data_range_high[i] <= 16'h7fff;
  end
  threshold_low <= '0;
  threshold_high <= '0;
  data_in.valid <= '0;
  config_in.valid <= '0;
  reset_state <= '0;
  is_high <= '0;
  timer <= '0;
  sample_index <= '0;
  repeat (100) @(posedge clk);
  reset <= 1'b0;
  reset_state <= 1'b1;
  @(posedge clk);
  reset_state <= '0;
  repeat (50) @(posedge clk);
  config_in.valid <= 1'b1;
  @(posedge clk);
  config_in.valid <= 1'b0;
  repeat (50) @(posedge clk);

  for (int i = 0; i < 3; i++) begin
    // loop a couple times, resetting the state to make sure we get the
    // correct behavior
    // send a bunch of data with discrimination disabled
    data_in.send_samples(clk, 10, 1'b1, 1'b1);
    repeat (50) @(posedge clk);
    data_in.send_samples(clk, 10, 1'b0, 1'b1);
    repeat (50) @(posedge clk);
    $display("######################################################");
    $display("# testing run with all data above thresholds         #");
    $display("# first sample will be zero                          #");
    $display("######################################################");
    check_results(threshold_low, threshold_high, timer, sample_index, is_high);
    
    // send a bunch of data, some below and some above the threshold on channel 0
    // for channel 1, keep the same settings as before
    data_range_low[0] <= 16'h0000;
    data_range_high[0] <= 16'h04ff;
    threshold_low[0] <= 16'h03c0;
    threshold_high[0] <= 16'h0400;
    config_in.valid <= 1'b1;
    @(posedge clk);
    config_in.valid <= 1'b0;
    repeat (50) @(posedge clk);
    data_in.send_samples(clk, 100, 1'b1, 1'b1);
    repeat (50) @(posedge clk);
    data_in.send_samples(clk, 100, 1'b0, 1'b1);
    repeat (50) @(posedge clk);
    $display("######################################################");
    $display("# testing run with channel 0 straddling thresholds   #");
    $display("# and channel 1 above thresholds                     #");
    $display("######################################################");
    check_results(threshold_low, threshold_high, timer, sample_index, is_high);

    // send a bunch of data below the threshold
    for (int i = 0; i < N_CHANNELS; i++) begin
      data_range_low[i] <= 16'h0000;
      data_range_high[i] <= 16'h00ff;
      threshold_low[i] <= 16'h03ff;
      threshold_high[i] <= 16'h0400;
    end
    config_in.valid <= 1'b1;
    @(posedge clk);
    config_in.valid <= 1'b0;
    repeat (50) @(posedge clk);
    data_in.send_samples(clk, 400, 1'b1, 1'b1);
    repeat (50) @(posedge clk);
    data_in.send_samples(clk, 400, 1'b0, 1'b1);
    repeat (50) @(posedge clk);
    $display("######################################################");
    $display("# testing run with all data below thresholds         #");
    $display("######################################################");
    check_results(threshold_low, threshold_high, timer, sample_index, is_high);

    // send a bunch of data close to the threshold
    for (int i = 0; i < N_CHANNELS; i++) begin
      data_range_low[i] <= 16'h0000;
      data_range_high[i] <= 16'h04ff;
      threshold_low[i] <= 16'h03c0;
      threshold_high[i] <= 16'h0400;
    end
    config_in.valid <= 1'b1;
    @(posedge clk);
    config_in.valid <= 1'b0;
    repeat (50) @(posedge clk);
    data_in.send_samples(clk, 400, 1'b1, 1'b1);
    repeat (50) @(posedge clk);
    data_in.send_samples(clk, 400, 1'b0, 1'b1);
    repeat (50) @(posedge clk);
    $display("######################################################");
    $display("# testing run with both channels straddling          #");
    $display("# thresholds                                         #");
    $display("######################################################");
    check_results(threshold_low, threshold_high, timer, sample_index, is_high);

    // reset state of counter and is_high
    repeat (10) @(posedge clk);
    reset_state <= 1'b1;
    @(posedge clk);
    reset_state <= '0;
    // need to make sure we keep track of this change
    is_high <= '0;
    sample_index <= '0;
    repeat (10) @(posedge clk);
  end

  $display("#################################################");
  if (error_count == 0) begin
    $display("# finished with zero errors");
  end else begin
    $error("# finished with %0d errors", error_count);
    $display("#################################################");
  end
  $display("#################################################");
  $finish;
end

endmodule
