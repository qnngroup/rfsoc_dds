module sample_buffer_wrapper (
  input wire clk, reset_n,
  output [127:0] data_out,
  output data_out_valid, data_out_last,
  input data_out_ready,
  output [15:0] data_out_keep,
  input [1023:0] data_in,
  input data_in_valid,
  output data_in_ready,
  input wire capture
);

assign data_out_keep = 16'hffff;

sample_buffer_sv_wrapper #(
  .BUFFER_DEPTH(32768),
  .PARALLEL_SAMPLES(64),
  .INPUT_SAMPLE_WIDTH(16),
  .OUTPUT_SAMPLE_WIDTH(16),
  .AXI_MM_WIDTH(128)
) sample_buffer_sv_wrapper_i (
  .clk(clk),
  .reset(~reset_n),
  .data_out(data_out),
  .data_out_valid(data_out_valid),
  .data_out_last(data_out_last),
  .data_out_ready(data_out_ready),
  .data_in(data_in),
  .data_in_valid(data_in_valid),
  .data_in_ready(data_in_ready),
  .capture(capture)
);

endmodule
