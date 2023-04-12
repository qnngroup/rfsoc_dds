module lmh6401_spi_wrapper (
  input wire clk, reset_n,
  input [15:0] data_in,
  input data_in_valid,
  output data_in_ready,
  output cs_n,
  output sck,
  output sdi_o,
  output sdi_t
);

lmh6401_spi #(
  .AXIS_CLK_FREQ(150_000_000),
  .SPI_CLK_FREQ(1_000_000)
) lmh6401_spi_i (
  .clk(clk),
  .reset(~reset_n),
  .data_in(data_in),
  .data_in_valid(data_in_valid),
  .data_in_ready(data_in_ready),
  .cs_n(cs_n),
  .sck(sck),
  .sdi(sdi_o),
  .sdi(sdi_t)
);
endmodule
