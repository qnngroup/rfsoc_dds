module sample_buffer_wrapper (
  input wire clk, reset_n,
  output [127:0] data_out_tdata,
  output data_out_tvalid, data_out_tlast,
  input data_out_tready,
  output [15:0] data_out_tkeep,
  input [1023:0] data_in_tdata,
  input data_in_tvalid,
  output data_in_tready,
  input wire capture,
  input wire pinc_change,
  input wire trigger_select
);

assign data_out_tkeep = 16'hffff;

sample_buffer_sv_wrapper #(
  .BUFFER_DEPTH(16384),
  .PARALLEL_SAMPLES(64),
  .INPUT_SAMPLE_WIDTH(16),
  .OUTPUT_SAMPLE_WIDTH(16),
  .AXI_MM_WIDTH(128)
) sample_buffer_sv_wrapper_i (
  .clk(clk),
  .reset(~reset_n),
  .data_out(data_out_tdata),
  .data_out_valid(data_out_tvalid),
  .data_out_last(data_out_tlast),
  .data_out_ready(data_out_tready),
  .data_in(data_in_tdata),
  .data_in_valid(data_in_tvalid),
  .data_in_ready(data_in_tready),
  .capture(capture),
  .pinc_change(pinc_change),
  .trigger_select(trigger_select)
);

endmodule
