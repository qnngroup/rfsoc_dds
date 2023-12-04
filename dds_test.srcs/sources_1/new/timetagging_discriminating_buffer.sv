// timetagging_discriminating_buffer - Reed Foster
// performs threshold-based sample discrimination
module timetagging_discriminating_buffer #(
  parameter int N_CHANNELS = 2, // number of input channels
  parameter int TSTAMP_BUFFER_DEPTH = 1024, // depth of timestamp buffer
  parameter int DATA_BUFFER_DEPTH = 32768, // depth of data/sample buffer
  parameter int AXI_MM_WIDTH = 128, // width of DMA AXI-stream interface
  parameter int PARALLEL_SAMPLES = 1, // number of parallel samples per clock cycle per channel
  parameter int SAMPLE_WIDTH = 16, // width in bits of each sample
  parameter int APPROX_CLOCK_WIDTH = 48 // requested width of timestamp
) (
  input wire clk, reset,
  output logic [31:0] timestamp_width, // output so that PS can correctly parse output data
  Axis_Parallel_If.Slave_Simple data_in, // all channels in parallel
  Axis_If.Master_Full data_out,
  Axis_If.Slave_Simple discriminator_config_in, // {threshold_high, threshold_low} for each channel
  Axis_If.Slave_Simple buffer_config_in // {banking_mode, start, stop}
);

localparam int SAMPLE_INDEX_WIDTH = $clog2(DATA_BUFFER_DEPTH*N_CHANNELS);
localparam int TIMESTAMP_WIDTH = SAMPLE_WIDTH * ((SAMPLE_INDEX_WIDTH + APPROX_CLOCK_WIDTH + (SAMPLE_WIDTH - 1)) / SAMPLE_WIDTH);
assign timestamps_width = TIMESTAMP_WIDTH;

// when either buffer fills up, it triggers a stop on the other with the stop_aux input
logic [1:0] buffer_full;

// axi-stream interfaces
Axis_Parallel_If #(.DWIDTH(TIMESTAMP_WIDTH), .PARALLEL_CHANNELS(N_CHANNELS)) disc_timestamps();
Axis_Parallel_If #(.DWIDTH(SAMPLE_WIDTH*PARALLEL_SAMPLES), .PARALLEL_CHANNELS(N_CHANNELS)) disc_data();
Axis_If #(.DWIDTH($clog2($clog2(N_CHANNELS)+1)+2)) buffer_timestamp_config ();
Axis_If #(.DWIDTH($clog2($clog2(N_CHANNELS)+1)+2)) buffer_data_config ();
Axis_If #(.DWIDTH(TIMESTAMP_WIDTH)) buffer_timestamp_out ();
Axis_If #(.DWIDTH(SAMPLE_WIDTH*PARALLEL_SAMPLES)) buffer_data_out ();
Axis_If #(.DWIDTH(AXI_MM_WIDTH)) buffer_timestamp_out_resized ();
Axis_If #(.DWIDTH(AXI_MM_WIDTH)) buffer_data_out_resized ();

// share buffer_config_in between both buffers so their configuration is synchronized
assign buffer_timestamp_config.data = buffer_config_in.data;
assign buffer_timestamp_config.valid = buffer_config_in.valid;
assign buffer_data_config.data = buffer_config_in.data;
assign buffer_data_config.valid = buffer_config_in.valid;
assign buffer_config_in.ready = 1'b1; // doesn't matter what we do here, since both modules hold ready = 1'b1

logic start, start_d;
always_ff @(posedge clk) begin
  if (reset) begin
    start <= '0;
    start_d <= '0;
  end else begin
    start_d <= start;
    if (buffer_config_in.ok) begin
      start <= buffer_config_in.data[1];
    end
  end
end

sample_discriminator #(
  .SAMPLE_WIDTH(SAMPLE_WIDTH),
  .PARALLEL_SAMPLES(PARALLEL_SAMPLES),
  .N_CHANNELS(N_CHANNELS),
  .SAMPLE_INDEX_WIDTH(SAMPLE_INDEX_WIDTH),
  .CLOCK_WIDTH(TIMESTAMP_WIDTH - SAMPLE_INDEX_WIDTH)
) disc_i (
  .clk,
  .reset,
  .data_in,
  .data_out(disc_data),
  .timestamps_out(disc_timestamps),
  .config_in(discriminator_config_in),
  .reset_state(start & ~start_d) // reset sample_index count and is_high whenever a new capture is started
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
  .data_out(buffer_data_out),
  .config_in(buffer_data_config),
  .stop_aux(buffer_full[0]), // stop saving data when timestamp buffer is full
  .capture_started(),
  .buffer_full(buffer_full[1])
);

banked_sample_buffer #(
  .SAMPLE_WIDTH(TIMESTAMP_WIDTH),
  .BUFFER_DEPTH(TSTAMP_BUFFER_DEPTH),
  .PARALLEL_SAMPLES(1),
  .N_CHANNELS(N_CHANNELS)
) timestamp_buffer_i (
  .clk,
  .reset,
  .data_in(disc_timestamps),
  .data_out(buffer_timestamp_out),
  .config_in(buffer_timestamp_config),
  .stop_aux(buffer_full[1]), // stop saving timestamps when data buffer is full
  .capture_started(),
  .buffer_full(buffer_full[0])
);

// merge both buffer outputs into a word that is AXI_MM_WIDTH bits
// first step down/up the width of the outputs
function int GCD(input int A, input int B);
  if (B == 0) begin
    return A;
  end else begin
    return GCD(B, A % B);
  end
endfunction

localparam int DATA_AXI_MM_GCD = GCD(AXI_MM_WIDTH, SAMPLE_WIDTH*PARALLEL_SAMPLES);
localparam int TIMESTAMP_AXI_MM_GCD = GCD(AXI_MM_WIDTH, TIMESTAMP_WIDTH);

localparam int DATA_RESIZER_UP = AXI_MM_WIDTH / DATA_AXI_MM_GCD;
localparam int DATA_RESIZER_DOWN = (SAMPLE_WIDTH*PARALLEL_SAMPLES) / DATA_AXI_MM_GCD;
localparam int TIMESTAMP_RESIZER_UP = AXI_MM_WIDTH / TIMESTAMP_AXI_MM_GCD;
localparam int TIMESTAMP_RESIZER_DOWN = TIMESTAMP_WIDTH / TIMESTAMP_AXI_MM_GCD;

axis_width_converter #(
  .DWIDTH_IN(SAMPLE_WIDTH*PARALLEL_SAMPLES),
  .UP(DATA_RESIZER_UP),
  .DOWN(DATA_RESIZER_DOWN)
) data_width_converter_i (
  .clk,
  .reset,
  .data_in(buffer_data_out),
  .data_out(buffer_data_out_resized)
);

axis_width_converter #(
  .DWIDTH_IN(TIMESTAMP_WIDTH),
  .UP(TIMESTAMP_RESIZER_UP),
  .DOWN(TIMESTAMP_RESIZER_DOWN)
) timestamp_width_converter_i (
  .clk,
  .reset,
  .data_in(buffer_timestamp_out),
  .data_out(buffer_timestamp_out_resized)
);

// mux the two outputs
// state machine
// first output all the timestamps, then all the data
enum {TIMESTAMP, DATA} buffer_select;

always_ff @(posedge clk) begin
  if (reset) begin
    buffer_select <= TIMESTAMP;
  end else begin
    unique case (buffer_select)
      TIMESTAMP: if (buffer_timestamp_out_resized.last && buffer_timestamp_out_resized.ok) buffer_select <= DATA;
      DATA: if (buffer_data_out_resized.last && buffer_data_out_resized.ok) buffer_select <= TIMESTAMP;
    endcase
  end
end

// mux data, valid, and last
always_comb begin
  unique case (buffer_select)
    TIMESTAMP: begin
      data_out.data = buffer_timestamp_out_resized.data;
      data_out.valid = buffer_timestamp_out_resized.valid;
      data_out.last = 1'b0; // don't send last for timestamp data
    end
    DATA: begin
      data_out.data = buffer_data_out_resized.data;
      data_out.valid = buffer_data_out_resized.valid;
      data_out.last = buffer_data_out_resized.last;
    end
  endcase
end

assign buffer_timestamp_out_resized.ready = (buffer_select == TIMESTAMP) ? data_out.ready : 1'b0;
assign buffer_data_out_resized.ready = (buffer_select == DATA) ? data_out.ready : 1'b0;

endmodule
