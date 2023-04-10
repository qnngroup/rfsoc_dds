`timescale 1ns / 1ps
module dds_test ();

logic reset;

localparam PHASE_BITS = 24;
localparam OUTPUT_WIDTH = 18;
localparam QUANT_BITS = 8;
localparam PARALLEL_SAMPLES = 4;
localparam LUT_ADDR_BITS = PHASE_BITS - QUANT_BITS;
localparam LUT_DEPTH = 2**LUT_ADDR_BITS;

logic clk = 0;
localparam CLK_RATE_HZ = 100_000_000;
always #(0.5s/CLK_RATE_HZ) clk = ~clk;

Axis_If #(.DWIDTH(PHASE_BITS)) phase_inc_in();
Axis_If #(.DWIDTH(OUTPUT_WIDTH*PARALLEL_SAMPLES)) cos_out();
Axis_If #(.DWIDTH($clog2(OUTPUT_WIDTH))) cos_scale_in();

dds #(.PHASE_BITS(PHASE_BITS), .OUTPUT_WIDTH(OUTPUT_WIDTH), .QUANT_BITS(QUANT_BITS)) dut_i (
  .clk,
  .reset,
  .cos_out,
  .phase_inc_in,
  .cos_scale_in
);

localparam int N_FREQS = 4;
localparam int N_SAMP_PER_FREQ = 2**14;
int freqs [N_FREQS] = {12_130_000, 517_036_000, 1_729_725_000, 2_759_000};

logic [PHASE_BITS-1:0] phase_inc, phase;
logic [PARALLEL_SAMPLES:0][PHASE_BITS-1:0] sample_phases;

logic [PARALLEL_SAMPLES-1:0][OUTPUT_WIDTH-1:0] cos_dout;

localparam real PI = 3.14159265;
logic signed [OUTPUT_WIDTH-1:0] test_lut [LUT_DEPTH];

function logic[PHASE_BITS-1:0] get_phase_inc_from_freq(input int freq);
  return unsigned'(int'($floor((real'(freq)/6_400_000_000.0) * (2**(PHASE_BITS)))));
endfunction

always @(posedge clk) begin
  if (reset) begin
    phase <= '0;
    phase_inc <= '0;
  end else begin
    if (phase_inc_in.valid && phase_inc_in.ready) begin
      phase_inc <= phase_inc_in.data;
    end
    for (int i = 0; i < PARALLEL_SAMPLES + 1; i++) begin
      sample_phases[i] <= phase_inc * i;
    end
    if (cos_out.ready && cos_out.valid) begin
      phase <= phase + sample_phases[PARALLEL_SAMPLES];
    end
    for (int i = 0; i < PARALLEL_SAMPLES; i++) begin
      cos_dout[i] <= test_lut[(phase + sample_phases[i]) >> QUANT_BITS];
    end
  end
end

initial begin
  for (int i = 0; i < LUT_DEPTH; i = i + 1) begin
    test_lut[i] <= signed'(int'($floor($cos(2*PI/(LUT_DEPTH)*i)*(2**(OUTPUT_WIDTH-1) - 0.5) - 0.5)));
  end
  reset <= 1'b1;
  repeat (50) @(posedge clk);
  reset <= 1'b0;
  repeat (20) @(posedge clk);
  cos_out.ready <= 1'b1;
  cos_scale_in.data <= 4'b1;
  cos_scale_in.valid <= 1'b1;
  //repeat (100) @(posedge clk);
  for (int i = 0; i < N_FREQS; i++) begin
    phase_inc_in.data <= get_phase_inc_from_freq(freqs[i]);
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
