module hdmi_text_overlay #(
    parameter integer CLK_FREQ_HZ = 25_000_000,
    parameter integer BAUD_RATE   = 115_200,
    parameter integer TEXT_MAX    = 32
)(
    input  wire        I_clk,
    input  wire        I_rst,
    input  wire        I_uart_rx,
    input  wire        I_de,
    input  wire        I_vs,
    input  wire [23:0] I_rgb,
    output reg  [23:0] O_rgb
);

localparam integer BIT_TICKS      = CLK_FREQ_HZ / BAUD_RATE;
localparam integer HALF_BIT_TICKS = BIT_TICKS / 2;
localparam [1:0] RX_IDLE  = 2'd0;
localparam [1:0] RX_START = 2'd1;
localparam [1:0] RX_DATA  = 2'd2;
localparam [1:0] RX_STOP  = 2'd3;

reg [1:0] rx_sync;
reg [1:0] rx_state;
reg [15:0] rx_count;
reg [2:0] rx_bit;
reg [7:0] rx_shift;

reg [7:0] staging_text [0:TEXT_MAX-1];
reg [7:0] active_text [0:TEXT_MAX-1];
reg [5:0] staging_len;
reg [5:0] active_len;

reg de_d;
reg vs_d;
reg [9:0] pixel_x;
reg [9:0] pixel_y;
reg [10:0] scroll_offset;

integer init_idx;
integer copy_idx;

wire [10:0] text_width = {active_len, 3'b000};
wire [10:0] scroll_length = 11'd640 + text_width;
wire [10:0] marquee_x = {1'b0, pixel_x} + scroll_offset;
wire marquee_visible = (active_len != 0) &&
                       (marquee_x >= 11'd640) &&
                       ((marquee_x - 11'd640) < text_width);
wire [10:0] text_pixel_x = marquee_x - 11'd640;
wire [5:0] text_index = text_pixel_x[10:3];
wire [2:0] text_column = text_pixel_x[2:0];
wire [2:0] text_row = (pixel_y - 10'd453) >> 1;
wire [4:0] safe_text_index = (text_index < TEXT_MAX) ? text_index[4:0] : 5'd0;
wire [7:0] text_char = active_text[safe_text_index];
wire [34:0] glyph_bitmap = glyph_5x7(text_char);
wire [5:0] glyph_bit_index = (text_column < 3'd5)
    ? 6'd34 - (text_row * 6'd5) - text_column
    : 6'd0;
wire text_pixel = marquee_visible &&
                  (pixel_y >= 10'd453) && (pixel_y < 10'd467) &&
                  (text_column < 3'd5) && glyph_bitmap[glyph_bit_index];

function [34:0] glyph_5x7;
    input [7:0] character;
    begin
        case (character)
            "A": glyph_5x7 = {5'b01110,5'b10001,5'b10001,5'b11111,5'b10001,5'b10001,5'b10001};
            "B": glyph_5x7 = {5'b11110,5'b10001,5'b10001,5'b11110,5'b10001,5'b10001,5'b11110};
            "C": glyph_5x7 = {5'b01111,5'b10000,5'b10000,5'b10000,5'b10000,5'b10000,5'b01111};
            "D": glyph_5x7 = {5'b11110,5'b10001,5'b10001,5'b10001,5'b10001,5'b10001,5'b11110};
            "E": glyph_5x7 = {5'b11111,5'b10000,5'b10000,5'b11110,5'b10000,5'b10000,5'b11111};
            "F": glyph_5x7 = {5'b11111,5'b10000,5'b10000,5'b11110,5'b10000,5'b10000,5'b10000};
            "G": glyph_5x7 = {5'b01111,5'b10000,5'b10000,5'b10111,5'b10001,5'b10001,5'b01111};
            "H": glyph_5x7 = {5'b10001,5'b10001,5'b10001,5'b11111,5'b10001,5'b10001,5'b10001};
            "I": glyph_5x7 = {5'b11111,5'b00100,5'b00100,5'b00100,5'b00100,5'b00100,5'b11111};
            "J": glyph_5x7 = {5'b00111,5'b00010,5'b00010,5'b00010,5'b00010,5'b10010,5'b01100};
            "K": glyph_5x7 = {5'b10001,5'b10010,5'b10100,5'b11000,5'b10100,5'b10010,5'b10001};
            "L": glyph_5x7 = {5'b10000,5'b10000,5'b10000,5'b10000,5'b10000,5'b10000,5'b11111};
            "M": glyph_5x7 = {5'b10001,5'b11011,5'b10101,5'b10101,5'b10001,5'b10001,5'b10001};
            "N": glyph_5x7 = {5'b10001,5'b11001,5'b10101,5'b10011,5'b10001,5'b10001,5'b10001};
            "O": glyph_5x7 = {5'b01110,5'b10001,5'b10001,5'b10001,5'b10001,5'b10001,5'b01110};
            "P": glyph_5x7 = {5'b11110,5'b10001,5'b10001,5'b11110,5'b10000,5'b10000,5'b10000};
            "Q": glyph_5x7 = {5'b01110,5'b10001,5'b10001,5'b10001,5'b10101,5'b10010,5'b01101};
            "R": glyph_5x7 = {5'b11110,5'b10001,5'b10001,5'b11110,5'b10100,5'b10010,5'b10001};
            "S": glyph_5x7 = {5'b01111,5'b10000,5'b10000,5'b01110,5'b00001,5'b00001,5'b11110};
            "T": glyph_5x7 = {5'b11111,5'b00100,5'b00100,5'b00100,5'b00100,5'b00100,5'b00100};
            "U": glyph_5x7 = {5'b10001,5'b10001,5'b10001,5'b10001,5'b10001,5'b10001,5'b01110};
            "V": glyph_5x7 = {5'b10001,5'b10001,5'b10001,5'b10001,5'b10001,5'b01010,5'b00100};
            "W": glyph_5x7 = {5'b10001,5'b10001,5'b10001,5'b10101,5'b10101,5'b10101,5'b01010};
            "X": glyph_5x7 = {5'b10001,5'b10001,5'b01010,5'b00100,5'b01010,5'b10001,5'b10001};
            "Y": glyph_5x7 = {5'b10001,5'b10001,5'b01010,5'b00100,5'b00100,5'b00100,5'b00100};
            "Z": glyph_5x7 = {5'b11111,5'b00001,5'b00010,5'b00100,5'b01000,5'b10000,5'b11111};
            "0": glyph_5x7 = {5'b01110,5'b10001,5'b10011,5'b10101,5'b11001,5'b10001,5'b01110};
            "1": glyph_5x7 = {5'b00100,5'b01100,5'b00100,5'b00100,5'b00100,5'b00100,5'b01110};
            "2": glyph_5x7 = {5'b01110,5'b10001,5'b00001,5'b00010,5'b00100,5'b01000,5'b11111};
            "3": glyph_5x7 = {5'b11110,5'b00001,5'b00001,5'b01110,5'b00001,5'b00001,5'b11110};
            "4": glyph_5x7 = {5'b00010,5'b00110,5'b01010,5'b10010,5'b11111,5'b00010,5'b00010};
            "5": glyph_5x7 = {5'b11111,5'b10000,5'b10000,5'b11110,5'b00001,5'b00001,5'b11110};
            "6": glyph_5x7 = {5'b01110,5'b10000,5'b10000,5'b11110,5'b10001,5'b10001,5'b01110};
            "7": glyph_5x7 = {5'b11111,5'b00001,5'b00010,5'b00100,5'b01000,5'b01000,5'b01000};
            "8": glyph_5x7 = {5'b01110,5'b10001,5'b10001,5'b01110,5'b10001,5'b10001,5'b01110};
            "9": glyph_5x7 = {5'b01110,5'b10001,5'b10001,5'b01111,5'b00001,5'b00001,5'b01110};
            "-": glyph_5x7 = {5'b00000,5'b00000,5'b00000,5'b11111,5'b00000,5'b00000,5'b00000};
            "_": glyph_5x7 = {5'b00000,5'b00000,5'b00000,5'b00000,5'b00000,5'b00000,5'b11111};
            ".": glyph_5x7 = {5'b00000,5'b00000,5'b00000,5'b00000,5'b00000,5'b00110,5'b00110};
            ",": glyph_5x7 = {5'b00000,5'b00000,5'b00000,5'b00000,5'b00110,5'b00100,5'b01000};
            "!": glyph_5x7 = {5'b00100,5'b00100,5'b00100,5'b00100,5'b00100,5'b00000,5'b00100};
            "?": glyph_5x7 = {5'b01110,5'b10001,5'b00001,5'b00010,5'b00100,5'b00000,5'b00100};
            ":": glyph_5x7 = {5'b00000,5'b00110,5'b00110,5'b00000,5'b00110,5'b00110,5'b00000};
            "/": glyph_5x7 = {5'b00001,5'b00010,5'b00010,5'b00100,5'b01000,5'b01000,5'b10000};
            default: glyph_5x7 = 35'd0;
        endcase
    end
endfunction

always @(posedge I_clk or posedge I_rst) begin
    if (I_rst) begin
        rx_sync      <= 2'b11;
        rx_state     <= RX_IDLE;
        rx_count     <= 16'd0;
        rx_bit       <= 3'd0;
        rx_shift     <= 8'd0;
        staging_len  <= 6'd0;
        active_len   <= 6'd18;
        de_d         <= 1'b0;
        vs_d         <= 1'b0;
        pixel_x      <= 10'd0;
        pixel_y      <= 10'd0;
        scroll_offset<= 11'd0;
        active_text[0]  <= "H";
        active_text[1]  <= "X";
        active_text[2]  <= "4";
        active_text[3]  <= "S";
        active_text[4]  <= "2";
        active_text[5]  <= "0";
        active_text[6]  <= " ";
        active_text[7]  <= "H";
        active_text[8]  <= "D";
        active_text[9]  <= "M";
        active_text[10] <= "I";
        active_text[11] <= " ";
        active_text[12] <= "P";
        active_text[13] <= "L";
        active_text[14] <= "A";
        active_text[15] <= "Y";
        active_text[16] <= "E";
        active_text[17] <= "R";
        for (init_idx = 18; init_idx < TEXT_MAX; init_idx = init_idx + 1)
            active_text[init_idx] <= " ";
        for (init_idx = 0; init_idx < TEXT_MAX; init_idx = init_idx + 1)
            staging_text[init_idx] <= " ";
    end else begin
        rx_sync <= {rx_sync[0], I_uart_rx};
        de_d    <= I_de;
        vs_d    <= I_vs;

        if (vs_d && !I_vs) begin
            pixel_y <= 10'd0;
            pixel_x <= 10'd0;
            if (active_len != 0) begin
                if (scroll_offset >= scroll_length - 11'd1)
                    scroll_offset <= 11'd0;
                else
                    scroll_offset <= scroll_offset + 11'd1;
            end
        end else if (I_de) begin
            if (!de_d)
                pixel_x <= 10'd0;
            else if (pixel_x < 10'd639)
                pixel_x <= pixel_x + 10'd1;
        end else if (de_d) begin
            pixel_x <= 10'd0;
            if (pixel_y < 10'd479)
                pixel_y <= pixel_y + 10'd1;
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
                    rx_bit   <= 3'd0;
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
                        if ((rx_shift == 8'h0A) || (rx_shift == 8'h0D)) begin
                            if (staging_len != 0) begin
                                for (copy_idx = 0; copy_idx < TEXT_MAX; copy_idx = copy_idx + 1) begin
                                    if (copy_idx < staging_len)
                                        active_text[copy_idx] <= staging_text[copy_idx];
                                    else
                                        active_text[copy_idx] <= " ";
                                end
                                active_len    <= staging_len;
                                staging_len   <= 6'd0;
                                scroll_offset <= 11'd0;
                            end
                        end else if ((rx_shift >= 8'h20) && (rx_shift <= 8'h7E) &&
                                     (staging_len < TEXT_MAX)) begin
                            if ((rx_shift >= "a") && (rx_shift <= "z"))
                                staging_text[staging_len] <= rx_shift - 8'd32;
                            else
                                staging_text[staging_len] <= rx_shift;
                            staging_len <= staging_len + 6'd1;
                        end
                    end
                end
            end

            default: rx_state <= RX_IDLE;
        endcase
    end
end

always @* begin
    O_rgb = I_rgb;
    if (I_de && (pixel_y >= 10'd440)) begin
        O_rgb[23:16] = {1'b0, I_rgb[23:17]} + 8'd8;
        O_rgb[15:8]  = {1'b0, I_rgb[15:9]}  + 8'd12;
        O_rgb[7:0]   = {1'b0, I_rgb[7:1]}   + 8'd24;
    end
    if (I_de && text_pixel)
        O_rgb = 24'hFFFFFF;
end

endmodule
