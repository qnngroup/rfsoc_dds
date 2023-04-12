`timescale 1ns / 1ps

module sample_buffer_test ();

logic clk = 0;
localparam CLK_RATE_HZ = 100_000_000;
always #(0.5s/CLK_RATE_HZ) clk = ~clk;

logic reset;
logic [127:0] data_out;
logic data_out_valid, data_out_last, data_out_ready;
logic [31:0][15:0] data_in;
logic data_in_valid, data_in_ready;
logic capture;

Axis_If #(.DWIDTH(512)) data_in_if();
Axis_If #(.DWIDTH(128)) data_out_if();

sample_buffer #(
  .BUFFER_DEPTH(1024),
  .PARALLEL_SAMPLES(32),
  .INPUT_SAMPLE_WIDTH(16),
  .OUTPUT_SAMPLE_WIDTH(16),
  .AXI_MM_WIDTH(128)
) buffer_i (
  .clk,
  .reset,
  .data_out(data_out_if),
  .data_in(data_in_if),
  .capture
);

logic [31:0][15:0] data_sent [1024];

assign data_out = data_out_if.data;
assign data_out_valid = data_out_if.valid;
assign data_out_last = data_out_if.last;
assign data_out_if.ready = data_out_ready;

assign data_in_if.data = data_in;
assign data_in_if.valid = data_in_valid;
assign data_in_ready = data_in_if.ready;

always @(posedge clk) begin
  for (int i = 0; i < 32; i++) begin
    data_in[i] <= $urandom_range(0,1<<16);
  end
end

int sent_count;
always @(posedge clk) begin
  if (reset) begin
    sent_count <= 0;
  end else begin
    if (capture && data_in_valid && data_in_ready) begin
      sent_count <= sent_count + 1;
    end
  end
  data_sent[sent_count] <= data_in;
end

assign data_out_ready = 0;
assign data_in_valid = 1;

// checker
int recv_count, error_count;
bit state;
always @(posedge clk) begin
  if (state) begin
    // report results
    $display("transaction count: %d", recv_count);
    $display("error count: %d", error_count);
    $finish;
  end
  if (reset) begin
    recv_count <= 0;
    error_count <= 0;
    state <= 1'b0;
  end else begin
    if (data_out_valid && data_out_ready) begin
      recv_count <= recv_count + 1;
      for (int i = 0; i < 8; i++) begin
        if (data_out[16*i+:16] !== data_sent[recv_count >> 2][(recv_count % 4)*8+i]) begin
          $display("data mismatch, got %h, expected %h", data_out[16*i+:16], data_sent[recv_count >> 2][recv_count % 4]);
          $display("recv_count: %d", recv_count);
          error_count <= error_count + 1;
        end
      end
      if (data_out_last) begin
        state <= 1'b1;
      end
    end
  end
end


initial begin
  reset <= 1;
  capture <= 0;
  repeat (5000) @(posedge clk);
  reset <= 0;
  repeat (5000) @(posedge clk);
  capture <= 1;
  @(posedge clk);
  capture <= 0;
  repeat (5000) @(posedge clk);
  data_out_ready <= 1;
  repeat (50) @(posedge clk);
  data_out_ready <= 0;
  repeat (100) @(posedge clk);
  data_out_ready <= 1;
  repeat (10000) @(posedge clk);
  capture <= 1;
  repeat (1000) @(posedge clk);
  capture <= 0;
  repeat (1000) @(posedge clk);
  data_out_ready <= 1;
  repeat (100) @(posedge clk);
  data_out_ready <= 0;
  repeat (100) @(posedge clk);
  data_out_ready <= 1;
  repeat (500) @(posedge clk);
  data_out_ready <= 0;
  repeat (100) @(posedge clk);
  data_out_ready <= 1;
end
endmodule
