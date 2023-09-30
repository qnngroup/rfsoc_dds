// fifo.sv - Reed Foster
// output is unregistered; probably won't infer block ram
module fifo #(
  parameter int DATA_WIDTH = 16,
  parameter int ADDR_WIDTH = 5
) (
  input wire clk, reset,

  Axis_If.Master_Simple data_out,
  Axis_If.Slave_Simple data_in
);

logic [DATA_WIDTH-1:0] buffer [2**ADDR_WIDTH];

logic [ADDR_WIDTH:0] read_addr, write_addr; // extra bit to track full/empty state

logic full, empty;
logic lsbs_equal;
assign lsbs_equal = read_addr[ADDR_WIDTH-1:0] == write_addr[ADDR_WIDTH-1:0];
assign full  = lsbs_equal & (read_addr[ADDR_WIDTH] ^ write_addr[ADDR_WIDTH]);
assign empty = lsbs_equal & (~(read_addr[ADDR_WIDTH] ^ write_addr[ADDR_WIDTH]));

assign data_in.ready = !full;
assign data_out.valid = !empty;
assign data_out.data = buffer[read_addr[ADDR_WIDTH-1:0]];

always_ff @(posedge clk) begin
  if (reset) begin
    read_addr <= '0;
    write_addr <= '0;
  end else begin
    if (!full && data_in.valid) begin
      buffer[write_addr[ADDR_WIDTH-1:0]] <= data_in.data;
      write_addr <= write_addr + 1'b1;
    end
    if (!empty && data_out.ready) begin
      read_addr <= read_addr + 1'b1;
    end
  end
end

endmodule
