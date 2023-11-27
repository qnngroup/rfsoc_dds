`timescale 1ns / 1ps
module axis_width_converter_test();

logic reset;
logic clk = 0;
localparam CLK_RATE_HZ = 100_000_000;
always #(0.5s/CLK_RATE_HZ) clk = ~clk;

int error_count;

localparam int DWIDTH_DOWN_IN = 256;
localparam int DWIDTH_UP_IN = 16;
localparam int DWIDTH_COMB_IN = 192;
localparam int DOWN = 4;
localparam int UP = 8;
localparam int COMB_UP = 4;
localparam int COMB_DOWN = 3;

let max(a,b) = (a > b) ? a : b;
localparam int DWIDTH = max(max(max(DWIDTH_DOWN_IN, DWIDTH_UP_IN*UP), (DWIDTH_COMB_IN*COMB_UP)/COMB_DOWN), DWIDTH_COMB_IN);

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

logic [1:0][2:0] last;
assign last[0][0] = downsizer_in.last;
assign last[0][1] = upsizer_in.last;
assign last[0][2] = comb_in.last;
assign last[1][0] = downsizer_out.last;
assign last[1][1] = upsizer_out.last;
assign last[1][2] = comb_out.last;

localparam [1:0][2:0][31:0] NUM_WORDS = '{
  '{DOWN, 1, COMB_DOWN},
  '{1, UP, COMB_UP}
};

localparam [2:0][31:0] WORD_SIZE = '{
  DWIDTH_DOWN_IN/DOWN,      // downsizer
  DWIDTH_UP_IN,             // upsizer
  DWIDTH_COMB_IN/COMB_DOWN  // both
};

// update data and track sent/received samples
always_ff @(posedge clk) begin
  if (reset) begin
    data_in <= '0;
  end else begin
    for (int i = 0; i < 3; i++) begin
      // inputs
      if (ok[0][i]) begin
        for (int j = 0; j < DWIDTH/8; j++) begin
          data[0][i][j*8+:8] <= $urandom_range(0,8'hff);
        end
        // save data that was sent, split up into individual "words"
        for (int j = 0; j < NUM_WORDS[0][i]; j++) begin
          sent[i].push_front(data[0][i][j*WORD_SIZE[i]+:WORD_SIZE[i]]);
        end
        if (last[0][i]) begin
          last_sent[i].push_front(sent[i].size());
        end
      end
      // outputs
      if (ok[1][i]) begin
        // save data that was received, split up into individual "words"
        for (int j = 0; j < NUM_WORDS[1][i]; j++) begin
          received[i].push_front(data[1][i][j*WORD_SIZE[i]+:WORD_SIZE[i]]);
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
  // check downsizer
  while (last_sent[dut_select].size() > 0 && last_received[dut_select].size() > 0) begin
    $display("last_sent, last_received: %0d, %0d", last_sent[dut_select][$], last_received[dut_select][$]);
    last_sent[dut_select].pop_back();
    last_received[dut_select].pop_back();
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
  
  downsizer_in.valid <= '0;
  upsizer_in.valid <= '0;
  comb_in.valid <= '0;

  last[0] <= '0;
  readout_mode <= '0;

  repeat (50) @(posedge clk);
  reset <= 1'b0;
  repeat (50) @(posedge clk);
  for (int i = 0; i < 3; i++) begin
    $display("#################################################");
    unique case (i)
      0: $display("# testing downsizer                             #");
      1: $display("# testing upsizer                               #");
      2: $display("# testing combined upsizer/downsizer            #");
    endcase
    $display("#################################################");
    for (int j = 1; j <= 2; j++) begin
      readout_mode[i] <= j;
      unique case (i)
        0: begin
          downsizer_in.send_samples(clk, 5, 1'b1, 1'b0);
          downsizer_in.send_samples(clk, 8, 1'b0, 1'b0);
          downsizer_in.send_samples(clk, 7, 1'b1, 1'b0);
        end
        1: begin
          upsizer_in.send_samples(clk, 5, 1'b1, 1'b0);
          upsizer_in.send_samples(clk, 8, 1'b0, 1'b0);
          upsizer_in.send_samples(clk, 7, 1'b1, 1'b0);
        end
        2: begin
          comb_in.send_samples(clk, 5, 1'b1, 1'b0);
          comb_in.send_samples(clk, 8, 1'b0, 1'b0);
          comb_in.send_samples(clk, 7, 1'b1, 1'b0);
        end
      last[0][i] <= 1'b1;
      downsizer_in.valid <= 1'b1;
      do begin @(posedge clk); end while (!downsizer_in.ok);
      last[0][0] <= 1'b0;
      downsizer_in.valid <= 1'b0;
      // check downsizer
      do begin @(posedge clk); end while (!(downsizer_out.last && downsizer_out.ok));
      check_downsizer();
      repeat (100) @(posedge clk);
    end
    readout_mode[i] <= '0;
  end
  repeat (10) @(posedge clk);
  $display("#################################################");
  $display("# finished testing downsizer, testing upsizer   #");
  $display("#################################################");
  // check upsizer
  for (int i = 1; i <= 2; i++) begin
    upsizer_readout_mode <= i;
    upsizer_in.send_samples(clk, 27, 1'b1, 1'b0);
    upsizer_in.send_samples(clk, 19, 1'b0, 1'b0);
    upsizer_in.send_samples(clk, 17, 1'b1, 1'b0);
    upsizer_in.last <= 1'b1;
    upsizer_in.valid <= 1'b1;
    do begin @(posedge clk); end while (!upsizer_in.ok);
    upsizer_in.last <= 1'b0;
    upsizer_in.valid <= 1'b0;
    // check upsizer
    do begin @(posedge clk); end while (!(upsizer_out.last && upsizer_out.ok));
    check_upsizer();
    repeat (100) @(posedge clk);
  end
  upsizer_readout_mode <= 2'b00;
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
