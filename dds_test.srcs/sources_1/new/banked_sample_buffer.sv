// banked sample buffer
module banked_sample_buffer #(
  parameter int N_CHANNELS = 8, // number of ADC channels
  parameter int BUFFER_DEPTH = 8192 // maximum capacity across all channels
) (
  input wire clk, reset,
  Axis_If.Slave_Simple data_in, // all channels in parallel
  Axis_If.Master_Full data_out,
  Axis_If.Slave_Simple config_in // {banking_mode, start, stop}
);
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
  output logic full
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

assign full = write_addr == BUFFER_DEPTH - 1;

// state machine
always_ff @(posedge clk) begin
  if (reset) begin
    state <= IDLE;
  end else begin
    unique case (state)
      IDLE: if (start) state <= CAPTURE;
      CAPTURE: if (stop || (data_in.valid && full)) state <= PRETRANSFER;
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
      end
      CAPTURE: begin
        if (data_in.valid) begin
          buffer[write_addr] <= data_in.data;
          write_addr <= write_addr + 1'b1;
          buffer_has_data <= 1'b1;
        end
      end
      PRETRANSFER: begin
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
