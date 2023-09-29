`timescale 1ns / 1ps
module noise_event_tracker_test();

logic clk = 0;
localparam CLK_RATE_HZ = 100_000_000;
always #(0.5s/CLK_RATE_HZ) clk = ~clk;

logic reset;
logic start, stop, mode;
logic [15:0] threshold_high, threshold_low;

Axis_If #(.DWIDTH(16)) data_in_00_if();
Axis_If #(.DWIDTH(16)) data_in_02_if();
Axis_If #(.DWIDTH(128)) data_out_if();
Axis_If #(.DWIDTH(35)) config_in_if();

assign config_in_if.data = {mode, start, stop, threshold_high, threshold_low};

localparam int DEC_RATE = 100;

noise_event_tracker #(
  .BUFFER_DEPTH(32), // 32x128 = 128 samples from each channel can be stored
  .SAMPLE_WIDTH(16),
  .AXI_MM_WIDTH(128),
  .DECIMATION_BELOW_THRESH(DEC_RATE) // don't decimate for now
) dut_i (
  .clk,
  .reset,
  .data_out(data_out_if),
  .data_in_00(data_in_00_if),
  .data_in_02(data_in_02_if),
  .config_in(config_in_if)
);

logic [15:0] data_sent_00 [$];
logic [15:0] data_sent_02 [$];

int ch_00_rand_range_low, ch_00_rand_range_high;
int ch_02_rand_range_low, ch_02_rand_range_high;

int ch_00_dec_count, ch_02_dec_count;
bit ch_00_noise_state, ch_02_noise_state;
int word_index;
int words_stored;

always @(posedge clk) begin
  if (reset) begin
    data_in_00_if.data <= '0;
    data_in_02_if.data <= '0;
    word_index = 0;
    words_stored = 0;
  end else begin
    if (data_in_00_if.valid && data_in_00_if.ready) begin
      if (dut_i.mode == 0) begin
        data_sent_00.push_front({data_in_00_if.data[15:2], 1'b0, 1'b0});
        word_index = word_index + 1;
      end else begin
        if (data_in_00_if.data > dut_i.threshold_high) begin
          ch_00_noise_state <= 1'b1;
          data_sent_00.push_front({data_in_00_if.data[15:2], 1'b0, 1'b0});
          word_index = word_index + 1;
          ch_00_dec_count <= '0;
        end else if (ch_00_noise_state == 1 && data_in_00_if.data >= dut_i.threshold_low) begin
          data_sent_00.push_front({data_in_00_if.data[15:2], 1'b0, 1'b0});
          word_index = word_index + 1;
          ch_00_dec_count <= '0;
        end else if (ch_00_noise_state == 1 && data_in_00_if.data < dut_i.threshold_low) begin
          ch_00_noise_state <= 1'b0;
          ch_00_dec_count <= ch_00_dec_count + 1'b1;
        end else if (ch_00_noise_state == 0) begin
          if (ch_00_dec_count == DEC_RATE - 1) begin
            data_sent_00.push_front({data_in_00_if.data[15:2], 1'b0, 1'b0});
            word_index = word_index + 1;
            ch_00_dec_count <= '0;
          end else begin
            ch_00_dec_count <= ch_00_dec_count + 1'b1;
          end
        end
      end
      data_in_00_if.data <= $urandom_range(ch_00_rand_range_low,ch_00_rand_range_high);
    end
    if (data_in_02_if.valid && data_in_02_if.ready) begin
      if (dut_i.mode == 0) begin
        data_sent_02.push_front({data_in_02_if.data[15:2], 1'b0, 1'b0});
        word_index = word_index + 1;
      end else begin
        if (data_in_02_if.data > dut_i.threshold_high) begin
          ch_02_noise_state <= 1'b1;
          data_sent_02.push_front({data_in_02_if.data[15:2], 1'b0, 1'b0});
          word_index = word_index + 1;
          ch_02_dec_count <= '0;
        end else if (ch_02_noise_state == 1 && data_in_02_if.data >= dut_i.threshold_low) begin
          data_sent_02.push_front({data_in_02_if.data[15:2], 1'b0, 1'b0});
          word_index = word_index + 1;
        end else if (ch_02_noise_state == 1 && data_in_02_if.data < dut_i.threshold_low) begin
          ch_02_noise_state <= 1'b0;
          ch_02_dec_count <= ch_02_dec_count + 1'b1;
        end else if (ch_02_noise_state == 0) begin
          if (ch_02_dec_count == DEC_RATE - 1) begin
            data_sent_02.push_front({data_in_02_if.data[15:2], 1'b0, 1'b0});
            word_index = word_index + 1;
            ch_02_dec_count <= '0;
          end else begin
            ch_02_dec_count <= ch_02_dec_count + 1'b1;
          end
        end
      end
      data_in_02_if.data <= $urandom_range(ch_02_rand_range_low,ch_02_rand_range_high);
    end
    if (word_index >= 8) begin
      word_index = word_index % 8;
      words_stored = words_stored + 1;
    end
  end
end

int error_count_00;
int error_count_02;
int words_checked;
logic [15:0] data_received_00 [$];
logic [15:0] data_received_02 [$];
// check output
always @(posedge clk) begin
  if (reset) begin
    words_checked = 0;
    error_count_00 = 0;
    error_count_02 = 0;
  end else begin
    if (data_out_if.valid && data_out_if.ready) begin
      words_checked = words_checked + 1;
      for (int i = 0; i < 8; i++) begin
        if (data_out_if.data[i*16+1]) begin
          // channel 02
          data_received_02.push_front(data_out_if.data[i*16+:16]);
        end else begin
          // channel 00
          data_received_00.push_front(data_out_if.data[i*16+:16]);
        end
      end
    end
  end
end

task send_samples_separate(input int num_pairs);
  repeat (num_pairs) begin
    // only will ever get samples one at a time,
    // so it's okay to have valid high for only one cycle
    data_in_00_if.valid <= 1'b1;
    @(posedge clk);
    data_in_00_if.valid <= 1'b0;
    repeat (2) @(posedge clk);
    data_in_02_if.valid <= 1'b1;
    @(posedge clk);
    data_in_02_if.valid <= 1'b0;
    repeat (20) @(posedge clk);
  end
endtask

task send_samples_together(input int num_pairs);
  repeat (num_pairs) begin
    data_in_00_if.valid <= 1'b1;
    data_in_02_if.valid <= 1'b1;
    @(posedge clk);
    data_in_00_if.valid <= 1'b0;
    data_in_02_if.valid <= 1'b0;
    repeat (20) @(posedge clk);
  end
endtask

task do_readout();
  stop <= 1'b1;
  config_in_if.valid <= 1'b1;
  @(posedge clk);
  stop <= 1'b0;
  config_in_if.valid <= 1'b0;
  repeat (500) @(posedge clk);
  // read out
  data_out_if.ready <= 1'b1;
  repeat (10) @(posedge clk);
  data_out_if.ready <= 1'b0;
  repeat (100) @(posedge clk);
  data_out_if.ready <= 1'b1;
  repeat (1000) @(posedge clk);
endtask

task check_output();
  $info("word count (received: %d, sent: %d)", words_checked, words_stored);
  $info("ch00 sample count (received: %d, sent: %d)", data_received_00.size(), data_sent_00.size());
  $info("ch02 sample count (received: %d, sent: %d)", data_received_02.size(), data_sent_02.size());
  while (data_received_00.size() > 0 && data_sent_00.size() > 0) begin
    if ((data_received_00[$] & 16'hfffc) != (data_sent_00[$] & 16'hfffc)) begin
      $info("ch00 mismatch (got %x, expected %x)", data_received_00[$] & 16'hfffc, data_sent_00[$] & 16'hfffc);
      error_count_00 = error_count_00 + 1;
    end
    data_sent_00.pop_back();
    data_received_00.pop_back();
  end
  while (data_received_02.size() > 0 && data_sent_02.size() > 0) begin
    if ((data_received_02[$] & 16'hfffc) != (data_sent_02[$] & 16'hfffc)) begin
      $info("ch02 mismatch (got %x, expected %x)", data_received_02[$] & 16'hfffc, data_sent_02[$] & 16'hfffc);
      error_count_02 = error_count_02 + 1;
    end
    data_sent_02.pop_back();
    data_received_02.pop_back();
  end
  $info("error_count = (ch00: %d, ch02: %d)", error_count_00, error_count_02);
endtask

initial begin
  reset <= 1'b1;
  start <= 1'b0;
  stop <= 1'b0;
  mode <= 1'b0;
  config_in_if.valid <= 1'b0;
  data_in_00_if.valid <= 1'b0;
  data_in_02_if.valid <= 1'b0;
  data_out_if.ready <= 1'b0;
  ch_00_rand_range_low <= 0;
  ch_00_rand_range_high <= 1<<16;
  ch_02_rand_range_low <= 0;
  ch_02_rand_range_high <= 1<<16;
  repeat (500) @(posedge clk);
  reset <= 1'b0;
  repeat (100) @(posedge clk);

  ///////////////////////////////////////
  // first trial with mode = 0
  ///////////////////////////////////////
  start <= 1'b1;
  threshold_high <= '0;
  threshold_low <= '1;
  config_in_if.valid <= 1'b1;
  @(posedge clk);
  start <= 1'b0;
  config_in_if.valid <= 1'b0;
  repeat (100) @(posedge clk);
  // send some samples in
  // first, separate samples by a couple cycles
  send_samples_separate(50);
  // next, have samples arrive on the same cycle
  send_samples_together(54);
  // stop capture and read out
  do_readout();
  start <= 1'b1;
  threshold_high <= '0;
  threshold_low <= '1;
  config_in_if.valid <= 1'b1;
  @(posedge clk);
  start <= 1'b0;
  config_in_if.valid <= 1'b0;
  repeat (100) @(posedge clk);
  // send some samples in (this time with cycles arriving together first)
  send_samples_together(26);
  send_samples_separate(70);
  // stop capture and read out
  do_readout();
  // check everything
  $info("mode = 0 (no compression) test results:");
  check_output();

  ///////////////////////////////////////
  // second trial with mode = 1
  ///////////////////////////////////////
  start <= 1'b1;
  stop <= 1'b0;
  mode <= 1'b1;
  threshold_high <= 16'h0fff;
  threshold_low <= 16'h00ff;
  config_in_if.valid <= 1'b1;
  @(posedge clk);
  start <= 1'b0;
  config_in_if.valid <= 1'b0;
  repeat (100) @(posedge clk);
  // now generate some random signals with different power levels
  ch_00_rand_range_low <= 16'h01ff;
  ch_00_rand_range_high <= 1<<16;
  ch_02_rand_range_low <= 16'h01ff;
  ch_02_rand_range_high <= 1<<16;
  // send some samples in, all should be captured
  send_samples_together(16); // 40 altogether
  send_samples_separate(24);
  // decrease the high range below the high threshold, still should all be captured
  ch_00_rand_range_low <= 16'h01ff;
  ch_00_rand_range_high <= 16'h03ff;
  ch_02_rand_range_low <= 16'h01ff;
  ch_02_rand_range_high <= 16'h03ff;
  // send some samples in, all should be captured
  send_samples_separate(14); // 32 altogether
  send_samples_together(18);
  // decrease the high range below the low threshold, should start decimating
  ch_00_rand_range_low <= 16'h001f;
  ch_00_rand_range_high <= 16'h007f;
  ch_02_rand_range_low <= 16'h001f;
  ch_02_rand_range_high <= 16'h007f;
  send_samples_separate(1400); // 32 altogether
  send_samples_together(1800);
  // increase noise above high threshold
  ch_00_rand_range_low <= 16'h01ff;
  ch_00_rand_range_high <= 1<<16;
  ch_02_rand_range_low <= 16'h01ff;
  ch_02_rand_range_high <= 1<<16;
  // send some samples in, all should be captured
  send_samples_together(8); // 24 altogether
  send_samples_separate(16);
  // wrap up
  do_readout();
  // check everything
  $info("mode = 1 (compression) results:");
  check_output();

  $finish;
end


endmodule
