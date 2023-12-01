import sim_util_pkg::*;

`timescale 1ns / 1ps
module axis_width_converter_test();

logic reset;
logic clk = 0;
localparam CLK_RATE_HZ = 100_000_000;
always #(0.5s/CLK_RATE_HZ) clk = ~clk;

int error_count = 0;

localparam int DWIDTH_DOWN_IN = 256;
localparam int DWIDTH_UP_IN = 16;
localparam int DWIDTH_COMB_IN = 24;
localparam int DOWN = 4;
localparam int UP = 8;
localparam int COMB_UP = 4;
localparam int COMB_DOWN = 3;

sim_util_pkg::sample_discriminator_util util;
localparam int DWIDTH = util.max(util.max(util.max(DWIDTH_DOWN_IN, DWIDTH_UP_IN*UP), (DWIDTH_COMB_IN*COMB_UP)/COMB_DOWN), DWIDTH_COMB_IN);

Axis_If #(.DWIDTH(DWIDTH_DOWN_IN)) downsizer_in ();
Axis_If #(.DWIDTH(DWIDTH_DOWN_IN/DOWN)) downsizer_out ();
Axis_If #(.DWIDTH(DWIDTH_UP_IN)) upsizer_in ();
Axis_If #(.DWIDTH(DWIDTH_UP_IN*UP)) upsizer_out ();
Axis_If #(.DWIDTH(DWIDTH_COMB_IN)) comb_in ();
Axis_If #(.DWIDTH((DWIDTH_COMB_IN*COMB_UP)/COMB_DOWN)) comb_out ();

axis_downsizer #(
  .DWIDTH(DWIDTH_DOWN_IN),
  .DOWN(DOWN)
) downsize_dut_i (
  .clk,
  .reset,
  .data_in(downsizer_in),
  .data_out(downsizer_out)
);

axis_upsizer #(
  .DWIDTH(DWIDTH_UP_IN),
  .UP(UP)
) upsize_dut_i (
  .clk,
  .reset,
  .data_in(upsizer_in),
  .data_out(upsizer_out)
);

axis_width_converter #(
  .DWIDTH_IN(DWIDTH_COMB_IN),
  .UP(COMB_UP),
  .DOWN(COMB_DOWN)
) comb_dut_i (
  .clk,
  .reset,
  .data_in(comb_in),
  .data_out(comb_out)
);

logic [DWIDTH-1:0] sent [3][$];
logic [DWIDTH-1:0] received [3][$];
int last_sent [3][$]; // size of sent whenever last is present
int last_received [3][$]; // size of received whenever last is present

logic [1:0][2:0][DWIDTH-1:0] data;
assign downsizer_in.data = data[0][0];
assign upsizer_in.data = data[0][1];
assign comb_in.data = data[0][2];
assign data[1][0] = downsizer_out.data;
assign data[1][1] = upsizer_out.data;
assign data[1][2] = comb_out.data;

logic [1:0][2:0] ok;
assign ok[0][0] = downsizer_in.ok;
assign ok[0][1] = upsizer_in.ok;
assign ok[0][2] = comb_in.ok;
assign ok[1][0] = downsizer_out.ok;
assign ok[1][1] = upsizer_out.ok;
assign ok[1][2] = comb_out.ok;

logic [2:0] out_ready;
assign downsizer_out.ready = out_ready[0];
assign upsizer_out.ready = out_ready[1];
assign comb_out.ready = out_ready[2];

logic [2:0] in_valid;
assign downsizer_in.valid = in_valid[0];
assign upsizer_in.valid = in_valid[1];
assign comb_in.valid = in_valid[2];

logic [1:0][2:0] last;
assign downsizer_in.last = last[0][0];
assign upsizer_in.last = last[0][1];
assign comb_in.last = last[0][2];
assign last[1][0] = downsizer_out.last;
assign last[1][1] = upsizer_out.last;
assign last[1][2] = comb_out.last;

localparam [1:0][2:0][31:0] NUM_WORDS = '{
  '{COMB_UP, UP, 1},      // output words
  '{COMB_DOWN, 1, DOWN}   // input words
};

localparam [2:0][31:0] WORD_SIZE = '{
  DWIDTH_COMB_IN/COMB_DOWN, // both
  DWIDTH_UP_IN,             // upsizer
  DWIDTH_DOWN_IN/DOWN       // downsizer
};

localparam MAX_WORD_SIZE = util.max(util.max(WORD_SIZE[0],WORD_SIZE[1]),WORD_SIZE[2]);
logic [MAX_WORD_SIZE-1:0] sent_word, received_word;

// update data and track sent/received samples
always_ff @(posedge clk) begin
  if (reset) begin
    data[1] <= '0;
  end else begin
    for (int i = 0; i < 3; i++) begin
      // inputs
      if (ok[0][i]) begin
        for (int j = 0; j < DWIDTH/8; j++) begin
          data[0][i][j*8+:8] <= $urandom_range(0,8'hff);
        end
        // save data that was sent, split up into individual "words"
        for (int j = 0; j < NUM_WORDS[0][i]; j++) begin
          for (int k = 0; k < WORD_SIZE[i]; k++) begin
            sent_word[k] = data[0][i][j*WORD_SIZE[i]+k];
          end
          sent[i].push_front(sent_word & ((1 << WORD_SIZE[i]) - 1));
        end
        if (last[0][i]) begin
          last_sent[i].push_front(sent[i].size());
        end
      end
      // outputs
      if (ok[1][i]) begin
        // save data that was received, split up into individual "words"
        for (int j = 0; j < NUM_WORDS[1][i]; j++) begin
          for (int k = 0; k < WORD_SIZE[i]; k++) begin
            received_word[k] = data[1][i][j*WORD_SIZE[i]+k];
          end
          received[i].push_front(received_word & ((1 << WORD_SIZE[i]) - 1));
        end
        if (last[1][i]) begin
          last_received[i].push_front(received[i].size());
        end
      end
    end
  end
end

logic [2:0][1:0] readout_mode; // 0 for always 0, 1 for always 1, 2-3 for randomly toggling output ready signal

always_ff @(posedge clk) begin
  if (reset) begin
    out_ready <= '0;
  end else begin
    for (int i = 0; i < 3; i++) begin
      unique case (readout_mode[i])
        0: begin
          out_ready[i] <= '0;
        end
        1: begin
          out_ready[i] <= 1'b1;
        end
        2: begin
          out_ready[i] <= $urandom() & 1'b1;
        end
      endcase
    end
  end
end

task check_dut(input int dut_select);
  unique case (dut_select)
    0: begin
      $display("checking downsizer");
    end
    1: begin
      $display("checking upsizer");
    end
    2: begin
      $display("checking combination up:down");
    end
  endcase
  $display("sent[%0d].size() = %0d", dut_select, sent[dut_select].size());
  $display("received[%0d].size() = %0d", dut_select, received[dut_select].size());
  $display("last_sent[%0d].size() = %0d", dut_select, last_sent[dut_select].size());
  $display("last_received[%0d].size() = %0d", dut_select, last_received[dut_select].size());
  while (last_sent[dut_select].size() > 0 && last_received[dut_select].size() > 0) begin
    $display("last_sent, last_received: %0d, %0d", last_sent[dut_select][$], last_received[dut_select][$]);
    last_sent[dut_select].pop_back();
    last_received[dut_select].pop_back();
  end
  // check we got the right amount of data
  if (received[dut_select].size() < sent[dut_select].size()) begin
    $warning("mismatch in number of received/sent words, received fewer words than sent (received %d, sent %d)", received[dut_select].size(), sent[dut_select].size());
    error_count = error_count + 1;
  end
  unique case (dut_select)
    0: begin
      if (received[dut_select].size() > sent[dut_select].size()) begin
        $warning("mismatch in number of received/sent words, received more words than sent (received %d, sent %d)", received[dut_select].size(), sent[dut_select].size());
        error_count = error_count + 1;
      end
    end
    1: begin
      if (received[dut_select].size() - sent[dut_select].size() >= UP) begin
        $warning("mismatch in number of received/sent words, received more than UP words more than sent (received %d, sent %d)", received[dut_select].size(), sent[dut_select].size());
        error_count = error_count + 1;
      end
    end
    2: begin
      if (received[dut_select].size() - sent[dut_select].size() >= COMB_UP*COMB_DOWN) begin
        $warning("mismatch in number of received/sent words, received more than COMB_UP*COMB_DOWN words more than sent (received %d, sent %d)", received[dut_select].size(), sent[dut_select].size());
        error_count = error_count + 1;
      end
    end
  endcase
  // remove invalid subwords if an incomplete word was sent at the end
  if (dut_select > 0) begin
    // do nothing for downsizer; it cannot have invalid subwords
    while (received[dut_select].size() > sent[dut_select].size()) begin
      received[dut_select].pop_front();
    end
  end

  // check data
  while (sent[dut_select].size() > 0 && received[dut_select].size() > 0) begin
    if (sent[dut_select][$] != received[dut_select][$]) begin
      error_count = error_count + 1;
      $warning("data mismatch error (received %x, sent %x)", received[dut_select][$], sent[dut_select][$]);
    end
    sent[dut_select].pop_back();
    received[dut_select].pop_back();
  end
endtask

// actually do the test
initial begin
  reset <= 1'b1;

  // reset input valid
  in_valid <= '0;
  // reset input last
  last[0] <= '0;
  // set readout mode to off for all DUTs(readout disabled)
  readout_mode <= '0;
  // reset input data
  data[0] <= '0;

  repeat (50) @(posedge clk);
  reset <= 1'b0;
  repeat (50) @(posedge clk);

  // do test
  for (int i = 0; i < 3; i++) begin
    $display("#################################################");
    unique case (i)
      0: $display("# testing downsizer                             #");
      1: $display("# testing upsizer                               #");
      2: $display("# testing combined upsizer/downsizer            #");
    endcase
    $display("#################################################");
    repeat (50) begin
      for (int j = 1; j <= 2; j++) begin
        // cycle between continuously-high and randomly toggling ready signal on output interface 
        readout_mode[i] <= j;
        unique case (i)
          0: begin
            // send samples with random arrivals
            downsizer_in.send_samples(clk, $urandom_range(3,100), 1'b1, 1'b1);
            // send samples all at once
            downsizer_in.send_samples(clk, $urandom_range(3,100), 1'b0, 1'b1);
            // send samples with random arrivals
            downsizer_in.send_samples(clk, $urandom_range(3,100), 1'b1, 1'b1);
          end
          1: begin
            upsizer_in.send_samples(clk, $urandom_range(3,100), 1'b1, 1'b1);
            upsizer_in.send_samples(clk, $urandom_range(3,100), 1'b0, 1'b1);
            upsizer_in.send_samples(clk, $urandom_range(3,100), 1'b1, 1'b1);
          end
          2: begin
            comb_in.send_samples(clk, $urandom_range(3,100), 1'b1, 1'b1);
            comb_in.send_samples(clk, $urandom_range(3,100), 1'b0, 1'b1);
            comb_in.send_samples(clk, $urandom_range(3,100), 1'b1, 1'b1);
          end
        endcase
        last[0][i] <= 1'b1;
        in_valid[i] <= 1'b1;
        // wait until last is actually registered by the DUT before deasserting it
        do begin @(posedge clk); end while (!ok[0][i]);
        last[0][i] <= 1'b0;
        in_valid[i] <= 1'b0;

        // read out everything, waiting until last signal on DUT output
        do begin @(posedge clk); end while (!(last[1][i] && ok[1][i]));
        // check the output data matches the input
        check_dut(i);
        repeat (100) @(posedge clk);
      end
    end
    // disable readout of DUT when finished
    readout_mode[i] <= '0;
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
