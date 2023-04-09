module lfsr16 (
  input wire clk, reset,
  input logic enable,
  output logic [15:0] data_out
);

localparam [15:0] LFSR_POLY = 16'hb400;
always @(posedge clk) begin
  if (reset) begin
    data_out <= 16'hace1;
  end else begin
    if (enable) begin
      data_out <= ({16{data_out[0]}} & LFSR_POLY) ^ {1'b0, data_out[15:1]};
    end
  end
end

endmodule

module lfsr16_parallel #(
  parameter int PARALLEL_SAMPLES = 4
) (
  input wire clk, reset,
  input logic enable,
  output logic [PARALLEL_SAMPLES-1:0][15:0] data_out
);

localparam [15:0] LFSR_POLY = 16'hb400;

function logic [15:0] lfsr_step(input logic [15:0] state);
  return ({16{state[0]}} & LFSR_POLY) ^ {1'b0, state[15:1]};
endfunction

logic [15:0] state_t;

always @(posedge clk) begin
  logic [PARALLEL_SAMPLES-1:0][15:0] state_t;
  if (reset) begin
    for (int i = 0; i < PARALLEL_SAMPLES; i++) begin
      state_t = 16'hace1;
      for (int j = 0; j < i; j++) begin
        state_t = lfsr_step(state_t);
      end
      data_out[i] <= state_t;
    end
  end else begin
    if (enable) begin
      for (int i = 0; i < PARALLEL_SAMPLES; i++) begin
        state_t = data_out[i];
        for (int j = 0; j < PARALLEL_SAMPLES; j++) begin
          state_t = lfsr_step(state_t);
        end
        data_out[i] <= state_t;
      end
    end
  end
end

endmodule
