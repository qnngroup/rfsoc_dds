module lmh6401_spi_wrapper (
  input wire clk, reset_n,
  input [16:0] data_in_tdata,
  input data_in_tvalid,
  output data_in_tready,
  output [1:0] cs_n,
  output sck,
  output sdi
);

lmh6401_spi #(
  .AXIS_CLK_FREQ(150_000_000),
  .SPI_CLK_FREQ(750_000),
  .NUM_CHANNELS(2)
) lmh6401_spi_i (
  .clk(clk),
  .reset(~reset_n),
  .addr_in(data_in_tdata[16:16]),
  .data_in(data_in_tdata[15:0]),
  .data_in_valid(data_in_tvalid),
  .data_in_ready(data_in_tready),
  .cs_n(cs_n),
  .sck(sck),
  .sdi(sdi)
);
endmodule
