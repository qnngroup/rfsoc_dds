// noise event tracker
// performs real-time compression of incoming noise signal
// if noise level is above some threshold, then record the noise level at
// full rate (2MS/s), until it goes below some threshold, then record at low
// rate (e.g. 200S/s, no filtering before decimation, so any high frequency
// variation (e.g. 100Hz-1MHz in the noise power will alias)
// optionally, for mode = 0, always record data at the full rate
module noise_event_tracker #(
  parameter int BUFFER_DEPTH = 1024, // size will be BUFFER_DEPTH x AXI_MM_WIDTH
  parameter int SAMPLE_WIDTH = 16,
  parameter int AXI_MM_WIDTH = 128,
  parameter int DECIMATION_BELOW_THRESH = 10000 // 200S/s
) (
  input wire clk, reset,
  Axis_If.Master_Full data_out, // packed collection of samples
  Axis_If.Slave_Simple data_in_00, // two least significant bits of each sample will be trimmed off
  Axis_If.Slave_Simple data_in_02,
  Axis_If.Slave_Simple config_in // {mode, start, stop, threshold_high, threshold_low}
);

// always accept transactions
assign config_in.ready = 1'b1;
assign data_in_00.ready = 1'b1;
assign data_in_02.ready = 1'b1;

// split up config vector
logic config_in_mode, config_in_start, config_in_stop;
assign config_in_mode = config_in.data[2*SAMPLE_WIDTH+2];
assign config_in_start = config_in.data[2*SAMPLE_WIDTH+1];
assign config_in_stop = config_in.data[2*SAMPLE_WIDTH];

logic [SAMPLE_WIDTH-1:0] threshold_low, threshold_high;
logic mode; // 1 for rate compression, 0 for always full rate

// update mode and thresholds from config interface
always_ff @(posedge clk) begin
  if (reset) begin
    mode <= 1'b0; // by default record at full-rate
    threshold_low <= '1;
    threshold_high <= '0;
  end else begin
    if (config_in.valid) begin
      mode <= config_in_mode;
      threshold_high <= config_in.data[2*SAMPLE_WIDTH-1:SAMPLE_WIDTH];
      threshold_low <= config_in.data[SAMPLE_WIDTH-1:0];
    end
  end
end

//////////////////////////////////////////////////////
// main datapath and compression logic
//////////////////////////////////////////////////////

// track the state of the noise in each channel for hysteresis of sample recording:
// once the noise exceeds the high threshold, record at full rate until the
// noise dips below the low threshold
// two bits: one for each channel, set to 1 if high threshold was exceeded
// reset to 0 if noise level subsequently falls below low threshold
logic [1:0] noise_level;

// merge data from separate streams into indexable signals
logic [SAMPLE_WIDTH-1:0] data_in [2];
logic [1:0] data_in_valid;

assign data_in[0] = data_in_00.data;
assign data_in[1] = data_in_02.data;
assign data_in_valid[0] = data_in_00.valid;
assign data_in_valid[1] = data_in_02.valid;

// datapath signals
logic [SAMPLE_WIDTH-1:0] data_in_d [2];
logic [1:0] data_in_valid_d [2];
logic [$clog2(DECIMATION_BELOW_THRESH)-1:0] dec_counter [2];
logic [SAMPLE_WIDTH-1:0] fifo_out_data [2];
logic [1:0] fifo_ready;
logic [1:0] fifo_not_empty;

// apply fifos to merge data from two axi streams
generate begin: fifo_gen
  for (genvar i = 0; i < 2; i++) begin
    Axis_If #(.DWIDTH(SAMPLE_WIDTH)) fifo_in ();
    Axis_If #(.DWIDTH(SAMPLE_WIDTH)) fifo_out ();

    assign fifo_in.valid = ((dec_counter[i] == 0) || mode == 0) && data_in_valid_d[i][1];
    assign fifo_not_empty[i] = fifo_out.valid;
    assign fifo_out_data[i] = fifo_out.data;
    assign fifo_out.ready = fifo_ready[i];

    // ignore fifo_in.ready
    // input is at 2MS/s, clock is 150MHz so samples are sparse in time
    // FIFO is purely for arbitration so that if two samples arrive at the
    // same time, they can be written to the sample buffer sequentially

    always_ff @(posedge clk) begin
      data_in_d[i] <= data_in[i];
      data_in_valid_d[i] <= {data_in_valid_d[i][0], data_in_valid[i]};
      fifo_in.data <= {data_in_d[i][SAMPLE_WIDTH-1:2], 1'(i), noise_level[i]};
      if (reset) begin
        noise_level[i] <= '0;
        dec_counter[i] <= '0;
      end else begin
        // update noise level register
        if (data_in_valid[i]) begin
          if (data_in[i] > threshold_high) begin
            noise_level[i] <= 1'b1;
          end else if (data_in[i] < threshold_low) begin
            noise_level[i] <= 1'b0;
          end
        end
        // manage decimation counter
        if (noise_level[i]) begin
          dec_counter[i] <= '0;
        end else begin
          // noise is low, so update decimation counter
          if (data_in_valid_d[i][0]) begin
            if (dec_counter[i] == DECIMATION_BELOW_THRESH - 1) begin
              dec_counter[i] <= '0;
            end else begin
              dec_counter[i] <= dec_counter[i] + 1'b1;
            end
          end
        end
      end
    end

    fifo #(
      .DATA_WIDTH(SAMPLE_WIDTH),
      .ADDR_WIDTH(3)
    ) fifo_i (
      .clk,
      .reset,
      .data_out(fifo_out),
      .data_in(fifo_in)
    );
  end
end
endgenerate

//////////////////////////////////////////////////////
// combine FIFO outputs into a single word
//////////////////////////////////////////////////////

logic fifo_select;
always_comb begin
  if (fifo_not_empty[0]) begin
    fifo_select = 0;
    fifo_ready = 2'b01;
  end else begin
    if (fifo_not_empty[1]) begin
      fifo_select = 1;
      fifo_ready = 2'b10;
    end else begin
      // default to fifo 0
      fifo_select = 0;
      fifo_ready = 2'b0;
    end
  end
end

// memory read/write bus have the same width (wider than sample width)
// select appropriate subword range of input word when writing from FIFOs
localparam int WORD_SIZE = 2**($clog2(SAMPLE_WIDTH));
localparam int WORD_SELECT_BITS = $clog2(AXI_MM_WIDTH) - $clog2(SAMPLE_WIDTH);
logic [WORD_SELECT_BITS-1:0] word_select;
logic [AXI_MM_WIDTH-1:0] data_in_word;
logic data_in_word_valid;
always_ff @(posedge clk) begin
  if (reset) begin
    word_select <= '0;
    data_in_word <= '0;
    data_in_word_valid <= 1'b0;
  end else begin
    if (fifo_not_empty[fifo_select]) begin
      // word will continuously update and only be read into sample buffer
      // when a capture is started. yes this is a little inefficient but
      // I didn't think of it in advance and I don't want to rewrite the input
      // logic
      data_in_word[word_select*WORD_SIZE+:WORD_SIZE] <= fifo_out_data[fifo_select];
      word_select <= word_select + 1'b1; // rolls over since AXI_MM_WIDTH is a power of 2
    end
    data_in_word_valid <= fifo_not_empty[fifo_select] && (word_select == 2**WORD_SELECT_BITS - 1);
  end
end

//////////////////////////////////////////////////////
// main state machine and sample buffer
//////////////////////////////////////////////////////
enum {IDLE, CAPTURE, POSTCAPTURE, PRETRANSFER, TRANSFER} state;
logic [AXI_MM_WIDTH-1:0] buffer [BUFFER_DEPTH];
logic [$clog2(BUFFER_DEPTH)-1:0] write_addr, read_addr, read_stop_addr;
logic [AXI_MM_WIDTH-1:0] data_out_word [2];
logic [2:0] data_out_valid; // extra valid and last to match latency of BRAM
logic [1:0] data_out_last;
assign data_out.data = data_out_word[1];
assign data_out.valid = data_out_valid[2];
assign data_out.last = data_out_last[1];
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
          state <= POSTCAPTURE;
        end
      end
      POSTCAPTURE: state <= PRETRANSFER;
      PRETRANSFER: if (data_out_valid[1]) state <= TRANSFER;
      TRANSFER: if (data_out.last && data_out.valid && data_out.ready) state <= IDLE;
    endcase
  end
end
// sample buffer logic
// let's actually make the data_out_valid to spec
// will be a little bit of work, since we want to register the output (so
// valid will have to be delayed appropriately), but valid shouldn't
// depend on ready signal from DMA IP (according to spec).
always_ff @(posedge clk) begin
  if (reset) begin
    data_out_valid <= '0;
    data_out_last <= '0;
    read_addr <= '0;
    write_addr <= '0;
  end else begin
    unique case (state)
      IDLE: begin
        data_out_valid <= '0;
        data_out_last <= '0;
        read_addr <= '0;
        write_addr <= '0;
      end
      CAPTURE: begin
        if (data_in_word_valid) begin
          buffer[write_addr] <= data_in_word;
          write_addr <= write_addr + 1'b1;
          read_stop_addr <= write_addr;
        end
      end
      POSTCAPTURE: begin
        data_out_valid <= {data_out_valid[1:0], 1'b1};
        data_out_word[0] <= buffer[read_addr];
        data_out_word[1] <= data_out_word[0];
      end
      PRETRANSFER: begin
        // repeats until data_out.valid is high
        data_out_valid <= {data_out_valid[1:0], 1'b0};
        data_out_word[0] <= buffer[read_addr];
        data_out_word[1] <= data_out_word[0];
      end
      TRANSFER: begin
        if (data_out.ready) begin // as long as output is ready, increment address
          data_out_word[0] <= buffer[read_addr];
          data_out_word[1] <= data_out_word[0];
          if (read_addr == read_stop_addr) begin
            // stop reading after we've finished reading everything that's
            // been written to the buffer
            // set last signal high and valid signal low
            data_out_valid <= {data_out_valid[1:0], 1'b0};
            read_addr <= read_stop_addr;
            data_out_last <= {data_out_last[0], ~data_out_last[0]};
          end else begin
            // while we're not done reading from the buffer,
            // increment the read address and set valid signal high
            read_addr <= read_addr + 1'b1;
            data_out_valid <= {data_out_valid[1:0], 1'b1};
            data_out_last <= {data_out_last[0], 1'b0};
          end
        end
      end
    endcase
  end
end

endmodule

module noise_event_tracker_sv_wrapper #(
  parameter int BUFFER_DEPTH = 1024,
  parameter int SAMPLE_WIDTH = 16,
  parameter int AXI_MM_WIDTH = 128
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

  input config_in,
  input config_in_valid,
  output config_in_ready
);

Axis_If #(.DWIDTH(SAMPLE_WIDTH)) data_in_00_if();
Axis_If #(.DWIDTH(SAMPLE_WIDTH)) data_in_02_if();
Axis_If #(.DWIDTH(AXI_MM_WIDTH)) data_out_if();
Axis_If #(.DWIDTH(3+2*SAMPLE_WIDTH)) config_in_if();

noise_event_tracker #(
  .BUFFER_DEPTH(BUFFER_DEPTH),
  .SAMPLE_WIDTH(SAMPLE_WIDTH),
  .AXI_MM_WIDTH(AXI_MM_WIDTH)
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
