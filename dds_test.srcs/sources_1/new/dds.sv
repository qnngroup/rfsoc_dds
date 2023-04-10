module dds #(
  parameter int PHASE_BITS = 24,
  parameter int OUTPUT_WIDTH = 18,
  parameter int QUANT_BITS = 8,
  parameter int PARALLEL_SAMPLES = 4
) (
  input wire clk, reset,
  Axis_If.Master_Simple cos_out,
  Axis_If.Slave_Simple phase_inc_in,
  Axis_If.Slave_Simple cos_scale_in
);


localparam int LUT_ADDR_BITS = PHASE_BITS - QUANT_BITS;
localparam int LUT_DEPTH = 2**LUT_ADDR_BITS;

assign phase_inc_in.ready = 1'b1;
assign cos_scale_in.ready = 1'b1;

// generate LUT
localparam real PI = 3.14159265;
logic signed [OUTPUT_WIDTH-1:0] lut [LUT_DEPTH];
initial begin
  for (int i = 0; i < LUT_DEPTH; i = i + 1) begin
    lut[i] = signed'(int'($floor($cos(2*PI/(LUT_DEPTH)*i)*(2**(OUTPUT_WIDTH-1) - 0.5) - 0.5)));
  end
end

// update phases
logic [PARALLEL_SAMPLES-1:0][PHASE_BITS-1:0] phase_inc;
logic [PHASE_BITS-1:0] cycle_phase;
logic [PARALLEL_SAMPLES-1:0][PHASE_BITS-1:0] sample_phase;
assign phase_inc_in.ready = 1'b1;
always @(posedge clk) begin
  if (reset) begin
    phase_inc <= '0;
    cycle_phase <= '0;
    sample_phase <= '0;
  end else begin
    // load new phase_inc
    if (phase_inc_in.ready && phase_inc_in.valid) begin
      for (int i = 0; i < PARALLEL_SAMPLES; i = i + 1) begin
        phase_inc[i] <= phase_inc_in.data * (i + 1);
      end
    end
    if (cos_out.ready) begin
      cycle_phase <= cycle_phase + phase_inc[PARALLEL_SAMPLES-1];
      sample_phase[0] <= cycle_phase;
      for (int i = 1; i < PARALLEL_SAMPLES; i = i + 1) begin
        sample_phase[i] <= cycle_phase + phase_inc[i-1];
      end
    end
  end
end

// dither LFSR
logic [PARALLEL_SAMPLES-1:0][15:0] lfsr;
lfsr16_parallel #(.PARALLEL_SAMPLES(PARALLEL_SAMPLES)) lfsr_i (
  .clk,
  .reset,
  .enable(cos_out.ready),
  .data_out(lfsr)
);

logic [PARALLEL_SAMPLES-1:0][PHASE_BITS-1:0] phase_dithered;
logic [PARALLEL_SAMPLES-1:0][LUT_ADDR_BITS-1:0] phase_quant;
// delay data_valid to match phase increment + LUT latency
logic [3:0] data_valid;
assign cos_out.valid = data_valid[3];
// this isn't working right --- need to fix sign extension, and a bunch of samples are getting zeroed out
logic signed [OUTPUT_WIDTH-1:0] data_out_full_scale [PARALLEL_SAMPLES];
logic [$clog2(OUTPUT_WIDTH)-1:0] cos_scale;
genvar i;
generate
  for (i = 0; i < PARALLEL_SAMPLES; i = i + 1) begin
    if (QUANT_BITS > 16) begin
      assign phase_dithered[i] = {lfsr[i], {(QUANT_BITS - 16){1'b0}}} + sample_phase[i];
    end else begin
      assign phase_dithered[i] = lfsr[i][QUANT_BITS-1:0] + sample_phase[i];
    end
    always @(posedge clk) begin
      cos_out.data[OUTPUT_WIDTH*i+:OUTPUT_WIDTH] <= data_out_full_scale[i] >>> cos_scale;
      if (reset) begin
        data_out_full_scale[i] <= '0;
        phase_quant[i] <= '0;
      end else begin
        if (cos_out.ready) begin
          phase_quant[i] <= phase_dithered[i][PHASE_BITS-1:QUANT_BITS];
          data_out_full_scale[i] <= lut[phase_quant[i]];
        end
      end
    end
  end
endgenerate

always @(posedge clk) begin
  if (reset) begin
    cos_scale <= '0;
    data_valid <= '0;
  end else begin
    if (cos_scale_in.valid) begin
      cos_scale <= cos_scale_in.data;
    end
    data_valid[0] <= 1'b1;
    for (int j = 1; j < 4; j++) begin
      data_valid[j] <= data_valid[j-1];
    end
  end
end

endmodule

module dds_sv_wrapper #(
  parameter int PHASE_BITS = 24,
  parameter int OUTPUT_WIDTH = 18,
  parameter int QUANT_BITS = 8,
  parameter int PARALLEL_SAMPLES = 4
) (
  input wire clk, reset,
  output logic [PARALLEL_SAMPLES*OUTPUT_WIDTH-1:0] cos_out_data,
  output logic cos_out_valid,
  input logic cos_out_ready,
  input logic [PHASE_BITS-1:0] phase_inc_in_data,
  input logic phase_inc_in_valid,
  output logic phase_inc_in_ready,
  input logic [$clog2(OUTPUT_WIDTH)-1:0] cos_scale_in_data,
  input logic cos_scale_in_valid,
  output logic cos_scale_in_ready
);

Axis_If #(.DWIDTH(PHASE_BITS)) phase_inc_if();
Axis_If #(.DWIDTH($clog2(OUTPUT_WIDTH))) cos_scale_if();
Axis_If #(.DWIDTH(PARALLEL_SAMPLES*OUTPUT_WIDTH)) cos_out_if();

assign phase_inc_if.data = phase_inc_in_data;
assign phase_inc_if.valid = phase_inc_in_valid;
assign phase_inc_in_ready = phase_inc_if.ready;

assign cos_scale_if.data = cos_scale_in_data;
assign cos_scale_if.valid = cos_scale_in_valid;
assign cos_scale_in_ready = cos_scale_if.ready;

assign cos_out_data = cos_out_if.data;
assign cos_out_valid = cos_out_if.valid;
assign cos_out_if.ready = cos_out_ready;

dds #(.PHASE_BITS(PHASE_BITS), .OUTPUT_WIDTH(OUTPUT_WIDTH), .QUANT_BITS(QUANT_BITS), .PARALLEL_SAMPLES(PARALLEL_SAMPLES)) dds_i (
  .clk,
  .reset,
  .cos_out(cos_out_if),
  .phase_inc_in(phase_inc_if),
  .cos_scale_in(cos_scale_if)
);

endmodule
