// noise event tracker - Reed Foster
// performs real-time compression of incoming noise signal
// if samples are above some high threshold, then record the samples
// once they dip below a low threshold, stop recording until they go above the
// high threshold again.  for the first sample that exceeds the high threshold
// after a period of low samples, also output a timestamp
// (CLOCK_WIDTH bits) immediately following the sample.
//
// data format (LSB 1'bx is channel index)
// sample: {sample[15:3], 1'bx, 1'b0, 1'bx} bit 2 1'bx is new_is_high
// timestamp (4 successive transactions): {clock[i*14+:14], 1'b1, 1'bx} for i = 0..3
// (assumes 56-bit CLOCK_WIDTH, will be different #transactions for
// wider/narrower sample counters)

module noise_event_tracker #(
  parameter int BUFFER_DEPTH = 1024, // size will be BUFFER_DEPTH x AXI_MM_WIDTH
  parameter int SAMPLE_WIDTH = 16,
  parameter int AXI_MM_WIDTH = 128,
  parameter int CLOCK_WIDTH = 42
) (
  input wire clk, reset,
  Axis_If.Master_Full data_out, // collection of samples
  Axis_If.Slave_Simple data_in_00, // two least significant bits of each sample will be trimmed off
  Axis_If.Slave_Simple data_in_02,
  Axis_If.Slave_Simple config_in // {start, stop, threshold_high, threshold_low}
);

// always accept transactions
assign config_in.ready = 1'b1;

Axis_If #(.DWIDTH(SAMPLE_WIDTH)) ch_00_disc_in ();
Axis_If #(.DWIDTH(SAMPLE_WIDTH)) ch_02_disc_in ();
Axis_If #(.DWIDTH(SAMPLE_WIDTH)) ch_00_disc_out ();
Axis_If #(.DWIDTH(SAMPLE_WIDTH)) ch_02_disc_out ();
Axis_If #(.DWIDTH(2*SAMPLE_WIDTH)) ch_00_config_in ();
Axis_If #(.DWIDTH(2*SAMPLE_WIDTH)) ch_02_config_in ();

// disc_in inputs
assign ch_00_disc_in.valid = data_in_00.valid;
assign ch_02_disc_in.valid = data_in_02.valid;
assign data_in_00.ready = ch_00_disc_in.ready;
assign data_in_02.ready = ch_02_disc_in.ready;
assign ch_00_disc_in.data = {data_in_00.data[SAMPLE_WIDTH-1:1], 1'b0};
assign ch_02_disc_in.data = {data_in_02.data[SAMPLE_WIDTH-1:1], 1'b1};

// merge config; we'll use the same threshold for both channels
assign ch_00_config_in.valid = config_in.valid;
assign ch_02_config_in.valid = config_in.valid;
assign ch_00_config_in.data = config_in.data[2*SAMPLE_WIDTH-1:0];
assign ch_02_config_in.data = config_in.data[2*SAMPLE_WIDTH-1:0];

// split up config vector
logic config_in_start, config_in_stop;
assign config_in_start = config_in.data[2*SAMPLE_WIDTH+1];
assign config_in_stop = config_in.data[2*SAMPLE_WIDTH];

//////////////////////////////////////////////////////
// combine FIFO outputs into a single word
//////////////////////////////////////////////////////

logic fifo_select;
logic [1:0] fifo_valid;
logic [1:0][SAMPLE_WIDTH-1:0] fifo_out_data;
assign fifo_valid = {ch_02_disc_out.valid, ch_00_disc_out.valid};
assign fifo_out_data = {ch_02_disc_out.data, ch_00_disc_out.data};

always_comb begin
  if (ch_00_disc_out.valid) begin
    fifo_select = 0;
    ch_00_disc_out.ready = 1'b1;
    ch_02_disc_out.ready = 1'b0;
  end else begin
    if (ch_02_disc_out.valid) begin
      fifo_select = 1;
      ch_00_disc_out.ready = 1'b0;
      ch_02_disc_out.ready = 1'b1;
    end else begin
      // default to fifo 0, but don't actually enable either
      fifo_select = 0;
      ch_00_disc_out.ready = 1'b0;
      ch_02_disc_out.ready = 1'b0;
    end
  end
end

sample_discriminator #(
  .SAMPLE_WIDTH(SAMPLE_WIDTH),
  .CLOCK_WIDTH(CLOCK_WIDTH)
) sample_discriminator_ch_00 (
  .clk,
  .reset,
  .data_in(ch_00_disc_in),
  .data_out(ch_00_disc_out),
  .config_in(ch_00_config_in)
);

sample_discriminator #(
  .SAMPLE_WIDTH(SAMPLE_WIDTH),
  .CLOCK_WIDTH(CLOCK_WIDTH)
) sample_discriminator_ch_02 (
  .clk,
  .reset,
  .data_in(ch_02_disc_in),
  .data_out(ch_02_disc_out),
  .config_in(ch_02_config_in)
);

//////////////////////////////////////////////////////
// sample buffer and state machine
//////////////////////////////////////////////////////
// state machine and buffer signals
enum {IDLE, CAPTURE, TRANSFER, POSTTRANSFER} state;
logic [AXI_MM_WIDTH-1:0] buffer [BUFFER_DEPTH];
logic [$clog2(BUFFER_DEPTH)-1:0] write_addr, read_addr, read_stop_addr, read_addr_d;
logic [AXI_MM_WIDTH-1:0] data_out_word;
logic [2:0] data_out_valid; // extra valid and last to match latency of BRAM
assign data_out.valid = data_out_valid[1];
// memory read/write bus have the same width (wider than sample width)
// select appropriate subword range of input word when writing from FIFOs
localparam int WORD_SIZE = 2**($clog2(SAMPLE_WIDTH));
localparam int WORD_SELECT_BITS = $clog2(AXI_MM_WIDTH) - $clog2(WORD_SIZE);
logic [WORD_SELECT_BITS-1:0] data_word_select;
logic [AXI_MM_WIDTH-1:0] data_in_word;
logic data_in_word_valid;
always_ff @(posedge clk) begin
  if (reset) begin
    data_word_select <= '0;
    data_in_word <= '0;
    data_in_word_valid <= 1'b0;
  end else begin
    if (fifo_valid[fifo_select]) begin
      // word will continuously update and only be read into sample buffer
      // when a capture is started.
      data_in_word[data_word_select*WORD_SIZE+:WORD_SIZE] <= fifo_out_data[fifo_select];
      data_word_select <= data_word_select + 1'b1; // rolls over since AXI_MM_WIDTH is a power of 2
    end
    data_in_word_valid <= fifo_valid[fifo_select] && (data_word_select == 2**WORD_SELECT_BITS - 1);
  end
end

// state machine
always_ff @(posedge clk) begin
  if (reset) begin
    state <= IDLE;
  end else begin
    unique case (state)
      // config_in.ready is held high, so whenever config_in.valid goes high,
      // an AXI-stream transaction can take place
      IDLE: if (config_in.valid && config_in_start) state <= CAPTURE;
      CAPTURE: begin
        if ((config_in.valid && config_in_stop)
            || (data_in_word_valid && (write_addr == BUFFER_DEPTH - 1))) begin
          state <= TRANSFER;
        end
      end
      TRANSFER: if ((read_addr_d == read_stop_addr) && data_out.ready) state <= POSTTRANSFER;
      POSTTRANSFER: if (data_out.last && data_out.valid && data_out.ready) state <= IDLE;
    endcase
  end
end
// sample buffer logic
// let's actually make the data_out_valid to spec
// will be a little bit of work, since we want to register the output (so
// valid will have to be delayed appropriately), but valid shouldn't
// depend on ready signal from DMA IP (according to spec).
// buffer design
always_ff @(posedge clk) begin
  if (reset) begin
    data_out_valid <= '0;
    data_out.last <= '0;
    read_addr <= '0;
    read_addr_d <= '0;
    write_addr <= '0;
  end else begin
    unique case (state)
      IDLE: begin
        data_out_valid <= '0;
        data_out.last <= '0;
        read_addr <= '0;
        read_addr_d <= '0;
        write_addr <= '0;
        read_stop_addr <= '0;
      end
      CAPTURE: begin
        if (data_in_word_valid) begin
          buffer[write_addr] <= data_in_word;
          write_addr <= write_addr + 1'b1;
          read_stop_addr <= write_addr;
        end
      end
      TRANSFER: begin
        if (data_out.ready || !data_out.valid) begin // as long as output is ready, increment address
          if (read_addr != read_stop_addr) begin
            read_addr <= read_addr + 1'b1;
            data_out_valid <= {data_out_valid[0], 1'b1};
          end
          if (read_addr_d == read_stop_addr) begin
            data_out_valid <= {data_out_valid[0], 1'b0};
            data_out.last <= 1'b1;
          end
          data_out_word <= buffer[read_addr];
          data_out.data <= data_out_word;
          read_addr_d <= read_addr;
        end
      end
      POSTTRANSFER: begin
        // handle last signal
        if (data_out.ready) begin
          data_out.last <= 1'b0;
          data_out_valid <= {data_out_valid[0], 1'b0};
        end
      end
    endcase
  end
end

endmodule

module noise_event_tracker_sv_wrapper #(
  parameter int BUFFER_DEPTH = 1024,
  parameter int SAMPLE_WIDTH = 16,
  parameter int AXI_MM_WIDTH = 128,
  parameter int CLOCK_WIDTH = 42
) (
  input wire clk, reset,

  output [AXI_MM_WIDTH-1:0] data_out,
  output data_out_valid,
  output data_out_last,
  input data_out_ready,

  input [SAMPLE_WIDTH-1:0] data_in_00,
  input data_in_00_valid,
  output data_in_00_ready,

  input [SAMPLE_WIDTH-1:0] data_in_02,
  input data_in_02_valid,
  output data_in_02_ready,

  input [2+2*SAMPLE_WIDTH-1:0] config_in,
  input config_in_valid,
  output config_in_ready
);

Axis_If #(.DWIDTH(SAMPLE_WIDTH)) data_in_00_if();
Axis_If #(.DWIDTH(SAMPLE_WIDTH)) data_in_02_if();
Axis_If #(.DWIDTH(AXI_MM_WIDTH)) data_out_if();
Axis_If #(.DWIDTH(2+2*SAMPLE_WIDTH)) config_in_if();

noise_event_tracker #(
  .BUFFER_DEPTH(BUFFER_DEPTH),
  .SAMPLE_WIDTH(SAMPLE_WIDTH),
  .AXI_MM_WIDTH(AXI_MM_WIDTH),
  .CLOCK_WIDTH(CLOCK_WIDTH)
) noise_event_tracker_i (
  .clk,
  .reset,
  .data_out(data_out_if),
  .data_in_00(data_in_00_if),
  .data_in_02(data_in_02_if),
  .config_in(config_in_if)
);

assign data_out = data_out_if.data;
assign data_out_valid = data_out_if.valid;
assign data_out_last = data_out_if.last;
assign data_out_if.ready = data_out_ready;

assign data_in_00_if.data = data_in_00;
assign data_in_00_if.valid = data_in_00_valid;
assign data_in_00_ready = data_in_00_if.ready;

assign data_in_02_if.data = data_in_02;
assign data_in_02_if.valid = data_in_02_valid;
assign data_in_02_ready = data_in_02_if.ready;

assign config_in_if.data = config_in;
assign config_in_if.valid = config_in_valid;
assign config_in_ready = config_in_if.ready;

endmodule
