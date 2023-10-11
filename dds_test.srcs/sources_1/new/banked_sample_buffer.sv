// banked sample buffer
module banked_sample_buffer #(
  parameter int N_CHANNELS = 8, // number of ADC channels
  parameter int BUFFER_DEPTH = 8192, // maximum capacity across all channels
  parameter int PARALLEL_SAMPLES = 16, // 4.096 GS/s @ 256 MHz
  parameter int SAMPLE_WIDTH = 16 // 12-bit ADC
) (
  input wire clk, reset,
  Axis_Parallel_If.Slave_Simple data_in, // all channels in parallel
  Axis_If.Master_Full data_out,
  Axis_If.Slave_Simple config_in // {banking_mode, start, stop}
);

// never apply backpressure to discriminator or ADC
assign data_in.ready = '1; // all channels
assign config_in.ready = 1'b1;

// e.g. for 8 channels, single-channel mode, dual-channel, 4-channel, and 8-channel modes
localparam int N_BANKING_MODES = $clog2(N_CHANNELS) + 1;
logic [$clog2(N_BANKING_MODES)-1:0] banking_mode;
logic [$clog2(N_CHANNELS):0] n_active_channels; // extra bit so we can represent N_CHANNELS
assign n_active_channels = 1'b1 << banking_mode;
logic start, stop;

always_ff @(posedge clk) begin
  if (reset) begin
    start <= '0;
    stop <= '0;
    banking_mode <= '0;
  end else begin
    if (config_in.ok) begin
      banking_mode <= config_in.data[2+:N_BANKING_MODES];
      start <= config_in.data[1];
      stop <= config_in.data[0];
    end else begin
      // reset start/stop so they are only a pulse
      start <= '0;
      stop <= '0;
    end
  end
end

logic [N_CHANNELS-1:0] banks_full;
logic [N_CHANNELS-1:0] full_mask;
logic [N_CHANNELS-1:0] banks_first;
logic banks_stop;
always_comb begin
  if (stop) begin
    banks_stop = 1'b1;
  end else begin
    // mask so only the final bank filling up can stop capture
    // if banking_mode == 0: 1 << N_CHANNELS
    // if banking_mode == 1: 3 << (N_CHANNELS - 1)
    // if banking_mode == 2: 7 << (N_CHANNELS - 2)
    // ...
    full_mask = ((2 << banking_mode) - 1) << (N_CHANNELS - banking_mode);
    banks_stop = |(full_mask & banks_full);
  end
end
logic [$clog2(N_CHANNELS)-1:0] bank_select;
logic [$clog2(N_CHANNELS)-1:0] active_channel_id;
assign active_channel_id = bank_select % n_active_channels;

// bundle of axistreams for each bank output
Axis_Parallel_If #(.DWIDTH(SAMPLE_WIDTH*PARALLEL_SAMPLES), .PARALLEL_CHANNELS(N_CHANNELS)) all_banks_out ();

// mux outputs
always_ff @(posedge clk) begin
  if (reset) begin
    data_out.data <= '0;
    data_out.valid <= 1'b0;
  end else begin
    if (data_out.ready) begin
      if (banks_first[bank_select]) begin
        // first word from each bank contains the number of samples that were stored in the bank
        // use least significant bits of data output to encode which channel the data came from
        data_out.data <= {all_banks_out.data[bank_select][PARALLEL_SAMPLES*SAMPLE_WIDTH-$clog2(N_CHANNELS)-1:0], active_channel_id};
      end else begin
        data_out.data <= all_banks_out.data[bank_select];
      end
      data_out.valid <= all_banks_out.valid[bank_select];
    end
  end
end
// only take last signal from the final bank, and only when the final bank is selected
always_ff @(posedge clk) begin
  data_out.last <= (bank_select == N_CHANNELS - 1) && all_banks_out.last[bank_select];
end
always_comb begin
  for (int i = 0; i < N_CHANNELS; i++) begin
    if (i == bank_select) begin
      all_banks_out.ready[i] = data_out.ready;
    end else begin
      all_banks_out.ready[i] = 1'b0; // stall all other banks until we're done reading out the current one
    end
  end
end

// update which output is selected
always_ff @(posedge clk) begin
  if (reset) begin
    bank_select <= '0;
  end else begin
    if (start) begin
      bank_select <= '0;
    end else if (all_banks_out.ok[bank_select] && all_banks_out.last[bank_select]) begin
      if (bank_select == N_CHANNELS - 1) begin
        bank_select <= '0;
      end else begin
        bank_select <= bank_select + 1'b1;
      end
    end
  end
end

// generate banks
genvar i;
generate
  for (i = 0; i < N_CHANNELS; i++) begin: bank_i
    // only a single interface, but PARALLEL_SAMPLES wide
    // PARALLEL_CHANNELS is used for multiple parallel interfaces with separate valid/ready
    Axis_If #(.DWIDTH(SAMPLE_WIDTH*PARALLEL_SAMPLES)) bank_in ();
    Axis_If #(.DWIDTH(SAMPLE_WIDTH*PARALLEL_SAMPLES)) bank_out ();

    // connect bank_out to all_banks_out
    assign all_banks_out.data[i] = bank_out.data;
    assign all_banks_out.valid[i] = bank_out.valid;
    assign all_banks_out.last[i] = bank_out.last;
    assign bank_out.ready = all_banks_out.ready[i];

    buffer_bank #(
      .BUFFER_DEPTH(BUFFER_DEPTH),
      .PARALLEL_SAMPLES(PARALLEL_SAMPLES),
      .SAMPLE_WIDTH(SAMPLE_WIDTH)
    ) bank_i (
      .clk,
      .reset,
      .data_in(bank_in),
      .data_out(bank_out),
      .start,
      .stop(banks_stop),
      .full(banks_full[i]),
      .first(banks_first[i])
    );

    // mux the channels of data_in depending on banking_mode
    logic valid_d; // match latency of registered data input
    // when chaining banks in series, which bank should the current bank i wait for
    always_comb begin
      if ((n_active_channels != N_CHANNELS) && (i >= n_active_channels)) begin
        bank_in.valid = valid_d & banks_full[i - n_active_channels];
      end else begin
        bank_in.valid = valid_d;
      end
    end
    always_ff @(posedge clk) begin
      bank_in.data <= data_in.data[i % n_active_channels];
      valid_d <= data_in.valid[i];
    end
  end
endgenerate

endmodule

module buffer_bank #(
  parameter int BUFFER_DEPTH = 1024,
  parameter int PARALLEL_SAMPLES = 16, // 4.096 GS/s @ 256 MHz
  parameter int SAMPLE_WIDTH = 16 // 12-bit ADC
) (
  input wire clk, reset,
  Axis_If.Slave_Simple data_in, // one channel
  Axis_If.Master_Full data_out,
  input logic start, stop,
  output logic full, first
);

enum {IDLE, CAPTURE, PRETRANSFER, TRANSFER} state;
// IDLE: wait for start (either from user or from previous bank filling up in
// a high-memory, low-channel count banking mode)
// CAPTURE: save samples until full or until stop is supplied
// PRETRANSFER: output number of captured samples
// TRANSFER: output samples

assign data_in.ready = state == CAPTURE;

logic [PARALLEL_SAMPLES*SAMPLE_WIDTH-1:0] buffer [BUFFER_DEPTH];
logic [$clog2(BUFFER_DEPTH)-1:0] write_addr, read_addr;
logic [1:0][$clog2(BUFFER_DEPTH)-1:0] read_addr_d; // delay so that we don't miss the last sample
logic [3:0][PARALLEL_SAMPLES*SAMPLE_WIDTH-1:0] data_out_d;
logic [3:0] data_out_valid; // extra valid to match latency of BRAM
logic [3:0] data_out_last;
logic buffer_has_data, readout_begun;
assign data_out.data = data_out_d[3];
assign data_out.valid = data_out_valid[3];
assign data_out.last = data_out_last[3];

// state machine
always_ff @(posedge clk) begin
  if (reset) begin
    state <= IDLE;
  end else begin
    unique case (state)
      IDLE: if (start) state <= CAPTURE;
      CAPTURE: if (stop || (data_in.valid && (write_addr == BUFFER_DEPTH - 1))) state <= PRETRANSFER;
      // only transition after successfully sending out number of captured samples:
      PRETRANSFER: if (data_out.valid && data_out.ready) begin
        if (data_out.last) begin
          // no data was saved, so there's nothing to send
          state <= IDLE;
        end else begin
          state <= TRANSFER;
        end
      end
      TRANSFER: if (data_out.last && data_out.ready && data_out.valid) state <= IDLE;
    endcase
  end
end

// sample buffer logic
always_ff @(posedge clk) begin
  if (reset) begin
    write_addr <= '0;
    read_addr <= '0;
    read_addr_d <= '0;
    data_out_d <= '0;
    data_out_valid <= '0;
    data_out_last <= '0;
    buffer_has_data <= '0;
    readout_begun <= '0;
    full <= '0;
    first <= '0;
  end else begin
    unique case (state)
      IDLE: begin
        write_addr <= '0;
        read_addr <= '0;
        read_addr_d <= '0;
        data_out_d <= '0;
        data_out_valid <= '0;
        data_out_last <= '0;
        buffer_has_data <= '0;
        readout_begun <= '0;
        full <= '0;
        first <= '0;
      end
      CAPTURE: begin
        if (data_in.valid) begin
          buffer[write_addr] <= data_in.data;
          write_addr <= write_addr + 1'b1;
          buffer_has_data <= 1'b1;
          if (write_addr == BUFFER_DEPTH - 1) begin
            full <= 1'b1;
          end
        end
      end
      PRETRANSFER: begin
        first <= 1'b1;
        if (write_addr > 0) begin
          data_out_d[3] <= write_addr;
        end else if (buffer_has_data) begin
          // if write_addr == 0 but we've written to the buffer, then it's full
          data_out_d[3] <= BUFFER_DEPTH;
        end else begin
          data_out_d[3] <= '0; // we don't have any data to send
          data_out_last[3] <= 1'b1;
        end
        if (data_out.ready) begin
          // transaction will go through, so we should reset data_out_valid so
          // that we don't accidentally send the sample count twice
          data_out_valid[3] <= 1'b0;
          // also reset last in case we don't have any data to send and the
          // sample count is the only thing we're outputting
          data_out_last[3] <= 1'b0;
        end else begin
          data_out_valid[3] <= 1'b1;
        end
      end
      TRANSFER: begin
        first <= '0;
        if (data_out.ready || (!data_out.valid)) begin
          // in case the entire buffer was filled, we would never read anything out if we don't add
          // the option to increment the address when readout hasn't been begun but the read/write
          // addresses are both zero
          // it is not possible to enter the TRANSFER state with an empty buffer, so we know if both are zero,
          // then the buffer must be full
          if ((read_addr != write_addr) || (!readout_begun)) begin
            readout_begun <= 1'b1;
            read_addr <= read_addr + 1'b1;
            data_out_valid <= {data_out_valid[2:0], 1'b1};
            if (read_addr + 1'b1 == write_addr) begin
              data_out_last <= {data_out_last[2:0], 1'b1};
            end
          end else begin
            // no more samples are read out
            data_out_valid <= {data_out_valid[2:0], 1'b0};
            data_out_last <= {data_out_last[2:0], 1'b0};
          end
          data_out_d <= {data_out_d[2:0], buffer[read_addr]};
          read_addr_d <= {read_addr_d[1:0], read_addr};
        end
      end
    endcase
  end
end

endmodule
