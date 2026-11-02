module bmp_read(
    input                       clk,
    input                       rst,
    output                      ready,

    // 上电扫描：从 scan_start_sector 开始，顺序寻找前 scan_target_count 张 BMP
    input                       scan_start,
    input  [31:0]               scan_start_sector,
    input  [31:0]               scan_max_sector,
    input  [2:0]                scan_target_count,
    output reg                  scan_done,
    output reg                  scan_found_valid,
    output reg [31:0]           scan_found_sector,
    output reg [2:0]            scan_found_total,
    output reg                  music_found,
    output reg [31:0]           music_start_sector,
    output reg [6:0]            music_data_offset,
    output reg [31:0]           music_data_size,
    output reg                  voice_found,
    output reg [31:0]           voice_start_sector,
    output reg [6:0]            voice_data_offset,
    output reg [31:0]           voice_data_size,

    // 按指定扇区加载一张图到 SDRAM
    input                       load_start,
    input  [31:0]               load_sector,

    input                       sd_init_done,
    output reg [3:0]            state_code,
    input  [15:0]               bmp_width,
    input  [15:0]               bmp_height,
    input                       write_fifo_almost_full,

    output reg                  write_req,
    input                       write_req_ack,

    output reg                  sd_sec_read,
    output reg [31:0]           sd_sec_read_addr,
    input  [7:0]                sd_sec_read_data,
    input                       sd_sec_read_data_valid,
    input                       sd_sec_read_end,

    output                      bmp_data_wr_en,
    output [23:0]               bmp_data
);

localparam ST_IDLE      = 3'd0;
localparam ST_SCAN      = 3'd1;
localparam ST_LOAD_HDR  = 3'd2;
localparam ST_LOAD_WAIT = 3'd3;
localparam ST_LOAD_DATA = 3'd4;
localparam ST_SCAN_ADVANCE = 3'd5;

reg [2:0]  state;
reg [9:0]  rd_cnt;

reg [7:0]  header_0;
reg [7:0]  header_1;
reg [31:0] file_len;
reg [31:0] pixel_offset;
reg [31:0] width;
reg [31:0] height;
reg [15:0] bit_count;
reg [31:0] compression;

reg [31:0] scan_sector;
reg [1:0] wav_found_total;
reg [7:0] wav_header [0:45];
reg [31:0] load_sector_latched;
reg [31:0] bmp_len_cnt;
reg [1:0]  bmp_byte_idx;
reg [19:0] bmp_pixel_count;
reg [23:0] src_pixel;
reg        src_pixel_valid;
reg        scale_start;

wire header_match;
wire supported_size;
wire bmp_data_valid;
wire [19:0] bmp_pixel_limit;
wire native_640x480;
wire scale_pixel_valid;
wire [23:0] scale_pixel;
reg  [22:0] file_sector_count;
wire [31:0] next_scan_sector_if_match;
wire [31:0] next_scan_sector_if_miss;
wire [22:0] calculated_file_sector_count;
wire wav_header_match;
wire [31:0] wav_candidate_data_size;
wire [6:0] wav_candidate_data_offset;
wire [31:0] wav_candidate_total_bytes;
wire [22:0] wav_candidate_sector_count;

assign wav_header_match =
    (wav_header[0] == "R") && (wav_header[1] == "I") &&
    (wav_header[2] == "F") && (wav_header[3] == "F") &&
    (wav_header[8] == "W") && (wav_header[9] == "A") &&
    (wav_header[10] == "V") && (wav_header[11] == "E") &&
    (wav_header[12] == "f") && (wav_header[13] == "m") &&
    (wav_header[14] == "t") && (wav_header[15] == " ") &&
    (wav_header[20] == 8'd1) && (wav_header[21] == 8'd0) &&
    (wav_header[22] == 8'd1) && (wav_header[23] == 8'd0) &&
    (wav_header[24] == 8'h80) && (wav_header[25] == 8'hbb) &&
    (wav_header[26] == 8'd0) && (wav_header[27] == 8'd0) &&
    (wav_header[32] == 8'd2) && (wav_header[33] == 8'd0) &&
    (wav_header[34] == 8'd16) && (wav_header[35] == 8'd0) &&
    (((wav_header[16] == 8'd16) && (wav_header[17] == 8'd0) &&
      (wav_header[18] == 8'd0) && (wav_header[19] == 8'd0) &&
      (wav_header[36] == "d") && (wav_header[37] == "a") &&
      (wav_header[38] == "t") && (wav_header[39] == "a")) ||
     ((wav_header[16] == 8'd18) && (wav_header[17] == 8'd0) &&
      (wav_header[18] == 8'd0) && (wav_header[19] == 8'd0) &&
      (wav_header[38] == "d") && (wav_header[39] == "a") &&
      (wav_header[40] == "t") && (wav_header[41] == "a")));

assign wav_candidate_data_offset =
    (wav_header[16] == 8'd16) ? 7'd44 : 7'd46;
assign wav_candidate_data_size =
    (wav_header[16] == 8'd16)
        ? {wav_header[43], wav_header[42], wav_header[41], wav_header[40]}
        : {wav_header[45], wav_header[44], wav_header[43], wav_header[42]};
assign wav_candidate_total_bytes =
    wav_candidate_data_size + {25'd0, wav_candidate_data_offset};
assign wav_candidate_sector_count =
    wav_candidate_total_bytes[31:9] +
    {22'd0, (|wav_candidate_total_bytes[8:0])};

assign ready = (state == ST_IDLE);
assign supported_size = ((width == 32'd640) && (height == 32'd480)) ||
                        ((width == 32'd480) && (height == 32'd640)) ||
                        ((width == 32'd800) && (height == 32'd600)) ||
                        ((width == 32'd320) && (height == 32'd240));
assign header_match = (header_0 == "B") &&
                      (header_1 == "M") &&
                      supported_size &&
                      (bit_count    == 16'd24) &&
                      (compression  == 32'd0);
assign bmp_pixel_limit = (width == 32'd800) ? 20'd480000 :
                         (width == 32'd320) ? 20'd76800  :
                                              20'd307200;
assign native_640x480 = (width == 32'd640) && (height == 32'd480);
assign bmp_data_valid = (sd_sec_read_data_valid == 1'b1) &&
                        (bmp_len_cnt >= pixel_offset) &&
                        (bmp_len_cnt <  file_len);
assign calculated_file_sector_count = (file_len == 32'd0)
    ? 23'd1
    : file_len[31:9] + {22'd0, (|file_len[8:0])};
assign next_scan_sector_if_match = scan_sector + file_sector_count;
assign next_scan_sector_if_miss  = scan_sector + 32'd1;
assign bmp_data_wr_en = native_640x480 ? src_pixel_valid : scale_pixel_valid;
assign bmp_data = native_640x480 ? src_pixel : scale_pixel;

bmp_frame_scaler bmp_frame_scaler_m0(
    .clk                 (clk),
    .rst                 (rst),
    .start               (scale_start),
    .source_width        (width[15:0]),
    .source_height       (height[15:0]),
    .target_width        (bmp_width),
    .target_height       (bmp_height),
    .pixel_fifo_almost_full (write_fifo_almost_full),
    .source_pixel_valid  (src_pixel_valid),
    .source_pixel        (src_pixel),
    .pixel_valid         (scale_pixel_valid),
    .pixel               (scale_pixel)
);

always @(posedge clk or posedge rst) begin
    if (rst) begin
        rd_cnt <= 10'd0;
    end else if ((state == ST_SCAN) || (state == ST_LOAD_HDR)) begin
        if (sd_sec_read_data_valid)
            rd_cnt <= rd_cnt + 10'd1;
        else if (sd_sec_read_end)
            rd_cnt <= 10'd0;
    end else begin
        rd_cnt <= 10'd0;
    end
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        header_0     <= 8'd0;
        header_1     <= 8'd0;
        file_len     <= 32'd0;
        pixel_offset <= 32'd54;
        width        <= 32'd0;
        height       <= 32'd0;
        bit_count    <= 16'd0;
        compression  <= 32'd0;
        file_sector_count <= 23'd1;
    end else if (((state == ST_SCAN) || (state == ST_LOAD_HDR)) && sd_sec_read_data_valid) begin
        case (rd_cnt)
            10'd0 : header_0 <= sd_sec_read_data;
            10'd1 : header_1 <= sd_sec_read_data;

            10'd2 : file_len[7:0] <= sd_sec_read_data;
            10'd3 : file_len[15:8] <= sd_sec_read_data;
            10'd4 : file_len[23:16] <= sd_sec_read_data;
            10'd5 : file_len[31:24] <= sd_sec_read_data;

            10'd10: pixel_offset[7:0] <= sd_sec_read_data;
            10'd11: pixel_offset[15:8] <= sd_sec_read_data;
            10'd12: pixel_offset[23:16] <= sd_sec_read_data;
            10'd13: pixel_offset[31:24] <= sd_sec_read_data;

            10'd18: width[7:0] <= sd_sec_read_data;
            10'd19: width[15:8] <= sd_sec_read_data;
            10'd20: width[23:16] <= sd_sec_read_data;
            10'd21: width[31:24] <= sd_sec_read_data;

            10'd22: height[7:0] <= sd_sec_read_data;
            10'd23: height[15:8] <= sd_sec_read_data;
            10'd24: height[23:16] <= sd_sec_read_data;
            10'd25: height[31:24] <= sd_sec_read_data;

            10'd28: bit_count[7:0] <= sd_sec_read_data;
            10'd29: bit_count[15:8] <= sd_sec_read_data;

            10'd30: compression[7:0] <= sd_sec_read_data;
            10'd31: compression[15:8] <= sd_sec_read_data;
            10'd32: compression[23:16] <= sd_sec_read_data;
            10'd33: compression[31:24] <= sd_sec_read_data;
            default: ;
        endcase
        if ((state == ST_SCAN) && (rd_cnt == 10'd6))
            file_sector_count <= calculated_file_sector_count;
    end
end

always @(posedge clk) begin
    if ((state == ST_SCAN) && sd_sec_read_data_valid &&
        (rd_cnt < 10'd46))
        wav_header[rd_cnt[5:0]] <= sd_sec_read_data;
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        bmp_len_cnt <= 32'd0;
    end else if (state == ST_LOAD_DATA) begin
        if (sd_sec_read_data_valid)
            bmp_len_cnt <= bmp_len_cnt + 32'd1;
    end else begin
        bmp_len_cnt <= 32'd0;
    end
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        bmp_byte_idx <= 2'd0;
    end else if (state == ST_LOAD_DATA) begin
        if (bmp_data_valid)
            bmp_byte_idx <= (bmp_byte_idx == 2'd2) ? 2'd0 : (bmp_byte_idx + 2'd1);
    end else begin
        bmp_byte_idx <= 2'd0;
    end
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        src_pixel       <= 24'd0;
        src_pixel_valid <= 1'b0;
        bmp_pixel_count <= 20'd0;
    end else if (state == ST_LOAD_DATA) begin
        src_pixel_valid <= 1'b0;
        if (bmp_data_valid) begin
            case (bmp_byte_idx)
                2'd0: begin
                    src_pixel[7:0] <= sd_sec_read_data;
                end
                2'd1: begin
                    src_pixel[15:8] <= sd_sec_read_data;
                end
                2'd2: begin
                    src_pixel[23:16] <= sd_sec_read_data;
                    if (bmp_pixel_count < bmp_pixel_limit) begin
                        src_pixel_valid <= 1'b1;
                        bmp_pixel_count <= bmp_pixel_count + 20'd1;
                    end
                end
                default: ;
            endcase
        end
    end else begin
        src_pixel_valid <= 1'b0;
        bmp_pixel_count <= 20'd0;
    end
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        state             <= ST_IDLE;
        state_code        <= 4'd0;
        sd_sec_read       <= 1'b0;
        sd_sec_read_addr  <= 32'd0;
        write_req         <= 1'b0;
        scan_done         <= 1'b0;
        scan_found_valid  <= 1'b0;
        scan_found_sector <= 32'd0;
        scan_found_total  <= 3'd0;
        wav_found_total   <= 2'd0;
        music_found       <= 1'b0;
        music_start_sector <= 32'd0;
        music_data_offset <= 7'd0;
        music_data_size   <= 32'd0;
        voice_found       <= 1'b0;
        voice_start_sector <= 32'd0;
        voice_data_offset <= 7'd0;
        voice_data_size   <= 32'd0;
        scan_sector       <= 32'd0;
        load_sector_latched <= 32'd0;
        scale_start       <= 1'b0;
    end else if (!sd_init_done) begin
        state             <= ST_IDLE;
        state_code        <= 4'd0;
        sd_sec_read       <= 1'b0;
        sd_sec_read_addr  <= 32'd0;
        write_req         <= 1'b0;
        scan_done         <= 1'b0;
        scan_found_valid  <= 1'b0;
        scan_found_sector <= 32'd0;
        scan_found_total  <= 3'd0;
        wav_found_total   <= 2'd0;
        music_found       <= 1'b0;
        music_start_sector <= 32'd0;
        music_data_offset <= 7'd0;
        music_data_size   <= 32'd0;
        voice_found       <= 1'b0;
        voice_start_sector <= 32'd0;
        voice_data_offset <= 7'd0;
        voice_data_size   <= 32'd0;
        scan_sector       <= 32'd0;
        load_sector_latched <= 32'd0;
        scale_start       <= 1'b0;
    end else begin
        scan_found_valid <= 1'b0;
        scale_start      <= 1'b0;

        case (state)
            ST_IDLE: begin
                state_code  <= 4'd1;
                sd_sec_read <= 1'b0;
                write_req   <= 1'b0;

                if (scan_start) begin
                    scan_done        <= 1'b0;
                    scan_found_total <= 3'd0;
                    wav_found_total <= 2'd0;
                    music_found <= 1'b0;
                    voice_found <= 1'b0;
                    scan_sector      <= scan_start_sector;
                    sd_sec_read_addr <= scan_start_sector;
                    state            <= ST_SCAN;
                end else if (load_start) begin
                    load_sector_latched <= load_sector;
                    sd_sec_read_addr    <= load_sector;
                    state               <= ST_LOAD_HDR;
                end
            end

            ST_SCAN: begin
                state_code  <= 4'd2;
                sd_sec_read <= 1'b1;

                if (sd_sec_read_end) begin
                    sd_sec_read <= 1'b0;

                    if (wav_header_match && (wav_candidate_data_size != 32'd0) &&
                        (wav_found_total < 2'd2)) begin
                        if (wav_found_total == 2'd0) begin
                            music_found <= 1'b1;
                            music_start_sector <= scan_sector;
                            music_data_offset <= wav_candidate_data_offset;
                            music_data_size <= wav_candidate_data_size;
                        end else begin
                            voice_found <= 1'b1;
                            voice_start_sector <= scan_sector;
                            voice_data_offset <= wav_candidate_data_offset;
                            voice_data_size <= wav_candidate_data_size;
                        end
                        wav_found_total <= wav_found_total + 2'd1;
                        sd_sec_read_addr <= scan_sector + wav_candidate_sector_count;
                        scan_sector <= scan_sector + wav_candidate_sector_count;
                        state <= ST_SCAN_ADVANCE;
                    end else if (header_match) begin
                        scan_found_valid  <= 1'b1;
                        scan_found_sector <= scan_sector;
                        scan_found_total  <= scan_found_total + 3'd1;
                        sd_sec_read_addr  <= next_scan_sector_if_match;
                        scan_sector       <= next_scan_sector_if_match;

                        if (scan_found_total + 3'd1 >= scan_target_count) begin
                            scan_done <= 1'b1;
                            state     <= ST_IDLE;
                        end else begin
                            state <= ST_SCAN_ADVANCE;
                        end
                    end else begin
                        if (scan_sector >= scan_max_sector) begin
                            scan_done <= 1'b1;
                            state     <= ST_IDLE;
                        end else begin
                            sd_sec_read_addr <= next_scan_sector_if_miss;
                            scan_sector      <= next_scan_sector_if_miss;
                            state            <= ST_SCAN_ADVANCE;
                        end
                    end
                end
            end

            ST_SCAN_ADVANCE: begin
                state_code  <= 4'd2;
                sd_sec_read <= 1'b0;

                if (scan_sector > scan_max_sector) begin
                    scan_done <= 1'b1;
                    state     <= ST_IDLE;
                end else begin
                    state <= ST_SCAN;
                end
            end

            ST_LOAD_HDR: begin
                state_code  <= 4'd2;
                sd_sec_read <= 1'b1;

                if (sd_sec_read_end) begin
                    sd_sec_read <= 1'b0;
                    if (header_match) begin
                        write_req        <= 1'b1;
                        sd_sec_read_addr <= load_sector_latched;
                        state            <= ST_LOAD_WAIT;
                    end else begin
                        state <= ST_IDLE;
                    end
                end
            end

            ST_LOAD_WAIT: begin
                state_code <= 4'd3;
                if (write_req_ack) begin
                    write_req <= 1'b0;
                    scale_start <= !native_640x480;
                    state     <= ST_LOAD_DATA;
                end
            end

            ST_LOAD_DATA: begin
                state_code  <= 4'd4;
                sd_sec_read <= 1'b1;

                if (sd_sec_read_end) begin
                    sd_sec_read <= 1'b0;
                    if (bmp_len_cnt >= file_len) begin
                        state <= ST_IDLE;
                    end else begin
                        sd_sec_read_addr <= sd_sec_read_addr + 32'd1;
                    end
                end
            end

            default: begin
                state       <= ST_IDLE;
                state_code  <= 4'd1;
                sd_sec_read <= 1'b0;
                write_req   <= 1'b0;
            end
        endcase
    end
end

endmodule

module bmp_frame_scaler(
    input               clk,
    input               rst,
    input               start,
    input      [15:0]   source_width,
    input      [15:0]   source_height,
    input      [15:0]   target_width,
    input      [15:0]   target_height,
    input               pixel_fifo_almost_full,
    input               source_pixel_valid,
    input      [23:0]   source_pixel,
    output reg          pixel_valid,
    output reg [23:0]   pixel
);

localparam ST_WAIT_LINE = 1'b0;
localparam ST_OUTPUT_LINE = 1'b1;

reg [23:0] line_buffer_0 [0:799];
reg [23:0] line_buffer_1 [0:799];
reg [1:0]  line_repeat_count_0;
reg [1:0]  line_repeat_count_1;
reg [1:0]  line_ready;
reg        write_buf_sel;
reg        read_buf_sel;
reg        state;
reg        scale_active;
reg [15:0] source_width_latched;
reg [15:0] source_height_latched;
reg [15:0] target_width_latched;
reg [15:0] target_height_latched;
reg [15:0] scaled_width;
reg [15:0] horizontal_offset;
reg [15:0] vertical_phase;
reg [9:0]  source_pixel_x;
reg [9:0]  source_read_x;
reg [9:0]  output_x;
reg [9:0]  output_y;
reg [1:0]  repeat_remaining;
reg [15:0] horizontal_phase;
reg [2:0]  pixel_rate_divider;

wire [16:0] vertical_sum;
wire [16:0] vertical_after_first;
wire [16:0] horizontal_sum;
wire [16:0] horizontal_after_first;

assign vertical_sum = {1'b0, vertical_phase} + {1'b0, target_height_latched};
assign vertical_after_first = vertical_sum - {1'b0, source_height_latched};
assign horizontal_sum = {1'b0, horizontal_phase} + {1'b0, source_width_latched};
assign horizontal_after_first = horizontal_sum - {1'b0, scaled_width};

always @(posedge clk or posedge rst) begin
    if (rst) begin
        line_repeat_count_0 <= 2'd0;
        line_repeat_count_1 <= 2'd0;
        line_ready          <= 2'b00;
        write_buf_sel       <= 1'b0;
        read_buf_sel        <= 1'b0;
        state               <= ST_WAIT_LINE;
        scale_active        <= 1'b0;
        source_width_latched  <= 16'd0;
        source_height_latched <= 16'd0;
        target_width_latched  <= 16'd0;
        target_height_latched <= 16'd0;
        scaled_width        <= 16'd0;
        horizontal_offset   <= 16'd0;
        vertical_phase      <= 16'd0;
        source_pixel_x      <= 10'd0;
        source_read_x       <= 10'd0;
        output_x            <= 10'd0;
        output_y            <= 10'd0;
        repeat_remaining    <= 2'd0;
        horizontal_phase    <= 16'd0;
        pixel_rate_divider  <= 3'd0;
        pixel_valid         <= 1'b0;
        pixel               <= 24'd0;
    end else begin
        pixel_valid <= 1'b0;

        if (start) begin
            source_width_latched  <= source_width;
            source_height_latched <= source_height;
            target_width_latched  <= target_width;
            target_height_latched <= target_height;
            if ((source_width == 16'd480) && (source_height == 16'd640)) begin
                scaled_width      <= 16'd360;
                horizontal_offset <= (target_width - 16'd360) >> 1;
            end else begin
                scaled_width      <= target_width;
                horizontal_offset <= 16'd0;
            end
            vertical_phase   <= source_height - 16'd1;
            source_pixel_x   <= 10'd0;
            source_read_x    <= 10'd0;
            output_x         <= 10'd0;
            output_y         <= 10'd0;
            repeat_remaining <= 2'd0;
            horizontal_phase <= 16'd0;
            pixel_rate_divider <= 3'd0;
            line_repeat_count_0 <= 2'd0;
            line_repeat_count_1 <= 2'd0;
            line_ready        <= 2'b00;
            write_buf_sel     <= 1'b0;
            read_buf_sel      <= 1'b0;
            state             <= ST_WAIT_LINE;
            scale_active      <= 1'b1;
        end else if (scale_active) begin
            if (state == ST_WAIT_LINE) begin
                if (line_ready[read_buf_sel]) begin
                    if (read_buf_sel)
                        repeat_remaining <= line_repeat_count_1;
                    else
                        repeat_remaining <= line_repeat_count_0;

                    if ((read_buf_sel && (line_repeat_count_1 == 2'd0)) ||
                        (!read_buf_sel && (line_repeat_count_0 == 2'd0))) begin
                        line_ready[read_buf_sel] <= 1'b0;
                        read_buf_sel <= ~read_buf_sel;
                    end else begin
                        output_x         <= 10'd0;
                        source_read_x    <= 10'd0;
                        horizontal_phase <= 16'd0;
                        pixel_rate_divider <= 3'd0;
                        state            <= ST_OUTPUT_LINE;
                    end
                end
            end else begin
                // Stop before the FIFO fills so the registered pixel can still be accepted.
                if ((pixel_rate_divider == 3'd7) && !pixel_fifo_almost_full) begin
                    pixel_rate_divider <= 3'd0;
                    pixel_valid <= 1'b1;
                    if ((output_x < horizontal_offset) ||
                        (output_x >= horizontal_offset + scaled_width)) begin
                        pixel <= 24'd0;
                    end else if (read_buf_sel) begin
                        pixel <= line_buffer_1[source_read_x];
                    end else begin
                        pixel <= line_buffer_0[source_read_x];
                    end

                    if ((output_x >= horizontal_offset) &&
                        (output_x < horizontal_offset + scaled_width)) begin
                        if (horizontal_sum >= {1'b0, scaled_width}) begin
                            if (horizontal_after_first >= {1'b0, scaled_width}) begin
                                horizontal_phase <= horizontal_after_first - {1'b0, scaled_width};
                                source_read_x <= source_read_x + 10'd2;
                            end else begin
                                horizontal_phase <= horizontal_after_first[15:0];
                                source_read_x <= source_read_x + 10'd1;
                            end
                        end else begin
                            horizontal_phase <= horizontal_sum[15:0];
                        end
                    end

                    if (output_x == target_width_latched - 16'd1) begin
                        output_x <= 10'd0;
                        horizontal_phase <= 16'd0;
                        source_read_x <= 10'd0;
                        if (repeat_remaining > 2'd1) begin
                            repeat_remaining <= repeat_remaining - 2'd1;
                        end else begin
                            line_ready[read_buf_sel] <= 1'b0;
                            read_buf_sel <= ~read_buf_sel;
                            repeat_remaining <= 2'd0;
                            state <= ST_WAIT_LINE;
                        end

                        if (output_y == target_height_latched - 16'd1) begin
                            scale_active <= 1'b0;
                        end else begin
                            output_y <= output_y + 10'd1;
                        end
                    end else begin
                        output_x <= output_x + 10'd1;
                    end
                end else begin
                    pixel_rate_divider <= pixel_rate_divider + 3'd1;
                end
            end

            if (source_pixel_valid && (source_pixel_x < source_width_latched)) begin
                if (write_buf_sel)
                    line_buffer_1[source_pixel_x] <= source_pixel;
                else
                    line_buffer_0[source_pixel_x] <= source_pixel;

                if (source_pixel_x == source_width_latched - 16'd1) begin
                    source_pixel_x <= 10'd0;
                    write_buf_sel <= ~write_buf_sel;
                    vertical_phase <= vertical_sum[15:0];
                    if (vertical_sum >= {1'b0, source_height_latched}) begin
                        if (vertical_after_first >= {1'b0, source_height_latched}) begin
                            vertical_phase <= vertical_after_first[15:0] - source_height_latched;
                            if (write_buf_sel)
                                line_repeat_count_1 <= 2'd2;
                            else
                                line_repeat_count_0 <= 2'd2;
                        end else begin
                            vertical_phase <= vertical_after_first[15:0];
                            if (write_buf_sel)
                                line_repeat_count_1 <= 2'd1;
                            else
                                line_repeat_count_0 <= 2'd1;
                        end
                    end else begin
                        vertical_phase <= vertical_sum[15:0];
                        if (write_buf_sel)
                            line_repeat_count_1 <= 2'd0;
                        else
                            line_repeat_count_0 <= 2'd0;
                    end
                    line_ready[write_buf_sel] <= 1'b1;
                end else begin
                    source_pixel_x <= source_pixel_x + 10'd1;
                end
            end
        end
    end
end

endmodule
