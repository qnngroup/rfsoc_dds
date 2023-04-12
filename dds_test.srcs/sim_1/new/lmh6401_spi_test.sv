`timescale 1ns / 1ps
module lmh6401_spi_test();

logic clk = 0;
localparam CLK_RATE_HZ = 100_000_000;
always #(0.5s/CLK_RATE_HZ) clk = ~clk;

logic reset;

logic [15:0] data_in;
logic data_in_valid, data_in_ready;
logic cs_n;
logic sck;
logic sdi;

lmh6401_spi #(
  .AXIS_CLK_FREQ(100_000_000),
  .SPI_CLK_FREQ(1_000_000)
) dut_i (
  .clk, .reset,
  .data_in,
  .data_in_valid,
  .data_in_ready,
  .cs_n,
  .sck,
  .sdi
);

initial begin
  reset <= 1;
  data_in <= '0;
  data_in_valid <= '0;
  repeat (500) @(posedge clk);
  reset <= 0;
  repeat (500) @(posedge clk);
  data_in <= 16'h3bcd;
  @(posedge clk);
  data_in_valid <= 1'b1;
  do @(posedge clk); while (!data_in_ready);
  data_in_valid <= 1'b0;
  repeat (500) @(posedge clk);
  data_in <= 16'h5ebf;
  data_in_valid <= 1'b1;
  do @(posedge clk); while (!data_in_ready);
  data_in_valid <= 1'b0;
  repeat (5000) @(posedge clk);
  data_in <= 16'h27fc;
  data_in_valid <= 1'b1;
  do @(posedge clk); while (!data_in_ready);
  data_in_valid <= 1'b0;
  repeat (2000) @(posedge clk);
  $finish;
end

endmodule
