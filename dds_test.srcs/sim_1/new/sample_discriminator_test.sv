`timescale 1ns / 1ps
module sample_discriminator_test();

logic clk = 0;
localparam CLK_RATE_HZ = 100_000_000;
always #(0.5s/CLK_RATE_HZ) clk = ~clk;

logic reset;

localparam int N_CHANNELS = 2;
localparam int SAMPLE_WIDTH = 16;
localparam int PARALLEL_SAMPLES = 4;
localparam int SAMPLE_INDEX_WIDTH = 14;
localparam int CLOCK_WIDTH = 50;

Axis_If #(.DWIDTH(N_CHANNELS*SAMPLE_WIDTH*2)) config_in();
Axis_Parallel_If #(.DWIDTH(SAMPLE_WIDTH*PARALLEL_SAMPLES), .PARALLEL_CHANNELS(N_CHANNELS)) data_in();
Axis_Parallel_If #(.DWIDTH(SAMPLE_WIDTH*PARALLEL_SAMPLES), .PARALLEL_CHANNELS(N_CHANNELS)) data_out();
Axis_Parallel_If #(.DWIDTH(SAMPLE_INDEX_WIDTH+CLOCK_WIDTH), .PARALLEL_CHANNELS(N_CHANNELS)) timestamps_out();

typedef logic signed [SAMPLE_WIDTH-1:0] signed_sample_t;
logic [N_CHANNELS-1:0][SAMPLE_WIDTH-1:0] threshold_high, threshold_low;
always_comb begin
  for (int i = 0; i < N_CHANNELS; i++) begin
    config_in.data[2*SAMPLE_WIDTH*i+:2*SAMPLE_WIDTH] = {threshold_high[i], threshold_low[i]};
  end
end

logic sample_index_reset;

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
  .sample_index_reset
);

logic [SAMPLE_WIDTH*PARALLEL_SAMPLES-1:0] data_sent [N_CHANNELS][$];
logic [SAMPLE_WIDTH*PARALLEL_SAMPLES-1:0] data_received [N_CHANNELS][$];
logic [SAMPLE_INDEX_WIDTH+CLOCK_WIDTH-1:0] timestamps_received [N_CHANNELS][$];

logic [N_CHANNELS-1:0][SAMPLE_WIDTH-1:0] data_range_low, data_range_high;

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

assign data_out.ready = '1;
assign timestamps_out.ready = '1;

task send_samples(input int n_samples, input bit rand_arrivals);
  int samples_sent [N_CHANNELS];
  logic [N_CHANNELS-1:0] done;
  if (rand_arrivals) begin
    // reset
    done = '0;
    for (int i = 0; i < N_CHANNELS; i++) begin
      samples_sent[i] = 0;
    end
    while (~done) begin
      for (int i = 0; i < N_CHANNELS; i++) begin
        if (data_in.valid[i]) begin
          if (samples_sent[i] == n_samples - 1) begin
            done[i] = 1'b1;
          end else begin
            samples_sent[i] = samples_sent[i] + 1'b1;
          end
        end
      end
      data_in.valid <= $urandom_range((1<<N_CHANNELS) - 1) & (~done);
      @(posedge clk);
    end
    data_in.valid <= '0;
    @(posedge clk);
  end else begin
    data_in.valid <= '1;
    repeat (n_samples) begin
      @(posedge clk);
    end
    data_in.valid <= '0;
  end
endtask

function logic any_above_high (
  input logic [SAMPLE_WIDTH*PARALLEL_SAMPLES-1:0] samples_in,
  input logic [SAMPLE_WIDTH-1:0] threshold_high
);
  for (int j = 0; j < PARALLEL_SAMPLES; j++) begin
    if (signed_sample_t'(samples_in[j*SAMPLE_WIDTH+:SAMPLE_WIDTH]) > signed_sample_t'(threshold_high)) begin
      return 1'b1;
    end
  end
  return 1'b0;
endfunction

function logic all_below_low (
  input logic [SAMPLE_WIDTH*PARALLEL_SAMPLES-1:0] samples_in,
  input logic [SAMPLE_WIDTH-1:0] threshold_low
);
  for (int j = 0; j < PARALLEL_SAMPLES; j++) begin
    if (signed_sample_t'(samples_in[j*SAMPLE_WIDTH+:SAMPLE_WIDTH]) > signed_sample_t'(threshold_low)) begin
      return 1'b0;
    end
  end
  return 1'b1;
endfunction

task check_results (
  input logic [N_CHANNELS-1:0][SAMPLE_WIDTH-1:0] threshold_low,
  input logic [N_CHANNELS-1:0][SAMPLE_WIDTH-1:0] threshold_high,
  inout logic [N_CHANNELS-1:0][CLOCK_WIDTH-1:0] timer,
  inout logic [N_CHANNELS-1:0][SAMPLE_INDEX_WIDTH-1:0] sample_index,
  inout logic [N_CHANNELS-1:0] is_high
);
  for (int i = 0; i < N_CHANNELS; i++) begin
    // process each channel
    $display("data_sent[%0d].size() = %0d", i, data_sent[i].size());
    $display("data_received[%0d].size() = %0d", i, data_received[i].size());
    $display("timestamps_received[%0d].size() = %0d", i, timestamps_received[i].size());

    if (data_sent[i].size() < data_received[i].size()) begin
      $error("more data received than sent. this is not possible");
    end

    while (data_sent[i].size() > 0) begin
      if (any_above_high(data_sent[i][$], threshold_high[i])) begin
        if (!is_high[i]) begin
          // new high, we should get a timestamp
          if (timestamps_received[i].size() > 0) begin
            if (timestamps_received[i][$] != {timer[i], sample_index[i]}) begin
              $warning("mismatched timestamp: got %x, expected %x", timestamps_received[i][$], {timer[i], sample_index[i]});
            end
            timestamps_received[i].pop_back();
          end else begin
            $warning("expected a timestamp (with value %x), but no more timestamps left", {timer[i], sample_index[i]});
          end
        end
        is_high[i] = 1'b1;
      end else if (all_below_low(data_sent[i][$], threshold_low[i])) begin
        is_high[i] = 1'b0;
      end
      if (is_high[i]) begin
        if (data_sent[i][$] != data_received[i][$]) begin
          $warning("mismatched data: got %x, expected %x", data_received[i][$], data_sent[i][$]);
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
  sample_index_reset <= '0;
  is_high <= '0;
  timer <= '0;
  sample_index <= '0;
  repeat (100) @(posedge clk);
  reset <= 1'b0;
  sample_index_reset <= 1'b1;
  @(posedge clk);
  sample_index_reset <= '0;
  repeat (50) @(posedge clk);
  config_in.valid <= 1'b1;
  @(posedge clk);
  config_in.valid <= 1'b0;
  repeat (50) @(posedge clk);

  // send a bunch of data with discrimination disabled
  send_samples(10, 1);
  repeat (50) @(posedge clk);
  send_samples(10, 0);
  repeat (50) @(posedge clk);
  $display("######################################################");
  $display("# testing run with all data above thresholds         #");
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
  send_samples(100, 1);
  repeat (50) @(posedge clk);
  send_samples(100, 0);
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
  send_samples(400, 1);
  repeat (50) @(posedge clk);
  send_samples(400, 0);
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
  send_samples(400, 1);
  repeat (50) @(posedge clk);
  send_samples(400, 0);
  repeat (50) @(posedge clk);
  $display("######################################################");
  $display("# testing run with both channels straddling          #");
  $display("# thresholds                                         #");
  $display("######################################################");
  check_results(threshold_low, threshold_high, timer, sample_index, is_high);

  $finish;
end

endmodule
