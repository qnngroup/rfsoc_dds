// sample discriminator - Reed Foster
// If input sample is above some threshold (w/ hysteresis), it is passed through,
// otherwise it is dropped. If the preceeding sample was below the low threshold,
// then a timestamp is also sent out
// The timestamp also contains a count of saved samples up to the event that triggered
// the creation of the timestamp.
// This allows the samples to be associated with specific sample that was saved.
// The sample count and hysteresis is reset every time a new capture is started.
module sample_discriminator #( 
  parameter int SAMPLE_WIDTH = 16,
  parameter int PARALLEL_SAMPLES = 16,
  parameter int N_CHANNELS = 8,
  parameter int SAMPLE_INDEX_WIDTH = 14, // ideally keep the sum of this and CLOCK_WIDTH at most 64
  parameter int CLOCK_WIDTH = 50 // rolls over roughly every 3 days at 4GS/s (100 days at 32MS/s)
) (
  input wire clk, reset,
  Axis_Parallel_If.Slave_Simple data_in,
  Axis_Parallel_If.Master_Simple data_out,
  Axis_Parallel_If.Master_Simple timestamps_out,
  Axis_If.Slave_Simple config_in, // {threshold_high, threshold_low} for each channel
  input wire reset_state
);

localparam int TIMESTAMP_WIDTH = SAMPLE_INDEX_WIDTH + CLOCK_WIDTH;

assign config_in.ready = 1'b1;
assign data_in.ready = '1; // don't apply backpressure

typedef logic signed [SAMPLE_WIDTH-1:0] signed_sample_t;

logic [N_CHANNELS-1:0][SAMPLE_WIDTH-1:0] threshold_low, threshold_high;
logic [N_CHANNELS-1:0][PARALLEL_SAMPLES*SAMPLE_WIDTH-1:0] data_in_reg;
logic [N_CHANNELS-1:0] data_in_valid;
logic [N_CHANNELS-1:0][CLOCK_WIDTH-1:0] timer, timer_d;
logic [N_CHANNELS-1:0][SAMPLE_INDEX_WIDTH-1:0] sample_index;

logic [N_CHANNELS-1:0] is_high, is_high_d;
logic [N_CHANNELS-1:0] new_is_high;

assign new_is_high = is_high & (~is_high_d);

// update thresholds from config interface
always_ff @(posedge clk) begin
  if (reset) begin
    threshold_low <= '0;
    threshold_high <= '0;
  end else begin
    if (config_in.ok) begin
      for (int i = 0; i < N_CHANNELS; i++) begin
        threshold_high[i] <= config_in.data[2*SAMPLE_WIDTH*i+SAMPLE_WIDTH+:SAMPLE_WIDTH];
        threshold_low[i] <= config_in.data[2*SAMPLE_WIDTH*i+:SAMPLE_WIDTH];
      end
    end
  end
end

// if we're dealing with multiple parallel samples, check to see if any of
// them exceed the high threshold or if all of them are below the low
// threshold
logic [N_CHANNELS-1:0] any_above_high, all_below_low;
always_comb begin
  for (int i = 0; i < N_CHANNELS; i++) begin
    any_above_high[i] = 1'b0;
    all_below_low[i] = 1'b1;
    for (int j = 0; j < PARALLEL_SAMPLES; j++) begin
      if (signed_sample_t'(data_in.data[i][j*SAMPLE_WIDTH+:SAMPLE_WIDTH]) > signed_sample_t'(threshold_high[i])) begin
        any_above_high[i] = 1'b1;
      end
      if (signed_sample_t'(data_in.data[i][j*SAMPLE_WIDTH+:SAMPLE_WIDTH]) > signed_sample_t'(threshold_low[i])) begin
        all_below_low[i] = 1'b0;
      end
    end
  end
end

always_ff @(posedge clk) begin
  // pipeline stage for timer to match sample_index delay
  timer_d <= timer;
  timestamps_out.valid <= new_is_high;
  for (int i = 0; i < N_CHANNELS; i++) begin
    timestamps_out.data[i] <= {timer_d[i], sample_index[i]};
  end

  // pipeline stage to match latency of is_high SR flipflop
  data_in_valid <= data_in.valid;
  data_in_reg <= data_in.data;

  // is_high_d
  is_high_d <= is_high;

  // match delay of sample_index
  data_out.data <= data_in_reg;
  data_out.valid <= data_in_valid & is_high;

  // is_high SR flipflop, sample_index, and timer
  if (reset) begin
    is_high <= '0;
    is_high_d <= '0;
    timer <= '0;
    sample_index <= '0;
  end else begin
    for (int i = 0; i < N_CHANNELS; i++) begin
      // update sample_index and is_high
      // don't reset timer, since we want
      // to be able to track the arrival time of
      // samples between multiple captures
      if (reset_state) begin
        sample_index[i] <= '0;
        is_high[i] <= 1'b0;
      end else begin
        if (data_in_valid[i] && is_high[i]) begin
          sample_index[i] <= sample_index[i] + 1'b1;
        end
        // update is_high only when we get a new sample
        if (data_in.ok[i]) begin
          if (any_above_high[i]) begin
            is_high[i] <= 1'b1;
          end else if (all_below_low[i]) begin
            is_high[i] <= 1'b0;
          end
        end
      end
      // update timer
      if (data_in.ok[i]) begin
        timer[i] <= timer[i] + 1'b1;
      end
    end
  end
end

endmodule
