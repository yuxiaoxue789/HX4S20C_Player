module audio_sample_async_fifo #(
    parameter integer ADDR_WIDTH = 10
)(
    input                   wr_clk,
    input                   rd_clk,
    input                   rst,
    input                   wr_en,
    input      [16:0]       wr_data,
    output                  wr_full,
    output     [ADDR_WIDTH:0] wr_level,
    input                   rd_en,
    output                  rd_empty,
    output reg              rd_valid,
    output reg [16:0]       rd_data
);

localparam integer DEPTH = 1 << ADDR_WIDTH;

reg [16:0] memory [0:DEPTH-1];
reg [ADDR_WIDTH:0] wr_binary;
reg [ADDR_WIDTH:0] wr_gray;
reg [ADDR_WIDTH:0] rd_binary;
reg [ADDR_WIDTH:0] rd_gray;
reg [ADDR_WIDTH:0] rd_gray_sync_1;
reg [ADDR_WIDTH:0] rd_gray_sync_2;
reg [ADDR_WIDTH:0] wr_gray_sync_1;
reg [ADDR_WIDTH:0] wr_gray_sync_2;

wire [ADDR_WIDTH:0] wr_binary_next;
wire [ADDR_WIDTH:0] wr_gray_next;
wire [ADDR_WIDTH:0] rd_binary_next;
wire [ADDR_WIDTH:0] rd_gray_next;
wire [ADDR_WIDTH:0] rd_binary_sync;

function [ADDR_WIDTH:0] gray_to_binary;
    input [ADDR_WIDTH:0] gray;
    integer i;
    begin
        gray_to_binary[ADDR_WIDTH] = gray[ADDR_WIDTH];
        for (i = ADDR_WIDTH - 1; i >= 0; i = i - 1)
            gray_to_binary[i] = gray_to_binary[i + 1] ^ gray[i];
    end
endfunction

assign rd_binary_sync = gray_to_binary(rd_gray_sync_2);
assign wr_level = wr_binary - rd_binary_sync;
assign rd_empty = (rd_gray == wr_gray_sync_2);
assign wr_full = (wr_gray ==
    {~rd_gray_sync_2[ADDR_WIDTH:ADDR_WIDTH-1],
      rd_gray_sync_2[ADDR_WIDTH-2:0]});
assign wr_binary_next = wr_binary + ((wr_en && !wr_full) ? 1'b1 : 1'b0);
assign wr_gray_next = (wr_binary_next >> 1) ^ wr_binary_next;
assign rd_binary_next = rd_binary + ((rd_en && !rd_empty) ? 1'b1 : 1'b0);
assign rd_gray_next = (rd_binary_next >> 1) ^ rd_binary_next;

always @(posedge wr_clk or posedge rst) begin
    if (rst) begin
        wr_binary <= {(ADDR_WIDTH + 1){1'b0}};
        wr_gray <= {(ADDR_WIDTH + 1){1'b0}};
        rd_gray_sync_1 <= {(ADDR_WIDTH + 1){1'b0}};
        rd_gray_sync_2 <= {(ADDR_WIDTH + 1){1'b0}};
    end else begin
        rd_gray_sync_1 <= rd_gray;
        rd_gray_sync_2 <= rd_gray_sync_1;
        if (wr_en && !wr_full)
            memory[wr_binary[ADDR_WIDTH-1:0]] <= wr_data;
        wr_binary <= wr_binary_next;
        wr_gray <= wr_gray_next;
    end
end

always @(posedge rd_clk or posedge rst) begin
    if (rst) begin
        rd_binary <= {(ADDR_WIDTH + 1){1'b0}};
        rd_gray <= {(ADDR_WIDTH + 1){1'b0}};
        wr_gray_sync_1 <= {(ADDR_WIDTH + 1){1'b0}};
        wr_gray_sync_2 <= {(ADDR_WIDTH + 1){1'b0}};
        rd_valid <= 1'b0;
        rd_data <= 17'd0;
    end else begin
        wr_gray_sync_1 <= wr_gray;
        wr_gray_sync_2 <= wr_gray_sync_1;
        rd_valid <= 1'b0;
        if (rd_en && !rd_empty) begin
            rd_data <= memory[rd_binary[ADDR_WIDTH-1:0]];
            rd_valid <= 1'b1;
        end
        rd_binary <= rd_binary_next;
        rd_gray <= rd_gray_next;
    end
end

endmodule
