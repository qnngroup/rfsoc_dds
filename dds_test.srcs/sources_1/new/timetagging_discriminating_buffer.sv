// timetagging_discriminating_buffer - Reed Foster
// performs threshold-based sample discrimination
module timetagging_discriminating_buffer #(
  parameter int N_CHANNELS = 2,
  parameter int TSTAMP_BUFFER_DEPTH = 1024,
  parameter int DATA_BUFFER_DEPTH = 32768,
  parameter int AXI_MM_WIDTH = 128,
  parameter int PARALLEL_SAMPLES = 1,
  parameter int SAMPLE_WIDTH = 16,
  parameter int APPROX_CLOCK_WIDTH = 48
) (
  input wire clk, reset,
  Axis_Parallel_If.Slave_Simple data_in, // all channels in parallel
  Axis_If.Master_Full data_out,
  Axis_If.Slave_Simple disc_cfg_in, // {threshold_high, threshold_low} for each channel
  Axis_If.Slave_Simple buffer_cfg_in // {banking_mode, start, stop}
);

localparam int SAMPLE_INDEX_WIDTH = $clog2(DATA_BUFFER_DEPTH*N_CHANNELS);
localparam int TIMESTAMP_WIDTH = SAMPLE_WIDTH * ((SAMPLE_INDEX_WIDTH + APPROX_CLOCK_WIDTH + (SAMPLE_WIDTH - 1)) / SAMPLE_WIDTH);

// when either buffer fills up, it triggers a stop on the other with the stop_aux input
logic [1:0] buffer_full;

// axi-stream interfaces
Axis_Parallel_If #(.DWIDTH(TIMESTAMP_WIDTH), .PARALLEL_CHANNELS(N_CHANNELS)) disc_tstamps();
Axis_Parallel_If #(.DWIDTH(SAMPLE_WIDTH*PARALLEL_SAMPLES), .PARALLEL_CHANNELS(N_CHANNELS)) disc_data();
Axis_If #(.DWIDTH($clog2($clog2(N_CHANNELS)+1)+2)) buf_tstamp_cfg ();
Axis_If #(.DWIDTH($clog2($clog2(N_CHANNELS)+1)+2)) buf_data_cfg ();
Axis_If #(.DWIDTH(TIMESTAMP_WIDTH)) buf_tstamp_out ();
Axis_If #(.DWIDTH(SAMPLE_WIDTH*PARALLEL_SAMPLES)) buf_data_out ();

// share buffer_cfg_in between both buffers so their configuration is synchronized
assign buf_tstamp_cfg.data = buffer_cfg_in.data;
assign buf_tstamp_cfg.valid = buffer_cfg_in.valid;
assign buf_data_cfg.data = buffer_cfg_in.data;
assign buf_data_cfg.valid = buffer_cfg_in.valid;
assign buffer_cfg_in.ready = 1'b1; // doesn't matter what we do here, since both modules hold ready = 1'b1

// whenever a buffer capture is triggered through the buffer_cfg_in interface,
// reset the sample_index counter in the sample discriminator
logic start;
always_ff @(posedge clk) begin
  if (reset) begin
    start <= '0;
  end else begin
    if (buffer_cfg_in.ok) begin
      start <= buffer_cfg_in.data[1];
    end
  end
end

// merge both buffer outputs into a word that is AXI_MM_WIDTH bits

sample_discriminator #(
  .SAMPLE_WIDTH(SAMPLE_WIDTH),
  .PARALLEL_SAMPLES(PARALLEL_SAMPLES),
  .N_CHANNELS(N_CHANNELS),
  .SAMPLE_INDEX_WIDTH($clog2(DATA_BUFFER_DEPTH*N_CHANNELS)),
  .CLOCK_WIDTH(TIMESTAMP_WIDTH - SAMPLE_INDEX_WIDTH)
) disc_i (
  .clk,
  .reset,
  .data_in,
  .data_out(disc_data),
  .timestamps_out(disc_tstamps),
  .config_in(disc_cfg_in),
  .sample_index_reset(start)
);

banked_sample_buffer #(
  .SAMPLE_WIDTH(SAMPLE_WIDTH),
  .BUFFER_DEPTH(DATA_BUFFER_DEPTH),
  .PARALLEL_SAMPLES(PARALLEL_SAMPLES),
  .N_CHANNELS(N_CHANNELS)
) data_buffer_i (
  .clk,
  .reset,
  .data_in(disc_data),
  .data_out(buf_data_out),
  .config_in(buf_data_cfg),
  .stop_aux(buffer_full[0]),
  .capture_started(),
  .buffer_full(buffer_full[1])
);

banked_sample_buffer #(
  .SAMPLE_WIDTH(TIMESTAMP_WIDTH),
  .BUFFER_DEPTH(TSTAMP_BUFFER_DEPTH),
  .PARALLEL_SAMPLES(1),
  .N_CHANNELS(N_CHANNELS)
) data_buffer_i (
  .clk,
  .reset,
  .data_in(disc_tstamps),
  .data_out(buf_tstamp_out),
  .config_in(buf_tstamp_cfg),
  .stop_aux(buffer_full[1]),
  .capture_started(),
  .buffer_full(buffer_full[0])
);

endmodule
