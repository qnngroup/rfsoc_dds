import sim_util_pkg::*;

`timescale 1ns / 1ps
module timetagging_discriminating_buffer_test ();

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

Axis_Parallel_If #(.DWIDTH(PARALLEL_SAMPLES*SAMPLE_WIDTH), .PARALLEL_CHANNELS(N_CHANNELS)) data_in ();
Axis_If #(.DWIDTH(AXI_MM_WIDTH)) data_out ();
Axis_If #(.DWIDTH(2+$clog2($clog2(N_CHANNELS)+1))) buffer_config_in ();
Axis_If #(.DWIDTH(N_CHANNELS*SAMPLE_WIDTH*2)) discriminator_config_in();
logic [31:0] timestamp_width;

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
  .timestamp_width,
  .data_in,
  .data_out,
  .discriminator_config_in,
  .buffer_cfg_in,
);

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
      end
    end
  end
  // save all data in the same buffer and postprocess it later
  if (data_out.ok) begin
    data_received.push_front(data_out.data);
  end
end

task check_results(input int banking_mode, input bit missing_ok);
  logic [SAMPLE_WIDTH*PARALLEL_SAMPLES:0] temp_sample;
  int current_channel, n_samples;
  for (int i = 0; i < N_CHANNELS; i++) begin
    $display("data_sent[%0d].size() = %0d", i, data_sent[i].size());
  end
  $display("data_received.size() = %0d", data_received.size());
  while (data_received.size() > 0) begin
    current_channel = data_received.pop_back();
    n_samples = data_received.pop_back();
    $display("processing new bank with %0d samples from channel %0d", n_samples, current_channel);
    for (int i = 0; i < n_samples; i++) begin
      if (data_sent[current_channel][$] != data_received[$]) begin
        $display("data mismatch error (channel = %0d, sample = %0d, received %x, sent %x)", current_channel, i, data_received[$], data_sent[current_channel][$]);
        error_count = error_count + 1;
      end
      data_sent[current_channel].pop_back();
      data_received.pop_back();
    end
  end
  for (int i = 0; i < (1 << banking_mode); i++) begin
    // make sure there are no remaining samples in data_sent queues
    // corresponding to channels which are enabled as per banking_mode
    // caveat: if one of the channels filled up, then it's okay for there to
    // be missing samples in the other channels
    if ((data_sent[i].size() > 0) & (!missing_ok)) begin
      $warning("leftover samples in data_sent[%0d]: %0d", i, data_sent[i].size());
      error_count = error_count + 1;
    end
    while (data_sent[i].size() > 0) data_sent[i].pop_back();
  end
  for (int i = (1 << banking_mode); i < N_CHANNELS; i++) begin
    // flush out any remaining samples in data_sent queue
    $display("removing %0d samples from data_sent[%0d]", data_sent[i].size(), i);
    while (data_sent[i].size() > 0) data_sent[i].pop_back();
  end
endtask

task start_acq_with_banking_mode(input int mode);
  start <= 1'b1;
  banking_mode <= mode;
  buffer_config_inconfig_in.valid <= 1'b1;
  @(posedge clk);
  start <= 1'b0;
  config_in.valid <= 1'b0;
endtask

task stop_acq();
  stop <= 1'b1;
  start <= 1'b0;
  config_in.valid <= 1'b1;
  @(posedge clk);
  config_in.valid <= 1'b0;
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
        disc_config_in.valid <= 1'b1;
        @(posedge clk);
        disc_config_in.valid <= 1'b0;

        repeat (10) @(posedge clk);
        start_acq_with_banking_mode(bank_mode);

        data_in.send_samples(clk, $urandom_range(50,500), in_valid_rand & 1'b1, 1'b1);
        repeat (10) @(posedge clk);
        stop_acq();
        data_out.do_readout(clk, 1'b1, 100000);
        $display("######################################################");
        $display("# checking results n_samples   = %d", samples_to_send);
        $display("# banking mode                 = %d", bank_mode);
        $display("# samples sent with rand_valid = %d", in_valid_rand);
        $display("######################################################");
        // The second argument of check_results is if it's okay for there to
        // be missing samples that weren't stored.
        // When data_in.valid is randomly toggled on and off and enough samples
        // are sent to fill up all the banks, one of the banks will likely
        // fill up before the others are done, triggering a stop condition for
        // the other banks before they are full.
        // This results in "missing" samples that aren't saved
        check_results(bank_mode, (samp_count == 2) & (in_valid_rand == 1));
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


