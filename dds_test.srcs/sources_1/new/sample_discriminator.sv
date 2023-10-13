// sample discriminator - Reed Foster
// If input sample is above some threshold (w/ hysteresis), it is passed through,
// otherwise it is dropped. If the preceeding sample was below the low threshold,
// then a timestamp is also sent out
// The timestamp also contains a count of saved samples up to the event that triggered
// the creation of the timestamp.
// This allows the samples to be associated with specific sample that was saved.
// The sample count is reset every time a new capture is started.
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
  input wire sample_index_reset
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
      // update sample_index
      if (sample_index_reset) begin
        sample_index[i] <= '0;
      end else if (data_in_valid[i] && is_high[i]) begin
        sample_index[i] <= sample_index[i] + 1'b1;
      end
      // update timer
      if (data_in.valid[i]) begin
        timer[i] <= timer[i] + 1'b1;
      end
      // update is_high
      if (any_above_high[i]) begin
        is_high[i] <= 1'b1;
      end else if (all_below_low[i]) begin
        is_high[i] <= 1'b0;
      end
    end
  end
end

endmodule

module sample_discriminator_sv #(
  parameter SAMPLE_WIDTH = 16,
  parameter PARALLEL_SAMPLES = 1,
  parameter SAMPLE_INDEX_WIDTH = 14,
  parameter CLOCK_WIDTH = 50
) (
  input wire clk, reset,

  input [SAMPLE_WIDTH*PARALLEL_SAMPLES-1:0] s00_axis_tdata,
  input s00_axis_tvalid,
  output s00_axis_tready,

  input [SAMPLE_WIDTH*PARALLEL_SAMPLES-1:0] s01_axis_tdata,
  input s01_axis_tvalid,
  output s01_axis_tready,

  output [SAMPLE_WIDTH*PARALLEL_SAMPLES-1:0] m00_data_axis_tdata,
  output m00_data_axis_tvalid,
  input m00_data_axis_tready,

  output [SAMPLE_WIDTH*PARALLEL_SAMPLES-1:0] m01_data_axis_tdata,
  output m01_data_axis_tvalid,
  input m01_data_axis_tready,

  output [SAMPLE_INDEX_WIDTH+CLOCK_WIDTH-1:0] m00_tstamp_axis_tdata,
  output m00_tstamp_axis_tvalid,
  input m00_tstamp_axis_tready,

  output [SAMPLE_INDEX_WIDTH+CLOCK_WIDTH-1:0] m01_tstamp_axis_tdata,
  output m01_tstamp_axis_tvalid,
  input m01_tstamp_axis_tready,

  input [2*2*SAMPLE_WIDTH-1:0] cfg_axis_tdata,
  input cfg_axis_tvalid,
  output cfg_axis_tready,

  input sample_index_reset
);

Axis_If #(.DWIDTH(N_CHANNELS*SAMPLE_WIDTH*2)) config_in();
Axis_Parallel_If #(.DWIDTH(SAMPLE_WIDTH*PARALLEL_SAMPLES), .PARALLEL_CHANNELS(N_CHANNELS)) data_in();
Axis_Parallel_If #(.DWIDTH(SAMPLE_WIDTH*PARALLEL_SAMPLES), .PARALLEL_CHANNELS(N_CHANNELS)) data_out();
Axis_Parallel_If #(.DWIDTH(SAMPLE_INDEX_WIDTH+CLOCK_WIDTH), .PARALLEL_CHANNELS(N_CHANNELS)) timestamps_out();

assign data_in.data[0] = s00_axis_tdata;
assign data_in.valid[0] = s00_axis_tvalid;
assign s00_axis_tready = data_in.ready[0];

assign data_in.data[1] = s01_axis_tdata;
assign data_in.valid[1] = s01_axis_tvalid;
assign s01_axis_tready = data_in.ready[1];

assign m00_data_axis_tdata = data_out.data[0];
assign m00_data_axis_tvalid = data_out.valid[0];
assign data_out.ready[0] = m00_data_axis_tready;

assign m01_data_axis_tdata = data_out.data[1];
assign m01_data_axis_tvalid = data_out.valid[1];
assign data_out.ready[1] = m01_data_axis_tready;

assign m00_tstamp_axis_tdata = timestamps_out.data[0];
assign m00_tstamp_axis_tvalid = timestamps_out.valid[0];
assign timestamps_out.ready[0] = m00_tstamp_axis_tready;

assign m01_tstamp_axis_tdata = timestamps_out.data[1];
assign m01_tstamp_axis_tvalid = timestamps_out.valid[1];
assign timestamps_out.ready[1] = m01_tstamp_axis_tready;

assign config_in.data = cfg_axis_tdata;
assign config_in.valid = cfg_axis_tvalid;
assign cfg_axis_tready = config_in.ready;

sample_discriminator #( 
  .SAMPLE_WIDTH(SAMPLE_WIDTH),
  .PARALLEL_SAMPLES(PARALLEL_SAMPLES),
  .N_CHANNELS(N_CHANNELS),
  .SAMPLE_INDEX_WIDTH(SAMPLE_INDEX_WIDTH),
  .CLOCK_WIDTH(CLOCK_WIDTH),
) disc_i (
  .clk,
  .reset,
  .data_in,
  .data_out,
  .timestamps_out,
  .config_in,
  .sample_index_reset
);

endmodule
