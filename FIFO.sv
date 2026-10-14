module FIFO #(
  parameter DATA_WIDTH = 8,  // Width of the data
  parameter DEPTH = 16       // Depth of the FIFO (must be a power of 2)
)(
  input clk,
  input rst,
  input wr,
  input rd,
  input [DATA_WIDTH-1:0] din,
  output reg [DATA_WIDTH-1:0] dout,
  output empty,
  output full
);

  // Pointers for write and read operations
  // FIX: pointers are exactly $clog2(DEPTH) bits wide, so they wrap from DEPTH-1 back to 0
  // and never index outside mem (the old extra bit let them reach DEPTH..2*DEPTH-1).
  reg [$clog2(DEPTH)-1:0] wptr = 0, rptr = 0;

  // Counter for tracking the number of elements in the FIFO
  reg [$clog2(DEPTH+1):0] cnt = 0;

  // Memory array to store data
  reg [DATA_WIDTH-1:0] mem [DEPTH-1:0];

  always @(posedge clk) begin
    if (rst) begin
      // Reset the pointers and counter when the reset signal is asserted
      wptr <= 0;
      rptr <= 0;
      cnt  <= 0;
    end
    else if (wr && !full) begin
      // Write data to the FIFO if it's not full
      mem[wptr] <= din;
      wptr      <= wptr + 1;
      cnt       <= cnt + 1;
    end
    else if (rd && !empty) begin
      // Read data from the FIFO if it's not empty
      dout <= mem[rptr];
      rptr <= rptr + 1;
      cnt  <= cnt - 1;
    end
  end

  // Determine if the FIFO is empty or full
  assign empty = (cnt == 0);
  assign full  = (cnt == DEPTH);

endmodule

interface fifo_if #(parameter DATA_WIDTH = 8, parameter DEPTH = 16)();
  logic clock, rd, wr, rst;
  logic full, empty;
  logic [DATA_WIDTH-1:0] data_in;
  logic [DATA_WIDTH-1:0] data_out;
endinterface