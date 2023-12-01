import sim_util_pkg::*;

`timescale 1ns / 1ps
module timetagging_discriminating_buffer_test ();

sim_util_pkg::generic #(int) util;

logic clk = 0;
localparam CLK_RATE_HZ = 100_000_000;
always #(0.5s/CLK_RATE_HZ) clk = ~clk;

logic reset;

int error_count = 0;

localparam int N_CHANNELS = 8;
localparam int TSTAMP_BUFFER_DEPTH = 128;
localparam int DATA_BUFFER_DEPTH = 1024;
localparam int AXI_MM_WIDTH = 128;
localparam int PARALLEL_SAMPLES = 1;
localparam int SAMPLE_WIDTH = 16;
localparam int APPROX_CLOCK_WIDTH = 48;

// derived parameters
localparam int SAMPLE_INDEX_WIDTH = $clog2(DATA_BUFFER_DEPTH*N_CHANNELS);
localparam int TIMESTAMP_WIDTH = SAMPLE_WIDTH * ((SAMPLE_INDEX_WIDTH + APPROX_CLOCK_WIDTH + (SAMPLE_WIDTH - 1)) / SAMPLE_WIDTH);

localparam int DMA_WORD_PARSE_WIDTH = util.max(2*TIMESTAMP_WIDTH, 2*PARALLEL_SAMPLES*SAMPLE_WIDTH);

Axis_Parallel_If #(.DWIDTH(PARALLEL_SAMPLES*SAMPLE_WIDTH), .PARALLEL_CHANNELS(N_CHANNELS)) data_in ();
Axis_If #(.DWIDTH(AXI_MM_WIDTH)) data_out ();
Axis_If #(.DWIDTH(2+$clog2($clog2(N_CHANNELS)+1))) buffer_config_in ();
Axis_If #(.DWIDTH(N_CHANNELS*SAMPLE_WIDTH*2)) discriminator_config_in();

logic start, stop;
logic [$clog2($clog2(N_CHANNELS)+1)-1:0] banking_mode;
logic [N_CHANNELS-1:0][SAMPLE_WIDTH-1:0] threshold_high, threshold_low;

always_comb begin
  for (int i = 0; i < N_CHANNELS; i++) begin
    discriminator_config_in.data[2*SAMPLE_WIDTH*i+:2*SAMPLE_WIDTH] = {threshold_high[i], threshold_low[i]};
  end
end

assign buffer_config_in.data = {banking_mode, start, stop};

timetagging_discriminating_buffer #(
  .N_CHANNELS(N_CHANNELS),
  .TSTAMP_BUFFER_DEPTH(TSTAMP_BUFFER_DEPTH),
  .DATA_BUFFER_DEPTH(DATA_BUFFER_DEPTH),
  .AXI_MM_WIDTH(AXI_MM_WIDTH),
  .PARALLEL_SAMPLES(PARALLEL_SAMPLES),
  .SAMPLE_WIDTH(SAMPLE_WIDTH),
  .APPROX_CLOCK_WIDTH(APPROX_CLOCK_WIDTH)
) dut_i (
  .clk,
  .reset,
  .timestamp_width(),
  .data_in,
  .data_out,
  .discriminator_config_in,
  .buffer_cfg_in
);

logic update_input_data;
logic [N_CHANNELS-1:0][SAMPLE_WIDTH-1:0] data_range_low, data_range_high;
logic [PARALLEL_SAMPLES*SAMPLE_WIDTH-1:0] data_sent [N_CHANNELS][$];
logic [AXI_MM_WIDTH-1:0] data_received [$];

// send data to DUT and save sent/received data
always @(posedge clk) begin
  for (int i = 0; i < N_CHANNELS; i++) begin
    if (reset) begin
      data_in.data[i] <= '0;
    end else begin
      if (data_in.ok[i]) begin
        // send new data
        for (int j = 0; j < PARALLEL_SAMPLES; j++) begin
          data_in.data[i][j*SAMPLE_WIDTH+:SAMPLE_WIDTH] <= $urandom_range({SAMPLE_WIDTH{1'b1}});
        end
        // save data that was sent
        data_sent[i].push_front(data_in.data[i]);
      end else if (update_input_data) begin
        // send new data
        for (int j = 0; j < PARALLEL_SAMPLES; j++) begin
          data_in.data[i][j*SAMPLE_WIDTH+:SAMPLE_WIDTH] <= $urandom_range({SAMPLE_WIDTH{1'b1}});
        end
      end
    end
  end
  // save all data in the same buffer and postprocess it later
  if (data_out.ok) begin
    data_received.push_front(data_out.data);
  end
end

task check_results(
  input int banking_mode,
  input logic [N_CHANNELS-1:0][SAMPLE_WIDTH-1:0] threshold_high,
  input logic [N_CHANNELS-1:0][SAMPLE_WIDTH-1:0] threshold_low
);
  // checks that:
  // - all data received belongs to the proper channels
  // - timestamps line up with when samples were sent
  // - all inputs > threshold_high were saved and all inputs < threshold_low
  //    were not
  // - all samples < threshold_high that were saved arrived in sequence after
  //    a sample > threshold_high

  // data structures for organizing DMA output
  logic [AXI_MM_WIDTH-1:0] dma_word;
  int dma_word_leftover_bits;
  int current_channel, words_remaining;
  int parsed_bank_count;
  int word_width;
  bit need_channel_id, need_word_count;
  enum {TIMESTAMP, DATA} parse_mode;
  logic [TIMESTAMP_WIDTH-1:0] timestamps [N_CHANNELS][$];
  logic [SAMPLE_WIDTH*PARALLEL_SAMPLES-1:0] samples [N_CHANNELS][$];

  // first report the size of the buffers
  for (int i = 0; i < N_CHANNELS; i++) begin
    $display("data_sent[%0d].size() = %0d", i, data_sent[i].size());
  end
  $display("data_received.size() = %0d", data_received.size());

  // organize DMA output into data structures for easier analysis
  dma_word_leftover_bits = 0;
  word_width = TIMESTAMP_WIDTH;
  parse_mode = TIMESTAMP;
  dma_word = '0;
  need_channel_id = 1'b1;
  need_word_count = 1'b1;
  parsed_bank_count = 0;
  while (!done_parsing) begin
    // combine remaining bits with new word
    dma_word = (data_received.pop_back() << dma_word_leftover_bits) | dma_word;
    dma_word_leftover_bits = dma_word_leftover_bits + AXI_MM_WIDTH;
    while (dma_word_leftover_bits >= word_width) begin
      // data is always organized as so:
      // [channel_id, tstamp_count, tstamp_0, ..., channel_id, tstamp_count, ...]
      // so first update the channel ID, then update the number of timestamps
      // to add to that channel, then finally collect those timestamps
      if (need_channel_id) begin
        // mask lower bits depending on whether we're parsing timestamps or data
        current_channel = dma_word & ((1'b1 << word_width) - 1);
        need_channel_id = 1'b0;
        need_word_count = 1'b1;
      end else begin
        if (need_word_count) begin
          // mask lower bits depending on whether we're parsing timestamps or data
          words_remaining = dma_word & ((1'b1 << word_width) - 1);
          need_word_count = 1'b0;
        end else begin
          unique case (parse_mode)
            TIMESTAMP: begin
              // mask lower bits based on timestamp width
              timestamps[current_channel].push_front(dma_word & ((1'b1 << word_width) - 1));
            end
            DATA: begin
              // mask lower bits based on data width
              samples[current_channel].push_front(dma_word & ((1'b1 << word_width) - 1));
            end
          words_remaining = words_remaining - 1;
        end
        // check if we have read all the timestamps or data
        if (words_remaining == 0) begin
          need_channel_id = 1'b1;
          parsed_bank_count = parsed_bank_count + 1;
        end
      end
      // check if we're done with all channels
      if (parsed_bank_count == N_CHANNELS) begin
        // if we're done with all channels, but we were in the timestamp mode,
        // then shift to data mode
        if (parse_mode == TIMESTAMP) begin
          word_width = SAMPLE_WIDTH*PARALLEL_SAMPLES;
          parse_mode = DATA;
        end else begin
          done = 1;
        end
        // reset DMA word, the rest of the word is garbage; the data
        // information will come on the next word
        dma_word = '0;
        dma_word_leftover_bits = 0;
        parsed_bank_count = 0;
      end else begin
        dma_word = dma_word >> word_width;
        dma_word_leftover_bits = dma_word_leftover_bits - word_width;
      end
    end
  end

  // report the number of timestamps and samples for each channel
  for (int i = 0; i < N_CHANNELS; i++) begin
    $display("timestamps[%0d].size() = %0d", i, timestamps[i].size());
    $display("samples[%0d].size() = %0d", i, samples[i].size());
  end

endtask



//    current_channel = data_received.pop_back();
//    // check if current_channel is valid for banking mode
//    if (current_channel >= (1'b1 << banking_mode)) begin
//      $warning(
//        "invalid channel id (%d) for current banking mode (%d)",
//        current_channel,
//        banking_mode
//      );
//      error_count = error_count + 1;
//    end
//    n_samples = data_received.pop_back();
//    $display(
//      "processing new bank with %0d samples from channel %0d",
//      n_samples,
//      current_channel
//    );
//    for (int i = 0; i < n_samples; i++) begin
//      if (data_sent[current_channel][$] != data_received[$]) begin
//        $display(
//          "data mismatch error (channel = %0d, sample = %0d, received %x, sent %x)",
//          current_channel,
//          i,
//          data_received[$],
//          data_sent[current_channel][$]
//        );
//        error_count = error_count + 1;
//      end
//      data_sent[current_channel].pop_back();
//      data_received.pop_back();
//    end
//  end
//  for (int i = 0; i < (1 << banking_mode); i++) begin
//    // make sure there are no remaining samples in data_sent queues
//    // corresponding to channels which are enabled as per banking_mode
//    // caveat: if one of the channels filled up, then it's okay for there to
//    // be missing samples in the other channels
//    if (data_sent[i].size() > 0) begin
//      $warning("leftover samples in data_sent[%0d]: %0d", i, data_sent[i].size());
//      error_count = error_count + 1;
//    end
//    while (data_sent[i].size() > 0) data_sent[i].pop_back();
//  end
//  for (int i = (1 << banking_mode); i < N_CHANNELS; i++) begin
//    // flush out any remaining samples in data_sent queue
//    $display("removing %0d samples from data_sent[%0d]", data_sent[i].size(), i);
//    while (data_sent[i].size() > 0) data_sent[i].pop_back();
//  end
//endtask

task start_acq_with_banking_mode(input int mode);
  start <= 1'b1;
  banking_mode <= mode;
  buffer_config_in.valid <= 1'b1;
  @(posedge clk);
  buffer_config_in.valid <= 1'b0;
  start <= 1'b0;
endtask

task stop_acq();
  stop <= 1'b1;
  start <= 1'b0;
  buffer_config_in.valid <= 1'b1;
  @(posedge clk);
  buffer_config_in.valid <= 1'b0;
  start <= 1'b0;
  stop <= 1'b0;
endtask

initial begin
  reset <= 1'b1;
  start <= 1'b0;
  stop <= 1'b0;
  banking_mode <= '0; // only enable channel 0
  data_in.valid <= '0;
  repeat (100) @(posedge clk);
  reset <= 1'b0;
  repeat (50) @(posedge clk);

  for (int in_valid_rand = 0; in_valid_rand < 2; in_valid_rand++) begin
    for (int bank_mode = 0; bank_mode < 4; bank_mode++) begin
      for (int amplitude_mode = 0; amplitude_mode < 4; amplitude_mode++) begin
        repeat (10) @(posedge clk);
        unique case (amplitude_mode)
          0: begin
            // save everything
            for (int i = 0; i < N_CHANNELS; i++) begin
              data_range_low[i] <= 16'h0000;
              data_range_high[i] <= 16'h04ff;
              threshold_low[i] <= 16'h03c0;
              threshold_high[i] <= 16'h0400;
            end
          end
          1: begin
            // send stuff straddling the threshold with strong hysteresis
            for (int i = 0; i < N_CHANNELS; i++) begin
              data_range_low[i] <= 16'h00ff;
              data_range_high[i] <= 16'h04ff;
              threshold_low[i] <= 16'h01c0;
              threshold_high[i] <= 16'h0400;
            end
          end
          2: begin
            // send stuff below the threshold
            for (int i = 0; i < N_CHANNELS; i++) begin
              data_range_low[i] <= 16'h0000;
              data_range_high[i] <= 16'h01ff;
              threshold_low[i] <= 16'h0200;
              threshold_high[i] <= 16'h0200;
            end
          end
          3: begin
            // send stuff straddling the threshold with weak hysteresis
            for (int i = 0; i < N_CHANNELS; i++) begin
              data_range_low[i] <= 16'h0000;
              data_range_high[i] <= 16'h04ff;
              threshold_low[i] <= 16'h03c0;
              threshold_high[i] <= 16'h0400;
            end
          end
        endcase
        // write the new threshold to the discriminator and update the input data
        discriminator_config_in.valid <= 1'b1;
        update_input_data <= 1'b1;
        @(posedge clk);
        discriminator_config_in.valid <= 1'b0;
        update_input_data <= 1'b0;

        repeat (10) @(posedge clk);
        start_acq_with_banking_mode(bank_mode);

        data_in.send_samples(clk, $urandom_range(50,500), in_valid_rand & 1'b1, 1'b1);
        repeat (10) @(posedge clk);
        stop_acq();
        data_out.do_readout(clk, 1'b1, 100000);
        $display("######################################################");
        $display("# checking results amplitude_mode = %d", amplitude_mode);
        $display("# banking mode                    = %d", bank_mode);
        $display("# samples sent with rand_valid    = %d", in_valid_rand);
        $display("######################################################");
        check_results(bank_mode, threshold_low, threshold_high);
      end
    end
  end

  $display("#################################################");
  if (error_count == 0) begin
    $display("# finished with zero errors");
  end else begin
    $error("# finished with %0d errors", error_count);
    $display("#################################################");
  end
  $display("#################################################");
  $finish;
end

endmodule
