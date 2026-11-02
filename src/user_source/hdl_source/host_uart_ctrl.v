module host_uart_ctrl #(
    parameter integer CLK_FREQ_HZ = 100_000_000,
    parameter integer BAUD_RATE = 115_200,
    parameter integer IMAGE_BYTES = 640 * 480 * 3
)(
    input wire clk,
    input wire rst,
    input wire uart_rx,
    output reg next_toggle,
    output reg auto_toggle,
    output reg param_panel_toggle,
    output reg param_write_toggle,
    output reg [1:0] param_select,
    output reg [7:0] param_value,
    output reg upload_start,
    output reg upload_done,
    output reg upload_active,
    output reg pixel_valid,
    output reg [31:0] pixel_data,
    output reg packet_busy
);

localparam integer BIT_TICKS = CLK_FREQ_HZ / BAUD_RATE;
localparam integer HALF_BIT_TICKS = BIT_TICKS / 2;
localparam [1:0] RX_IDLE = 2'd0;
localparam [1:0] RX_START = 2'd1;
localparam [1:0] RX_DATA = 2'd2;
localparam [1:0] RX_STOP = 2'd3;
localparam [1:0] CMD_WAIT = 2'd0;
localparam [1:0] CMD_OPCODE = 2'd1;
localparam [1:0] CMD_VALUE = 2'd2;
localparam [1:0] CMD_IMAGE = 2'd3;

reg [1:0] rx_sync;
reg [1:0] rx_state;
reg [15:0] rx_count;
reg [2:0] rx_bit;
reg [7:0] rx_shift;
reg [1:0] command_state;
reg [31:0] image_byte_count;
reg [1:0] pixel_byte_index;
reg [7:0] pixel_red;
reg [7:0] pixel_green;
reg finish_pending;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        rx_sync <= 2'b11;
        rx_state <= RX_IDLE;
        rx_count <= 16'd0;
        rx_bit <= 3'd0;
        rx_shift <= 8'd0;
        command_state <= CMD_WAIT;
        image_byte_count <= 32'd0;
        pixel_byte_index <= 2'd0;
        pixel_red <= 8'd0;
        pixel_green <= 8'd0;
        finish_pending <= 1'b0;
        next_toggle <= 1'b0;
        auto_toggle <= 1'b0;
        param_panel_toggle <= 1'b0;
        param_write_toggle <= 1'b0;
        param_select <= 2'd0;
        param_value <= 8'd0;
        upload_start <= 1'b0;
        upload_done <= 1'b0;
        upload_active <= 1'b0;
        pixel_valid <= 1'b0;
        pixel_data <= 32'd0;
        packet_busy <= 1'b0;
    end else begin
        rx_sync <= {rx_sync[0], uart_rx};
        upload_start <= 1'b0;
        upload_done <= 1'b0;
        pixel_valid <= 1'b0;

        if (finish_pending) begin
            finish_pending <= 1'b0;
            upload_active <= 1'b0;
            packet_busy <= 1'b0;
            command_state <= CMD_WAIT;
            upload_done <= 1'b1;
        end

        case (rx_state)
            RX_IDLE: begin
                if (!rx_sync[1]) begin
                    rx_count <= HALF_BIT_TICKS - 1;
                    rx_state <= RX_START;
                end
            end

            RX_START: begin
                if (rx_count != 0)
                    rx_count <= rx_count - 16'd1;
                else if (!rx_sync[1]) begin
                    rx_count <= BIT_TICKS - 1;
                    rx_bit <= 3'd0;
                    rx_state <= RX_DATA;
                end else begin
                    rx_state <= RX_IDLE;
                end
            end

            RX_DATA: begin
                if (rx_count != 0)
                    rx_count <= rx_count - 16'd1;
                else begin
                    rx_shift[rx_bit] <= rx_sync[1];
                    rx_count <= BIT_TICKS - 1;
                    if (rx_bit == 3'd7)
                        rx_state <= RX_STOP;
                    else
                        rx_bit <= rx_bit + 3'd1;
                end
            end

            RX_STOP: begin
                if (rx_count != 0)
                    rx_count <= rx_count - 16'd1;
                else begin
                    rx_state <= RX_IDLE;
                    if (rx_sync[1]) begin
                        if (command_state == CMD_IMAGE) begin
                            case (pixel_byte_index)
                                2'd0: begin
                                    pixel_red <= rx_shift;
                                    pixel_byte_index <= 2'd1;
                                end
                                2'd1: begin
                                    pixel_green <= rx_shift;
                                    pixel_byte_index <= 2'd2;
                                end
                                default: begin
                                    pixel_data <= {pixel_red, pixel_green, rx_shift, 8'd0};
                                    pixel_valid <= 1'b1;
                                    pixel_byte_index <= 2'd0;
                                end
                            endcase

                            if (image_byte_count == IMAGE_BYTES - 1)
                                finish_pending <= 1'b1;
                            else
                                image_byte_count <= image_byte_count + 32'd1;
                        end else if (command_state == CMD_WAIT) begin
                            if (rx_shift == 8'hA5) begin
                                command_state <= CMD_OPCODE;
                                packet_busy <= 1'b1;
                            end
                        end else if (command_state == CMD_OPCODE) begin
                            case (rx_shift)
                                8'h01: begin
                                    next_toggle <= ~next_toggle;
                                    command_state <= CMD_WAIT;
                                    packet_busy <= 1'b0;
                                end
                                8'h02: begin
                                    auto_toggle <= ~auto_toggle;
                                    command_state <= CMD_WAIT;
                                    packet_busy <= 1'b0;
                                end
                                8'h03: begin
                                    param_panel_toggle <= ~param_panel_toggle;
                                    command_state <= CMD_WAIT;
                                    packet_busy <= 1'b0;
                                end
                                8'h10, 8'h11, 8'h12: begin
                                    param_select <= (rx_shift == 8'h10) ? 2'd0 :
                                                    (rx_shift == 8'h11) ? 2'd1 : 2'd2;
                                    command_state <= CMD_VALUE;
                                end
                                8'h20: begin
                                    image_byte_count <= 32'd0;
                                    pixel_byte_index <= 2'd0;
                                    upload_active <= 1'b1;
                                    upload_start <= 1'b1;
                                    command_state <= CMD_IMAGE;
                                end
                                default: begin
                                    command_state <= CMD_WAIT;
                                    packet_busy <= 1'b0;
                                end
                            endcase
                        end else if (command_state == CMD_VALUE) begin
                            param_value <= rx_shift;
                            param_write_toggle <= ~param_write_toggle;
                            command_state <= CMD_WAIT;
                            packet_busy <= 1'b0;
                        end
                    end else begin
                        command_state <= CMD_WAIT;
                        upload_active <= 1'b0;
                        packet_busy <= 1'b0;
                    end
                end
            end

            default: rx_state <= RX_IDLE;
        endcase
    end
end

endmodule
