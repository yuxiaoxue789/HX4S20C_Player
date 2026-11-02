module wav_audio_reader(
    input                   clk,
    input                   rst,
    input                   sd_init_done,
    input                   scan_done,
    input                   display_valid,
    input      [1:0]        display_image_idx,
    input                   music_found,
    input      [31:0]       music_start_sector,
    input      [6:0]        music_data_offset,
    input      [31:0]       music_data_size,
    input                   voice_found,
    input      [31:0]       voice_start_sector,
    input      [6:0]        voice_data_offset,
    input      [31:0]       voice_data_size,
    input                   sd_sec_read_data_valid,
    input      [7:0]        sd_sec_read_data,
    input                   sd_sec_read_end,
    input      [10:0]       fifo_wr_level,
    input                   fifo_wr_full,
    output reg              sd_sec_read,
    output reg [31:0]       sd_sec_read_addr,
    output reg              fifo_wr_en,
    output reg [16:0]       fifo_wr_data,
    output reg              generation
);

localparam ST_IDLE = 1'b0;
localparam ST_READ = 1'b1;

reg state;
reg active;
reg active_voice;
reg stream_started;
reg stream_done;
reg first_sector;
reg restart_pending;
reg pending_voice;
reg discard_sector;
reg low_byte_valid;
reg [7:0] low_byte;
reg [8:0] sector_byte_index;
reg [31:0] bytes_remaining;
reg [31:0] music_sector_latched;
reg [31:0] music_size_latched;
reg [6:0] music_offset_latched;
reg [6:0] voice_offset_latched;

wire requested_voice = (display_image_idx == 2'd3);
wire selected_file_found = active_voice ? voice_found : music_found;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        state <= ST_IDLE;
        active <= 1'b0;
        active_voice <= 1'b0;
        stream_started <= 1'b0;
        stream_done <= 1'b0;
        first_sector <= 1'b0;
        restart_pending <= 1'b0;
        pending_voice <= 1'b0;
        discard_sector <= 1'b0;
        low_byte_valid <= 1'b0;
        low_byte <= 8'd0;
        sector_byte_index <= 9'd0;
        bytes_remaining <= 32'd0;
        music_sector_latched <= 32'd0;
        music_size_latched <= 32'd0;
        music_offset_latched <= 7'd0;
        voice_offset_latched <= 7'd0;
        sd_sec_read <= 1'b0;
        sd_sec_read_addr <= 32'd0;
        fifo_wr_en <= 1'b0;
        fifo_wr_data <= 17'd0;
        generation <= 1'b0;
    end else begin
        fifo_wr_en <= 1'b0;

        if (!scan_done || !display_valid || !sd_init_done) begin
            active <= 1'b0;
            state <= ST_IDLE;
            sd_sec_read <= 1'b0;
            stream_started <= 1'b0;
            stream_done <= 1'b0;
            restart_pending <= 1'b0;
            discard_sector <= 1'b0;
            low_byte_valid <= 1'b0;
        end else begin
            if (!active || (requested_voice != active_voice)) begin
                active <= 1'b1;
                active_voice <= requested_voice;
                generation <= ~generation;
                stream_started <= 1'b0;
                stream_done <= 1'b0;
                low_byte_valid <= 1'b0;
                first_sector <= 1'b1;
                sector_byte_index <= 9'd0;
                if ((state == ST_READ) && !sd_sec_read_end) begin
                    restart_pending <= 1'b1;
                    pending_voice <= requested_voice;
                    discard_sector <= 1'b1;
                end else begin
                    state <= ST_IDLE;
                    sd_sec_read <= 1'b0;
                    restart_pending <= 1'b0;
                    discard_sector <= 1'b0;
                    if (requested_voice) begin
                        sd_sec_read_addr <= voice_start_sector;
                        bytes_remaining <= voice_data_size;
                    end else begin
                        sd_sec_read_addr <= music_start_sector;
                        bytes_remaining <= music_data_size;
                    end
                end
            end else begin
                case (state)
                    ST_IDLE: begin
                        sd_sec_read <= 1'b0;
                        if (!stream_done && selected_file_found &&
                            (bytes_remaining == 32'd0) && stream_started) begin
                            if (!active_voice) begin
                                bytes_remaining <= music_size_latched;
                                sd_sec_read_addr <= music_sector_latched;
                                first_sector <= 1'b1;
                                low_byte_valid <= 1'b0;
                                stream_started <= 1'b0;
                            end else begin
                                stream_done <= 1'b1;
                            end
                        end else if (!stream_done && selected_file_found &&
                                     (bytes_remaining != 32'd0) &&
                                     (fifo_wr_level <= 11'd768)) begin
                            sd_sec_read <= 1'b1;
                            sector_byte_index <= 9'd0;
                            state <= ST_READ;
                            stream_started <= 1'b1;
                        end
                    end

                    ST_READ: begin
                        if (sd_sec_read_data_valid) begin
                            sector_byte_index <= sector_byte_index + 9'd1;
                            if (!discard_sector && (!first_sector ||
                                 (sector_byte_index >=
                                  (active_voice ? voice_offset_latched :
                                                    music_offset_latched))) &&
                                (bytes_remaining != 32'd0)) begin
                                bytes_remaining <= bytes_remaining - 32'd1;
                                if (!low_byte_valid) begin
                                    low_byte <= sd_sec_read_data;
                                    low_byte_valid <= 1'b1;
                                end else begin
                                    if (!fifo_wr_full) begin
                                        fifo_wr_en <= 1'b1;
                                        fifo_wr_data <= {generation,
                                                         sd_sec_read_data,
                                                         low_byte};
                                    end
                                    low_byte_valid <= 1'b0;
                                end
                            end
                        end

                        if (sd_sec_read_end) begin
                            sd_sec_read <= 1'b0;
                            state <= ST_IDLE;
                            if (restart_pending) begin
                                restart_pending <= 1'b0;
                                discard_sector <= 1'b0;
                                first_sector <= 1'b1;
                                sector_byte_index <= 9'd0;
                                stream_started <= 1'b0;
                                if (pending_voice) begin
                                    sd_sec_read_addr <= voice_start_sector;
                                    bytes_remaining <= voice_data_size;
                                end else begin
                                    sd_sec_read_addr <= music_start_sector;
                                    bytes_remaining <= music_data_size;
                                end
                            end else begin
                                sd_sec_read_addr <= sd_sec_read_addr + 32'd1;
                                first_sector <= 1'b0;
                            end
                        end
                    end

                    default: begin
                        state <= ST_IDLE;
                        sd_sec_read <= 1'b0;
                    end
                endcase
            end
        end

        if (!active && scan_done && display_valid) begin
            music_sector_latched <= music_start_sector;
            music_size_latched <= music_data_size;
            music_offset_latched <= music_data_offset;
            voice_offset_latched <= voice_data_offset;
        end
    end
end

endmodule
