module lmh6401_spi #(
  parameter int AXIS_CLK_FREQ = 150_000_000,
  parameter int SPI_CLK_FREQ = 1_000_000
) (
  input wire clk, reset,
  input [15:0] data_in,
  input data_in_valid,
  output data_in_ready,
  output logic cs_n,
  output logic sck,
  output logic sdi_o,
  output logic sdi_t
);

localparam int CLK_DIV = int'(AXIS_CLK_FREQ/SPI_CLK_FREQ);
localparam int CLK_COUNTER_BITS = $clog2(CLK_DIV);
localparam int CLK_COUNTER_MAX = int'(CLK_DIV / 2) - 1;

logic sck_last;

logic [CLK_COUNTER_BITS-1:0] clk_counter;
always_ff @(posedge clk) begin
  sck_last <= sck;
  if (reset) begin
    sck <= 1'b0;
    clk_counter <= '0;
  end else begin
    if (clk_counter == CLK_COUNTER_MAX) begin
      sck <= ~sck;
      clk_counter <= '0;
    end else begin
      clk_counter <= clk_counter + 1;
    end
  end
end

enum {IDLE, SENDING, FINISH} state;
logic [15:0] data;
logic [3:0] bits_sent;

logic sck_negedge;
assign sck_negedge = (sck_last == 1'b1 && clk_counter == CLK_COUNTER_MAX);

assign data_in_ready = state == IDLE;

always_ff @(posedge clk) begin
  if (reset) begin
    state <= IDLE;
    bits_sent <= '0;
    cs_n <= 1'b1;
    sdi_o <= 1'b0;
  end else begin
    if (data_in_valid && data_in_ready) begin
      state <= SENDING;
    end
    unique case (state)
      IDLE: if (data_in_valid && data_in_ready) begin 
        state <= SENDING;
        data <= {1'b1, data_in[14:0]};
      end
      SENDING: begin
        if (sck_negedge) begin
          cs_n <= 1'b0;
          sdi_o <= data[15];
          data <= {data[14:0], 1'b1};
          bits_sent <= bits_sent + 1'b1;
          if (bits_sent == 15) begin
            state <= FINISH;
          end
        end
      end
      FINISH: if (sck_negedge) begin
        cs_n <= 1'b1;
        state <= IDLE;
      end
    endcase
  end
end

endmodule
