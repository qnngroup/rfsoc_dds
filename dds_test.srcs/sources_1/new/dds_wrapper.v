module dds_wrapper (
  input wire clk, reset_n,
  output pinc_change,
  output [1023:0] cos_out_tdata,
  output cos_out_tvalid,
  input cos_out_tready,
  input [23:0] phase_inc_in_tdata,
  input phase_inc_in_tvalid,
  output phase_inc_in_tready,
  input [3:0] cos_scale_in_tdata,
  input cos_scale_in_tvalid,
  output cos_scale_in_tready
);

dds_sv_wrapper #(
  .PHASE_BITS(24),
  .OUTPUT_WIDTH(16),
  .QUANT_BITS(12),
  .PARALLEL_SAMPLES(64)
) dds_sv_wrapper_i (
  .clk(clk),
  .reset(~reset_n),
  .pinc_change(pinc_change),
  .cos_out_data(cos_out_tdata),
  .cos_out_valid(cos_out_tvalid),
  .cos_out_ready(cos_out_tready),
  .phase_inc_in_data(phase_inc_in_tdata),
  .phase_inc_in_valid(phase_inc_in_tvalid),
  .phase_inc_in_ready(phase_inc_in_tready),
  .cos_scale_in_data(cos_scale_in_tdata),
  .cos_scale_in_valid(cos_scale_in_tvalid),
  .cos_scale_in_ready(cos_scale_in_tready)
);

endmodule
