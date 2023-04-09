`timescale 1ns / 1ps
module dds_test ();

logic clk = 0;
logic clk_fast = 0;
localparam CLK_RATE_HZ = 100_000_000;
always #(0.5s/CLK_RATE_HZ) clk = ~clk;
always #(0.5s/CLK_RATE_HZ/4) clk_fast = ~clk_fast;

logic reset;

localparam PHASE_BITS = 24;
localparam OUTPUT_WIDTH = 18;
localparam QUANT_BITS = 8;
localparam PARALLEL_SAMPLES = 4;

Axis_If #(.DWIDTH(PHASE_BITS)) phase_inc_in();
Axis_If #(.DWIDTH(OUTPUT_WIDTH*PARALLEL_SAMPLES)) cos_out();

dds #(.PHASE_BITS(PHASE_BITS), .OUTPUT_WIDTH(OUTPUT_WIDTH), .QUANT_BITS(QUANT_BITS)) dut_i (
  .clk,
  .reset,
  .cos_out,
  .phase_inc_in
);

localparam int N_FREQS = 4;
localparam int N_SAMP_PER_FREQ = 2**14;
int freqs [N_FREQS] = {12_130_000, 517_036_000, 1_729_725_000, 2_759_000};

logic [OUTPUT_WIDTH-1:0] cos_vector [N_FREQS*N_SAMP_PER_FREQ];
logic [PHASE_BITS-1:0] phi_vector [N_FREQS*N_SAMP_PER_FREQ];
logic [OUTPUT_WIDTH-1:0] cos_vector_output_d [5];
logic [PHASE_BITS-1:0] phi_vector_output_d [5];
int vector_index;

logic [OUTPUT_WIDTH-1:0] cos_dout;
logic [$clog2(PARALLEL_SAMPLES)-1:0] parallel_index;

always @(posedge clk_fast) begin
  if (reset) begin
    parallel_index <= '0;
  end else begin
    if (cos_out.valid && cos_out.ready) begin
      cos_dout <= cos_out.data[parallel_index*OUTPUT_WIDTH+:OUTPUT_WIDTH];
      if (parallel_index == PARALLEL_SAMPLES - 1) begin
        parallel_index <= '0;
      end else begin
        parallel_index <= parallel_index + 1;
      end
      vector_index <= vector_index + 1;
    end
  end
end

always @(posedge clk_fast) begin
  cos_vector_output_d[0] <= cos_vector[vector_index];
  phi_vector_output_d[0] <= phi_vector[vector_index];
  for (int i = 1; i < 6; i++) begin
    cos_vector_output_d[i] <= cos_vector_output_d[i-1];
    phi_vector_output_d[i] <= phi_vector_output_d[i-1];
  end
end


initial begin
  $readmemh("lfsr_dithered_cos.mem", cos_vector);
  $readmemh("lfsr_dithered_phase.mem", phi_vector);
  reset <= 1'b1;
  vector_index <= 0;
  repeat (50) @(posedge clk);
  reset <= 1'b0;
  repeat (20) @(posedge clk);
  cos_out.ready <= 1'b1;
  //repeat (100) @(posedge clk);
  for (int i = 0; i < N_FREQS; i = i + 1) begin
    phase_inc_in.data <= unsigned'(int'($floor((real'(freqs[i])/6_400_000_000.0) * (2**(PHASE_BITS)))));
    phase_inc_in.valid <= 1;
    repeat (1) @(posedge clk);
    phase_inc_in.valid <= 0;
    repeat (100) @(posedge clk);
    cos_out.ready <= 1'b0;
    repeat (100) @(posedge clk);
    cos_out.ready <= 1'b1;
    repeat (3995) @(posedge clk);
  end
  $finish;
end

endmodule
