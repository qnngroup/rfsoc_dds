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

noise_event_tracker #(
  .BUFFER_DEPTH(32), // 32x128 = 128 samples from each channel can be stored
  .SAMPLE_WIDTH(16),
  .AXI_MM_WIDTH(128),
  .DECIMATION_BELOW_THRESH(1) // don't decimate for now
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
      data_sent_00.push_front({data_in_00_if.data[15:2], 1'b0, 1'b0});
      data_in_00_if.data <= $urandom_range(0,1<<16);
      word_index = word_index + 1;
    end
    if (data_in_02_if.valid && data_in_02_if.ready) begin
      data_sent_02.push_front({data_in_02_if.data[15:2], 1'b1, 1'b0});
      data_in_02_if.data <= $urandom_range(0,1<<16);
      word_index = word_index + 1;
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

initial begin
  reset <= 1'b1;
  start <= 1'b0;
  stop <= 1'b0;
  mode <= 1'b0;
  config_in_if.valid <= 1'b0;
  data_in_00_if.valid <= 1'b0;
  data_in_02_if.valid <= 1'b0;
  data_out_if.ready <= 1'b0;
  repeat (500) @(posedge clk);
  reset <= 1'b0;
  repeat (100) @(posedge clk);

  ///////////////////////////////////////
  // first trial
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
  repeat (50) begin
    // first, separate samples by a couple cycles
    data_in_00_if.valid <= 1'b1; // only will ever get samples one at a time
    @(posedge clk);
    data_in_00_if.valid <= 1'b0;
    repeat (2) @(posedge clk);
    data_in_02_if.valid <= 1'b1;
    @(posedge clk);
    data_in_02_if.valid <= 1'b0;
    repeat (20) @(posedge clk);
  end
  repeat (50) begin
    // next, have samples arrive on the same cycle
    repeat (100) @(posedge clk);
    data_in_00_if.valid <= 1'b1;
    data_in_02_if.valid <= 1'b1;
    @(posedge clk);
    data_in_00_if.valid <= 1'b0;
    data_in_02_if.valid <= 1'b0;
    repeat (20) @(posedge clk);
  end
  // stop capture and read out
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

  ///////////////////////////////////////
  // second trial
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
  repeat (70) begin
    // first, have samples arrive on the same cycle
    repeat (100) @(posedge clk);
    data_in_00_if.valid <= 1'b1;
    data_in_02_if.valid <= 1'b1;
    @(posedge clk);
    data_in_00_if.valid <= 1'b0;
    data_in_02_if.valid <= 1'b0;
    repeat (20) @(posedge clk);
  end
  repeat (20) begin
    // next, separate samples by a couple cycles
    data_in_00_if.valid <= 1'b1; // only will ever get samples one at a time
    @(posedge clk);
    data_in_00_if.valid <= 1'b0;
    repeat (2) @(posedge clk);
    data_in_02_if.valid <= 1'b1;
    @(posedge clk);
    data_in_02_if.valid <= 1'b0;
    repeat (20) @(posedge clk);
  end
  // stop capture and read out
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
  // check everything
  if (words_stored != words_checked) begin
    $warning("didn't receive same number of words as words sent (received: %d, sent: %d)",
      words_stored, words_checked);
  end
  if (data_sent_00.size() != data_received_00.size()) begin
    $warning("ch00 incorrect amount of samples received (received: %d, sent: %d)",
      data_received_00.size(), data_sent_00.size());
  end
  if (data_sent_02.size() != data_received_02.size()) begin
    $warning("ch02 incorrect amount of samples received (received: %d, sent: %d)",
      data_received_02.size(), data_sent_02.size());
  end
  while (data_received_00.size() > 0 && data_sent_00.size() > 0) begin
    if ((data_received_00[$] & 16'hfffc) != (data_sent_00[$] & 16'hfffc)) begin
      $warning("ch00 mismatch (got %x, expected %x)", data_received_00[$] & 16'hfffc, data_sent_00[$] & 16'hfffc);
      error_count_00 = error_count_00 + 1;
    end
    data_sent_00.pop_back();
    data_received_00.pop_back();
  end
  while (data_received_02.size() > 0 && data_sent_02.size() > 0) begin
    if ((data_received_02[$] & 16'hfffc) != (data_sent_02[$] & 16'hfffc)) begin
      $warning("ch02 mismatch (got %x, expected %x)", data_received_02[$] & 16'hfffc, data_sent_02[$] & 16'hfffc);
      error_count_02 = error_count_02 + 1;
    end
    data_sent_02.pop_back();
    data_received_02.pop_back();
  end
  $info("error_count = (ch00: %d, ch02: %d)", error_count_00, error_count_02);
  $finish;
end


endmodule
