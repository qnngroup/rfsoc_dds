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

logic signed [N_CHANNELS-1:0][SAMPLE_WIDTH-1:0] threshold_high, threshold_low;
assign config_in.data = {threshold_high, threshold_low};

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
        data_in.data[i] <= $urandom_range(data_range_low[i], data_range_high[i]);
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
    done = '0;
    while (~done) begin
      data_in.valid <= $urandom_range((1<<N_CHANNELS) - 1) & (~done);
      for (int i = 0; i < N_CHANNELS; i++) begin
        if (data_in.valid[i]) begin
          samples_sent[i] <= samples_sent[i] + 1'b1;
          if (samples_sent[i] == n_samples - 1) begin
            done[i] = 1'b1;
          end else begin
            samples_sent[i] <= samples_sent[i] + 1'b1;
          end
        end
      end
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

task check_results();
  for (int i = 0; i < N_CHANNELS; i++) begin
    $display("data_sent[%0d].size() = %0d", i, data_sent[i].size());
    $display("data_received[%0d].size() = %0d", i, data_received[i].size());
    $display("timestamps_received[%0d].size() = %0d", i, timestamps_received[i].size());
  end
  for (int i = 0; i < N_CHANNELS; i++) begin
    for (int j = 0; j < data_sent[i].size(); j++) begin
      $display("data_sent[%0d][%0d] = %x", i, data_sent[i].size() - j - 1, data_sent[i][$-j]);
    end
    for (int j = 0; j < data_received[i].size(); j++) begin
      $display("data_received[%0d][%0d] = %x", i, data_received[i].size() - j - 1, data_received[i][$-j]);
    end
    for (int j = 0; j < timestamps_received[i].size(); j++) begin
      $display("timestamps_received[%0d][%0d] = %x", i, timestamps_received[i].size() - j - 1, timestamps_received[i][$-j]);
    end
  end
endtask

initial begin
  reset <= 1'b1;
  data_range_low <= '0;
  data_range_high <= '1;
  threshold_low <= '0;
  threshold_high <= '0;
  data_in.valid <= '0;
  sample_index_reset <= '0;
  repeat (100) @(posedge clk);
  reset <= 1'b0;
  sample_index_reset <= 1'b1;
  @(posedge clk);
  sample_index_reset <= '0;
  repeat (50) @(posedge clk);
  send_samples(10, 1);
  repeat (50) @(posedge clk);
  send_samples(10, 0);
  repeat (50) @(posedge clk);
  check_results();
  $finish;
  // change amplitudes and threshold to check sample-rejection
  // first, try sending small signals that shouldn't make it through
  data_range_low <= 16'h00ff;
  data_range_high <= 16'h02ff;
  threshold_low <= 16'h03ff;
  threshold_high <= 16'h07ff;
  config_in.valid <= 1'b1;
  @(posedge clk);
  config_in.valid <= 1'b0;
  repeat (50) @(posedge clk);
  send_samples(200, 0);
  repeat (50) @(posedge clk);
  // should have 200 samples
  check_results();
  $finish;
end

endmodule
