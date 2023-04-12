module dds_wrapper (
  input wire clk, reset_n,
  output phase_change,
  output [1023:0] cos_out_data,
  output cos_out_valid,
  input cos_out_ready,
  input [23:0] phase_inc_in_data,
  input phase_inc_in_valid,
  output phase_inc_in_ready,
  input [3:0] cos_scale_in_data,
  input cos_scale_in_valid,
  output cos_scale_in_ready
);

dds_sv_wrapper #(
  .PHASE_BITS(24),
  .OUTPUT_WIDTH(16),
  .QUANT_BITS(12),
  .PARALLEL_SAMPLES(64)
) dds_sv_wrapper_i (
  .clk(clk),
  .reset(~reset_n),
  .phase_change(phase_change),
  .cos_out_data(cos_out_data),
  .cos_out_valid(cos_out_valid),
  .cos_out_ready(cos_out_ready),
  .phase_inc_in_data(phase_inc_in_data),
  .phase_inc_in_valid(phase_inc_in_valid),
  .phase_inc_in_ready(phase_inc_in_ready),
  .cos_scale_in_data(cos_scale_in_data),
  .cos_scale_in_valid(cos_scale_in_valid),
  .cos_scale_in_ready(cos_scale_in_ready)
);

endmodule
