// sample discriminator - Reed Foster
// If input sample is above high threshold (with hysteresis), it is passed through,
// otherwise it is dropped. If the preceeding sample was below the low threshold,
// then a timestamp is also sent out after the current sample (indicated by
// setting some flag bits)
// data format (LSB 1'bx is channel index)
// sample: {sample[15:3], 1'bx, 1'b0, 1'bx} bit 2 1'bx is new_is_high
// timestamp (4 successive transactions): {clock[i*14+:14], 1'b1, 1'bx} for i = 0..3
module sample_discriminator #( 
  parameter int SAMPLE_WIDTH = 16,
  parameter int CLOCK_WIDTH = 56 // rolls over roughly every 10 years
) (
  input wire clk, reset,
  Axis_If.Slave_Simple data_in,
  Axis_If.Master_Simple data_out,
  Axis_If.Slave_Simple config_in // {threshold_high, threshold_low}
);

// mask of LSB so we don't erroneously compare with the lower bits of the threshold
localparam logic [SAMPLE_WIDTH-1:0] DATA_MASK = {{(SAMPLE_WIDTH-1){1'b1}}, 1'b0};

assign config_in.ready = 1'b1;
assign data_in.ready = 1'b1; // always process new samples; we'll just throw them away later if we don't need them

logic signed [SAMPLE_WIDTH-1:0] threshold_low, threshold_high;
logic [SAMPLE_WIDTH-1:0] data_in_reg;
logic data_in_valid;
logic [CLOCK_WIDTH-1:0] sample_count;

// update thresholds from config interface
always_ff @(posedge clk) begin
  if (reset) begin
    threshold_low <= '0;
    threshold_high <= '0;
  end else begin
    if (config_in.valid) begin
      threshold_high <= config_in.data[2*SAMPLE_WIDTH-1:SAMPLE_WIDTH];
      threshold_low <= config_in.data[SAMPLE_WIDTH-1:0];
    end
  end
end

logic is_high, is_high_d;
logic new_is_high;
assign new_is_high = is_high & (!is_high_d);

always_ff @(posedge clk) begin
  if (reset) begin
    is_high <= '0;
    is_high_d <= '0;
    sample_count <= '0;
  end else begin
    data_in_valid <= data_in.valid;
    if (data_in.valid) begin
      data_in_reg <= data_in.data;
      is_high_d <= is_high;
      sample_count <= sample_count + 1'b1;
      if (signed'(data_in.data & DATA_MASK) > threshold_high) begin
        is_high <= 1'b1;
      end else if (signed'(data_in.data & DATA_MASK) < threshold_low) begin
        is_high <= 1'b0;
      end
    end
  end
end

Axis_If #(.DWIDTH(SAMPLE_WIDTH+CLOCK_WIDTH)) input_fifo_in ();
Axis_If #(.DWIDTH(SAMPLE_WIDTH+CLOCK_WIDTH)) input_fifo_out ();
Axis_If #(.DWIDTH(SAMPLE_WIDTH)) output_fifo_in ();

fifo #(
  .DATA_WIDTH(SAMPLE_WIDTH+CLOCK_WIDTH),
  .ADDR_WIDTH(4) // add some buffer in case we get several samples with alternating noise in a row
) input_fifo_i (
  .clk,
  .reset,
  .data_out(input_fifo_out),
  .data_in(input_fifo_in)
);

localparam int SPLIT_TIMESTAMP_COUNT = CLOCK_WIDTH / (SAMPLE_WIDTH - 2);
logic [$clog2(SPLIT_TIMESTAMP_COUNT+1)-1:0] subword_sel;

assign input_fifo_in.data = {sample_count, data_in_reg[SAMPLE_WIDTH-1:2], new_is_high, data_in_reg[0]};
assign input_fifo_in.valid = data_in_valid & is_high;
assign input_fifo_out.ready = ((!input_fifo_out.data[1]) || (subword_sel == SPLIT_TIMESTAMP_COUNT))
                                && input_fifo_out.valid;
assign output_fifo_in.valid = input_fifo_out.valid;

always_comb begin
  if (subword_sel == 0) begin
    // set bit 1 to 0 to indicate the word contains a sample
    // sample: {sample[15:3], 1'bx, 1'b0, 1'bx} bit 2 1'bx is new_is_high
    output_fifo_in.data = {input_fifo_out.data[SAMPLE_WIDTH-1:3],
                            input_fifo_out.data[1], 1'b0, input_fifo_out.data[0]};
  end else begin
    // set bit 1 to 1 to indicate the word contains a timestamp
    // timestamp (4 successive transactions): {clock[i*14+:14], 1'b1, 1'bx} for i = 0..3
    output_fifo_in.data = {input_fifo_out.data[2+subword_sel*(SAMPLE_WIDTH-2)+:(SAMPLE_WIDTH-2)],
                            1'b1, input_fifo_out.data[0]};
  end
end

always_ff @(posedge clk) begin
  if (reset) begin
    subword_sel <= '0;
  end else begin
    if (input_fifo_out.valid && input_fifo_out.data[1]) begin
      if (subword_sel == SPLIT_TIMESTAMP_COUNT) begin
        subword_sel <= '0;
      end else begin
        subword_sel <= subword_sel + 1'b1;
      end
    end
  end
end

fifo #(
  .DATA_WIDTH(SAMPLE_WIDTH),
  .ADDR_WIDTH(4)
) output_fifo_i (
  .clk,
  .reset,
  .data_out(data_out),
  .data_in(output_fifo_in)
);

endmodule
