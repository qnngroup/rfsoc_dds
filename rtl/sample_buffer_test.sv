`timescale 1ns / 1ps

module sample_buffer_test ();

logic clk = 0;
localparam CLK_RATE_HZ = 100_000_000;
always #(0.5s/CLK_RATE_HZ) clk = ~clk;

logic reset;
logic [127:0] data_out;
logic data_out_valid, data_out_last, data_out_ready;
logic [23:0] data_in;
logic data_in_valid, data_in_ready;
logic capture;

Axis_If #(.DWIDTH(32)) data_in_if();
Axis_If #(.DWIDTH(128)) data_out_if();

sample_buffer #(.BUFFER_DEPTH(1024)) buffer_i (
  .clk,
  .reset,
  .data_out(data_out_if),
  .phase_inc_in(data_in_if),
  .capture
);

assign data_out = data_out_if.data;
assign data_out_valid = data_out_if.valid;
assign data_out_last = data_out_if.last;
assign data_out_if.ready = data_out_ready;

assign data_in_if.data = data_in;
assign data_in_if.valid = data_in_valid;
assign data_in_ready = data_in_if.ready;

assign data_in = 50*3178; // just give it blank data for now
assign data_out_ready = 0;
assign data_in_valid = 1;

initial begin
  reset = 1;
  capture = 0;
  repeat (5000) @(posedge clk);
  reset = 0;
  repeat (5000) @(posedge clk);
  capture = 1;
  repeat (10000) @(posedge clk);
  capture = 0;
  repeat (1000) @(posedge clk);
  data_out_ready = 1;
  repeat (100) @(posedge clk);
  data_out_ready = 0;
  repeat (100) @(posedge clk);
  data_out_ready = 1;
  repeat (500) @(posedge clk);
  data_out_ready = 0;
  repeat (100) @(posedge clk);
  data_out_ready = 1;
  repeat (10000) @(posedge clk);
  $finish;
end
endmodule
