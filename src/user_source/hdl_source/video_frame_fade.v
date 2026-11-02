module video_frame_fade(
    input  wire       I_clk,
    input  wire       I_rst,
    input  wire       I_frame_start,
    input  wire       I_transition_start_toggle,
    input  wire [1:0] I_display_buf_idx,
    input  wire [1:0] I_display_image_idx,
    output reg        O_buffer_swap_toggle,
    output reg        O_transition_done_toggle,
    output reg  [4:0] O_level,
    output wire       O_slide_active,
    output reg  [9:0] O_slide_offset
);

localparam [2:0] ST_IDLE      = 3'd0;
localparam [2:0] ST_FADE_OUT  = 3'd1;
localparam [2:0] ST_WAIT_BUF  = 3'd2;
localparam [2:0] ST_FADE_IN   = 3'd3;
localparam [2:0] ST_SLIDE_OUT = 3'd4;
localparam [2:0] ST_SLIDE_IN  = 3'd5;
localparam [9:0] SLIDE_WIDTH  = 10'd640;
localparam [9:0] SLIDE_STEP   = 10'd40;

reg [2:0] state;
reg [2:0] start_sync;
reg [1:0] buf_idx_sync0;
reg [1:0] buf_idx_sync1;
reg [1:0] previous_buf_idx;
reg [1:0] image_idx_sync0;
reg [1:0] image_idx_sync1;
reg slide_transition;

wire start_pulse = start_sync[2] ^ start_sync[1];

assign O_slide_active = slide_transition &&
                        ((state == ST_SLIDE_OUT) ||
                         (state == ST_WAIT_BUF) ||
                         (state == ST_SLIDE_IN));

always @(posedge I_clk or posedge I_rst) begin
    if (I_rst) begin
        start_sync                 <= 3'b000;
        buf_idx_sync0              <= 2'b00;
        buf_idx_sync1              <= 2'b00;
        image_idx_sync0            <= 2'b00;
        image_idx_sync1            <= 2'b00;
        previous_buf_idx           <= 2'd0;
        state                      <= ST_IDLE;
        slide_transition           <= 1'b0;
        O_buffer_swap_toggle       <= 1'b0;
        O_transition_done_toggle   <= 1'b0;
        O_level                    <= 5'd16;
        O_slide_offset             <= 10'd0;
    end else begin
        start_sync   <= {start_sync[1:0], I_transition_start_toggle};
        buf_idx_sync0 <= I_display_buf_idx;
        buf_idx_sync1 <= buf_idx_sync0;
        image_idx_sync0 <= I_display_image_idx;
        image_idx_sync1 <= image_idx_sync0;

        case (state)
            ST_IDLE: begin
                O_level <= 5'd16;
                if (start_pulse) begin
                    previous_buf_idx <= buf_idx_sync1;
                    slide_transition <= (image_idx_sync1 == 2'd2) ||
                                        (image_idx_sync1 == 2'd3);
                    O_slide_offset   <= 10'd0;
                    if ((image_idx_sync1 == 2'd2) ||
                        (image_idx_sync1 == 2'd3))
                        state <= ST_SLIDE_OUT;
                    else
                        state <= ST_FADE_OUT;
                end
            end

            ST_FADE_OUT: begin
                if (I_frame_start) begin
                    if (O_level != 5'd0)
                        O_level <= O_level - 5'd1;
                    else begin
                        O_buffer_swap_toggle <= ~O_buffer_swap_toggle;
                        state                <= ST_WAIT_BUF;
                    end
                end
            end

            ST_WAIT_BUF: begin
                if (I_frame_start && (buf_idx_sync1 != previous_buf_idx)) begin
                    if (slide_transition)
                        state <= ST_SLIDE_IN;
                    else
                        state <= ST_FADE_IN;
                end
            end

            ST_FADE_IN: begin
                if (I_frame_start) begin
                    if (O_level < 5'd16)
                        O_level <= O_level + 5'd1;
                    else begin
                        O_transition_done_toggle <= ~O_transition_done_toggle;
                        state <= ST_IDLE;
                    end
                end
            end

            ST_SLIDE_OUT: begin
                O_level <= 5'd16;
                if (I_frame_start) begin
                    if (O_slide_offset < SLIDE_WIDTH)
                        O_slide_offset <= O_slide_offset + SLIDE_STEP;
                    else begin
                        O_buffer_swap_toggle <= ~O_buffer_swap_toggle;
                        state                <= ST_WAIT_BUF;
                    end
                end
            end

            ST_SLIDE_IN: begin
                O_level <= 5'd16;
                if (I_frame_start) begin
                    if (O_slide_offset > SLIDE_STEP)
                        O_slide_offset <= O_slide_offset - SLIDE_STEP;
                    else if (O_slide_offset != 10'd0)
                        O_slide_offset <= 10'd0;
                    else begin
                        O_transition_done_toggle <= ~O_transition_done_toggle;
                        slide_transition         <= 1'b0;
                        state                    <= ST_IDLE;
                    end
                end
            end

            default: begin
                state   <= ST_IDLE;
                O_level <= 5'd16;
                slide_transition <= 1'b0;
                O_slide_offset <= 10'd0;
            end
        endcase
    end
end

endmodule
