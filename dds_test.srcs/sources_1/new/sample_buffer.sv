// sample buffer
module sample_buffer # (
  parameter int BUFFER_DEPTH = 1024,
  parameter int PARALLEL_SAMPLES = 4,
  parameter int INPUT_SAMPLE_WIDTH = 18,
  parameter int OUTPUT_SAMPLE_WIDTH = 16,
  parameter int AXI_MM_WIDTH = 128
)(
  input wire clk, reset,
  Axis_If.Master_Full data_out, // packed pair of samples
  Axis_If.Slave_Simple data_in,
  input wire capture // trigger capture of samples in buffer
);

assign data_in.ready = 1'b1; // always accept data

// buffer and trigger logic
enum {IDLE, CAPTURE, TRANSFER} state;
logic capture_d;
logic [PARALLEL_SAMPLES*OUTPUT_SAMPLE_WIDTH-1:0] buffer [BUFFER_DEPTH];
logic [$clog2(BUFFER_DEPTH)-1:0] write_addr, read_addr;
logic [PARALLEL_SAMPLES*OUTPUT_SAMPLE_WIDTH-1:0] buffer_data_in;
logic [PARALLEL_SAMPLES*OUTPUT_SAMPLE_WIDTH-1:0] data_out_full_width;
logic data_out_valid;
logic data_out_last;

localparam bit UNEQUAL_RW_WIDTH = PARALLEL_SAMPLES*OUTPUT_SAMPLE_WIDTH != AXI_MM_WIDTH;
localparam int WORD_SELECT_BITS = $clog2(PARALLEL_SAMPLES*OUTPUT_SAMPLE_WIDTH)-$clog2(AXI_MM_WIDTH);
localparam int WORD_SELECT_MAX = 2**WORD_SELECT_BITS - 1;
logic [WORD_SELECT_BITS-1:0] read_word_select, read_word_select_d;

// state transitions
always @(posedge clk) begin
  if (reset) begin
    state <= IDLE;
  end else begin
    unique case (state)
      IDLE: if (capture && !capture_d) state <= CAPTURE;
      CAPTURE: if (write_addr == {$clog2(BUFFER_DEPTH){1'b1}}) state <= TRANSFER;
      TRANSFER: if (data_out_last) state <= IDLE;
    endcase
  end
end

always @(posedge clk) begin
  capture_d <= capture;
  if (reset) begin
    write_addr <= '0;
    read_addr <= '0;
    read_word_select <= '0;
    read_word_select_d <= '0;
    data_out_valid <= '0;
    data_out_last <= 1'b0;
  end else begin
    unique case (state)
      IDLE: begin
        write_addr <= '0;
        read_addr <= '0;
        read_word_select <= '0;
        read_word_select_d <= '0;
        data_out_valid <= 1'b0;
        data_out.valid <= 1'b0;
        data_out_last <= 1'b0;
        data_out.last <= 1'b0;
      end
      CAPTURE: begin
        if (data_in.valid) begin
          buffer[write_addr] <= buffer_data_in;
          write_addr <= write_addr + 1'b1;
        end
      end
      TRANSFER: begin
        if (data_out.ready) begin
          data_out_valid <= 1'b1;
          data_out.valid <= data_out_valid;
          data_out.last <= data_out_last;
          data_out_full_width <= buffer[read_addr];
          read_word_select_d <= read_word_select;
          if (UNEQUAL_RW_WIDTH) begin
            data_out.data <= data_out_full_width[AXI_MM_WIDTH*read_word_select_d+:AXI_MM_WIDTH];
            if (read_word_select == WORD_SELECT_MAX) begin
              read_word_select <= '0;
              if (read_addr == {$clog2(BUFFER_DEPTH){1'b1}}) begin
                data_out_last <= 1'b1;
                read_addr <= '0;
              end else begin
                read_addr <= read_addr + 1'b1;
              end
            end else begin
              read_word_select <= read_word_select + 1'b1;
            end
          end else begin
            data_out.data <= data_out_full_width;
            if (read_addr == {$clog2(BUFFER_DEPTH){1'b1}}) begin
              data_out_last <= 1'b1;
              read_addr <= '0;
            end else begin
              read_addr <= read_addr + 1'b1;
            end
          end
        end
      end
    endcase
  end
end

// buffer input and output
always @(posedge clk) begin
  for (int i = 0; i < PARALLEL_SAMPLES; i++) begin
    // only take OUTPUT_SAMPLE_WIDTH MSBs of each parallel sample of input data
    buffer_data_in[OUTPUT_SAMPLE_WIDTH*i+:OUTPUT_SAMPLE_WIDTH] <= data_in.data[(i+1)*INPUT_SAMPLE_WIDTH-OUTPUT_SAMPLE_WIDTH+:OUTPUT_SAMPLE_WIDTH];
  end
end

endmodule

// wrapper so this can be instantiated in .v file
module sample_buffer_sv_wrapper #(
  parameter int BUFFER_DEPTH = 1024,
  parameter int PARALLEL_SAMPLES = 4,
  parameter int INPUT_SAMPLE_WIDTH = 18,
  parameter int OUTPUT_SAMPLE_WIDTH = 16,
  parameter int AXI_MM_WIDTH = 128
) (
  input wire clk, reset,
  output [AXI_MM_WIDTH-1:0] data_out,
  output data_out_valid, data_out_last,
  input data_out_ready,
  input [INPUT_SAMPLE_WIDTH*PARALLEL_SAMPLES:0] data_in,
  input data_in_valid,
  output data_in_ready,
  input wire capture
);

Axis_If #(.DWIDTH(INPUT_SAMPLE_WIDTH*PARALLEL_SAMPLES)) data_in_if();
Axis_If #(.DWIDTH(AXI_MM_WIDTH)) data_out_if();

sample_buffer #(
  .BUFFER_DEPTH(BUFFER_DEPTH),
  .PARALLEL_SAMPLES(PARALLEL_SAMPLES),
  .INPUT_SAMPLE_WIDTH(INPUT_SAMPLE_WIDTH),
  .OUTPUT_SAMPLE_WIDTH(OUTPUT_SAMPLE_WIDTH),
  .AXI_MM_WIDTH(AXI_MM_WIDTH)
) buffer_i (
  .clk,
  .reset,
  .data_out(data_out_if),
  .data_in(data_in_if),
  .capture
);

assign data_out = data_out_if.data;
assign data_out_valid = data_out_if.valid;
assign data_out_last = data_out_if.last;
assign data_out_if.ready = data_out_ready;

assign data_in_if.data = data_in;
assign data_in_if.valid = data_in_valid;
assign data_in_ready = data_in_if.ready;

endmodule
