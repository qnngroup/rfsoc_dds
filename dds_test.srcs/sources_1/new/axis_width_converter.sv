// width converter
// constructs a single UP -> DOWN resizer
// The UP resizer always accepts samples, so it can run at full rate.
// Therefore, the rate of the input is limited by the output rate.
// If DOWN > UP, then the input must stall occasionally, which is to be
// expected.
module axis_width_converter #(
  parameter int DWIDTH_IN = 192,
  parameter int UP = 4,
  parameter int DOWN = 3
) (
  input wire clk, reset,
  Axis_If.Slave_Full data_in,
  Axis_If.Master_Full data_out
);

Axis_If #(.DWIDTH(DWIDTH_IN*UP)) data ();

axis_upsizer #(
  .DWIDTH(DWIDTH_IN),
  .UP(UP)
) up_i (
  .clk,
  .reset,
  .data_in,
  .data_out(data)
);

axis_downsizer #(
  .DWIDTH(DWIDTH_IN*UP),
  .DOWN(DOWN)
) down_i (
  .clk,
  .reset,
  .data_in(data),
  .data_out
);

endmodule

module axis_downsizer #(
  parameter int DWIDTH = 256,
  parameter int DOWN = 2
) (
  input wire clk, reset,
  Axis_If.Slave_Full data_in,
  Axis_If.Master_Full data_out
);

localparam int DWIDTH_OUT = DWIDTH/DOWN;

logic [DOWN-1:0][DWIDTH_OUT-1:0] data_reg;
logic valid_reg, last_reg;
logic [$clog2(DOWN)-1:0] counter;
logic read_final, rollover;

assign read_final = counter == DOWN - 1;
assign rollover = read_final & data_out.ready;

assign data_in.ready = rollover | (~data_out.valid);

assign data_out.data = data_reg[counter];
assign data_out.valid = valid_reg;
assign data_out.last = last_reg & read_final;

always_ff @(posedge clk) begin
  if (reset) begin
    counter <= '0;
    data_reg <= '0;
    valid_reg <= '0;
    last_reg <= '0;
  end else begin
    if (data_in.ready) begin
      data_reg <= data_in.data;
      valid_reg <= data_in.valid;
      last_reg <= data_in.last;
    end
    if (data_out.ok) begin
      if (read_final) begin
        counter <= '0;
      end else begin
        counter <= counter + 1'b1;
      end
    end
  end
end

endmodule

module axis_upsizer #(
  parameter int DWIDTH = 16,
  parameter int UP = 8
) (
  input wire clk, reset,
  Axis_If.Slave_Full data_in,
  Axis_If.Master_Full data_out
);

localparam DWIDTH_OUT = DWIDTH*UP;

logic [UP-1:0][DWIDTH-1:0] data_reg;
logic [$clog2(UP)-1:0] counter;

assign data_in.ready = data_out.ready;
assign data_out.data = data_reg;
//assign data_out.valid = (counter == UP - 1) | data_in.last;
//assign data_out.last = data_in.last;

always_ff @(posedge clk) begin
  if (reset) begin
    counter <= '0;
    data_reg <= '0;
    data_out.valid <= '0;
    data_out.last <= '0;
  end else begin
    if ((!data_out.valid) || data_out.ready) begin
      data_out.valid <= ((counter == UP - 1) | (data_in.last)) && data_in.ok;
      data_out.last <= data_in.last;
    end
    if (data_in.ok) begin
      data_reg[counter] <= data_in.data;
      if (counter == UP - 1) begin
        counter <= '0;
      end else begin
        counter <= counter + 1'b1;
      end
    end
  end
end

endmodule
