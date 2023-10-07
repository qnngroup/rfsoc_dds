module axis_x2_wrapper #(
  parameter SAMPLE_WIDTH = 16,
  parameter PARALLEL_SAMPLES = 1
) (
  input wire clk, reset_n,
  output [8*((SAMPLE_WIDTH*PARALLEL_SAMPLES+7)/8)-1:0] m_axis_tdata,
  output m_axis_tvalid,
  input m_axis_tready,
  input [8*((SAMPLE_WIDTH*PARALLEL_SAMPLES+7)/8)-1:0] s_axis_tdata,
  input s_axis_tvalid,
  output s_axis_tready
);

wire [SAMPLE_WIDTH*PARALLEL_SAMPLES-1:0] dout;
assign m_axis_tdata = dout; // upper bits will be ignored anyway

axis_x2_sv_wrapper #(
  .SAMPLE_WIDTH(SAMPLE_WIDTH),
  .PARALLEL_SAMPLES(PARALLEL_SAMPLES)
) axis_x2_sv_wrapper_i (
  .clk(clk),
  .reset(~reset_n),
  .data_out(dout),
  .data_out_valid(m_axis_tvalid),
  .data_out_ready(m_axis_tready),
  .data_in(s_axis_tdata[SAMPLE_WIDTH*PARALLEL_SAMPLES-1:0]),
  .data_in_valid(s_axis_tvalid),
  .data_in_ready(s_axis_tready)
);


endmodule
