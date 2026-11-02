
module sd_card_bmp #(
    parameter integer CLK_FREQ_HZ       = 100_000_000,
    parameter [31:0]  SCAN_START_SECTOR = 32'd0,
    parameter [31:0]  SCAN_MAX_SECTOR   = 32'd131071,
    parameter [2:0]   SCAN_TARGET_COUNT = 3'd4
)(
    input                       clk,
    input                       rst,
    input                       key_next_toggle,
    input                       host_next_toggle,
    input                       host_auto_toggle,
    input                       key_auto,
    input                       host_upload_start,
    input                       host_upload_done,
    input                       host_pixel_valid,
    input  [31:0]                host_pixel_data,
    output [3:0]                state_code,
    input  [15:0]               bmp_width,
    input  [15:0]               bmp_height,
    input                       write_fifo_almost_full,
    output reg                  display_valid,

    input                       write_finish_toggle,
    input                       fade_swap_toggle,
    input                       fade_done_toggle,
    output reg                  fade_start_toggle,
    output reg [1:0]            write_buf_idx,
    output reg [1:0]            disp_buf_idx,
    output reg [1:0]            display_image_idx,

    output                      write_req,
    input                       write_req_ack,
    output                      write_en,
    output [31:0]               write_data,
    input      [10:0]           audio_fifo_wr_level,
    input                       audio_fifo_wr_full,
    output                      audio_fifo_wr_en,
    output [16:0]               audio_fifo_wr_data,
    output                      audio_generation,
    output                      SD_nCS,
    output                      SD_DCLK,
    output                      SD_MOSI,
    input                       SD_MISO
);

wire key_next_press;
wire key_auto_press;
wire host_auto_press;
reg [2:0] key_next_toggle_sync;
reg [2:0] host_next_toggle_sync;
reg [2:0] host_auto_toggle_sync;

wire             bmp_sd_sec_read;
wire [31:0]      bmp_sd_sec_read_addr;
wire [7:0]       bmp_sd_sec_read_data;
wire             bmp_sd_sec_read_data_valid;
wire             bmp_sd_sec_read_end;
wire             wav_sd_sec_read;
wire [31:0]      wav_sd_sec_read_addr;
wire [7:0]       wav_sd_sec_read_data;
wire             wav_sd_sec_read_data_valid;
wire             wav_sd_sec_read_end;
wire             sd_sec_read;
wire [31:0]      sd_sec_read_addr;
wire             sd_raw_sec_read_data_valid;
wire             sd_raw_sec_read_end;
wire [7:0]       sd_raw_sec_read_data;
reg              sd_read_owner_valid;
reg              sd_read_owner_audio;
wire             bmp_data_wr_en;
wire [23:0]      bmp_data;
wire             sd_init_done;
wire             bmp_ready;
wire             bmp_write_req;
wire             bmp_write_en;
wire [31:0]      bmp_write_data;
wire             scan_done;
wire             scan_found_valid;
wire [31:0]      scan_found_sector;
wire [2:0]       scan_found_total;
wire             music_found;
wire [31:0]      music_start_sector;
wire [6:0]       music_data_offset;
wire [31:0]      music_data_size;
wire             voice_found;
wire [31:0]      voice_start_sector;
wire [6:0]       voice_data_offset;
wire [31:0]      voice_data_size;

reg              scan_start_pulse;
reg              load_start_pulse;
reg [31:0]       load_sector;
reg              scan_kicked;
reg              first_image_committed;
reg              auto_play_en;
reg [31:0]       auto_cnt;
reg              auto_req_pending;
reg [2:0]        img_found_count;
reg [1:0]        img_idx;              // 当前真正显示中的图片编号
reg [1:0]        load_idx;             // 当前正在写入的图片编号
reg [1:0]        pending_buf_idx;      // 当前正在写入的目标缓冲区
reg [31:0]       img_sector0;
reg [31:0]       img_sector1;
reg [31:0]       img_sector2;
reg [31:0]       img_sector3;
reg              next_req_pending;
reg              load_busy;
reg              transition_wait;

// bmp_ready 先表示“源文件读取/送 FIFO 完成”；真正切显示要等 write_finish_toggle 同步后
reg              source_done_seen;
reg              write_finish_seen;
reg              host_upload_pending;
reg              host_write_active;
reg              host_write_req;
reg              host_upload_done_seen;

// 同步 mem_clk 域的 write_finish_toggle
reg [2:0]        wrfin_tgl_sync;
reg [2:0]        fade_swap_sync;
wire             fade_swap_pulse;
wire             write_finish_pulse;
reg [2:0]        fade_done_sync;
wire              fade_done_pulse;
wire [3:0]        bmp_state_code;

wire auto_tick;
wire [1:0] next_from_current;

assign state_code = scan_done && (img_found_count == 3'd0) && !display_valid
                  ? 4'd5 : bmp_state_code;
assign write_req  = host_write_active ? host_write_req : bmp_write_req;
assign write_en   = host_write_active
                  ? (host_pixel_valid && !write_fifo_almost_full)
                  : bmp_write_en;
assign write_data = host_write_active
                  ? host_pixel_data
                  : bmp_write_data;
assign sd_sec_read = sd_read_owner_valid
                   ? 1'b1
                   : (wav_sd_sec_read || bmp_sd_sec_read);
assign sd_sec_read_addr = sd_read_owner_valid
                        ? (sd_read_owner_audio
                           ? wav_sd_sec_read_addr : bmp_sd_sec_read_addr)
                        : (wav_sd_sec_read
                           ? wav_sd_sec_read_addr : bmp_sd_sec_read_addr);
assign bmp_sd_sec_read_data = sd_raw_sec_read_data;
assign bmp_sd_sec_read_data_valid = sd_raw_sec_read_data_valid &&
                                    sd_read_owner_valid &&
                                    !sd_read_owner_audio;
assign bmp_sd_sec_read_end = sd_raw_sec_read_end &&
                             sd_read_owner_valid &&
                             !sd_read_owner_audio;
assign wav_sd_sec_read_data = sd_raw_sec_read_data;
assign wav_sd_sec_read_data_valid = sd_raw_sec_read_data_valid &&
                                    sd_read_owner_valid &&
                                    sd_read_owner_audio;
assign wav_sd_sec_read_end = sd_raw_sec_read_end &&
                             sd_read_owner_valid &&
                             sd_read_owner_audio;
assign auto_tick  = (auto_cnt >= (CLK_FREQ_HZ - 1));
assign next_from_current = next_index_limited(img_idx, img_found_count);
assign write_finish_pulse = wrfin_tgl_sync[2] ^ wrfin_tgl_sync[1];
assign fade_swap_pulse = fade_swap_sync[2] ^ fade_swap_sync[1];
assign fade_done_pulse = fade_done_sync[2] ^ fade_done_sync[1];
assign key_next_press = (key_next_toggle_sync[2] ^ key_next_toggle_sync[1]) |
                        (host_next_toggle_sync[2] ^ host_next_toggle_sync[1]);
assign host_auto_press = host_auto_toggle_sync[2] ^ host_auto_toggle_sync[1];

always @(posedge clk or posedge rst) begin
    if (rst)
        key_next_toggle_sync <= 3'b000;
    else
        key_next_toggle_sync <= {key_next_toggle_sync[1:0], key_next_toggle};
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        sd_read_owner_valid <= 1'b0;
        sd_read_owner_audio <= 1'b0;
    end else if (sd_raw_sec_read_end) begin
        sd_read_owner_valid <= 1'b0;
    end else if (!sd_read_owner_valid && sd_sec_read) begin
        sd_read_owner_valid <= 1'b1;
        sd_read_owner_audio <= wav_sd_sec_read;
    end
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        host_next_toggle_sync <= 3'b000;
        host_auto_toggle_sync <= 3'b000;
    end else begin
        host_next_toggle_sync <= {host_next_toggle_sync[1:0], host_next_toggle};
        host_auto_toggle_sync <= {host_auto_toggle_sync[1:0], host_auto_toggle};
    end
end

key_press_debounce #(
    .CLK_FREQ_HZ (CLK_FREQ_HZ),
    .DEBOUNCE_MS (20)
) u_key_auto (
    .clk        (clk),
    .rst        (rst),
    .button_in  (key_auto),
    .press_pulse(key_auto_press)
);

function [1:0] next_index_limited;
    input [1:0] cur;
    input [2:0] count;
    begin
        case (count)
            3'd0: next_index_limited = 2'd0;
            3'd1: next_index_limited = 2'd0;
            3'd2: next_index_limited = (cur == 2'd1) ? 2'd0 : (cur + 2'd1);
            3'd3: next_index_limited = (cur == 2'd2) ? 2'd0 : (cur + 2'd1);
            default: next_index_limited = (cur == 2'd3) ? 2'd0 : (cur + 2'd1);
        endcase
    end
endfunction

function [31:0] sector_lut;
    input [1:0] idx;
    begin
        case (idx)
            2'd0: sector_lut = img_sector0;
            2'd1: sector_lut = img_sector1;
            2'd2: sector_lut = img_sector2;
            2'd3: sector_lut = img_sector3;
            default: sector_lut = img_sector0;
        endcase
    end
endfunction

function [1:0] next_buf_lut;
    input [1:0] cur_disp_buf;
    input       valid_now;
    begin
        if (!valid_now)
            next_buf_lut = 2'd0;                 // 首图固定写 buffer0
        else if (cur_disp_buf == 2'd0)
            next_buf_lut = 2'd1;
        else
            next_buf_lut = 2'd0;
    end
endfunction

always @(posedge clk or posedge rst) begin
    if (rst) begin
        wrfin_tgl_sync        <= 3'b000;
        fade_swap_sync        <= 3'b000;
        fade_done_sync        <= 3'b000;
        fade_start_toggle     <= 1'b0;
        scan_start_pulse      <= 1'b0;
        load_start_pulse      <= 1'b0;
        load_sector           <= 32'd0;
        scan_kicked           <= 1'b0;
        first_image_committed <= 1'b0;
        auto_play_en          <= 1'b0;
        auto_cnt              <= 32'd0;
        auto_req_pending      <= 1'b0;
        img_found_count       <= 3'd0;
        img_idx               <= 2'd0;
        load_idx              <= 2'd0;
        pending_buf_idx       <= 2'd0;
        write_buf_idx         <= 2'd0;
        disp_buf_idx          <= 2'd0;
        display_image_idx     <= 2'd0;
        img_sector0           <= 32'd0;
        img_sector1           <= 32'd0;
        img_sector2           <= 32'd0;
        img_sector3           <= 32'd0;
        next_req_pending      <= 1'b0;
        load_busy             <= 1'b0;
        transition_wait       <= 1'b0;
        source_done_seen      <= 1'b0;
        write_finish_seen     <= 1'b0;
        host_upload_pending   <= 1'b0;
        host_write_active     <= 1'b0;
        host_write_req        <= 1'b0;
        host_upload_done_seen <= 1'b0;
        display_valid         <= 1'b0;
    end else begin
        wrfin_tgl_sync   <= {wrfin_tgl_sync[1:0], write_finish_toggle};
        fade_swap_sync   <= {fade_swap_sync[1:0], fade_swap_toggle};
        fade_done_sync   <= {fade_done_sync[1:0], fade_done_toggle};
        scan_start_pulse <= 1'b0;
        load_start_pulse <= 1'b0;

        if (!sd_init_done) begin
            fade_swap_sync        <= 3'b000;
            fade_done_sync        <= 3'b000;
            fade_start_toggle     <= 1'b0;
            scan_kicked           <= 1'b0;
            first_image_committed <= 1'b0;
            auto_play_en          <= 1'b0;
            auto_cnt              <= 32'd0;
            auto_req_pending      <= 1'b0;
            img_found_count       <= 3'd0;
            img_idx               <= 2'd0;
            load_idx              <= 2'd0;
            pending_buf_idx       <= 2'd0;
            write_buf_idx         <= 2'd0;
            disp_buf_idx          <= 2'd0;
            display_image_idx     <= 2'd0;
            img_sector0           <= 32'd0;
            img_sector1           <= 32'd0;
            img_sector2           <= 32'd0;
            img_sector3           <= 32'd0;
            next_req_pending      <= 1'b0;
            load_busy             <= 1'b0;
            transition_wait       <= 1'b0;
            source_done_seen      <= 1'b0;
            write_finish_seen     <= 1'b0;
            host_upload_pending   <= 1'b0;
            host_write_active     <= 1'b0;
            host_write_req        <= 1'b0;
            host_upload_done_seen <= 1'b0;
            display_valid         <= 1'b0;
        end else begin
            if (host_upload_start) begin
                host_upload_pending <= 1'b1;
                auto_play_en <= 1'b0;
                auto_req_pending <= 1'b0;
                auto_cnt <= 32'd0;
            end

            if (host_write_active && host_write_req && write_req_ack)
                host_write_req <= 1'b0;

            // 扫描阶段缓存前 4 张图的起始 sector
            if (scan_found_valid) begin
                case (img_found_count)
                    3'd0: img_sector0 <= scan_found_sector;
                    3'd1: img_sector1 <= scan_found_sector;
                    3'd2: img_sector2 <= scan_found_sector;
                    3'd3: img_sector3 <= scan_found_sector;
                    default: ;
                endcase

                if (img_found_count < 3'd4)
                    img_found_count <= img_found_count + 3'd1;
            end

            // 记住 bmp_read 已经把源图送完 FIFO，但还不能切显示，得等整帧写完
            if (load_busy && !host_write_active && bmp_ready)
                source_done_seen <= 1'b1;

            if (load_busy && host_upload_done)
                host_upload_done_seen <= 1'b1;

            if (load_busy && write_finish_pulse)
                write_finish_seen <= 1'b1;

            // 缩放帧可能先于源 BMP 读取结束，先锁存写完事件再等待源文件完成。
            if (load_busy && (source_done_seen || host_upload_done_seen) &&
                (write_finish_pulse || write_finish_seen) && !transition_wait) begin
                host_write_active <= 1'b0;
                host_write_req <= 1'b0;
                if (display_valid) begin
                    transition_wait  <= 1'b1;
                    fade_start_toggle <= ~fade_start_toggle;
                end else begin
                    load_busy             <= 1'b0;
                    transition_wait      <= 1'b0;
                    source_done_seen      <= 1'b0;
                    write_finish_seen     <= 1'b0;
                    host_upload_done_seen <= 1'b0;
                    disp_buf_idx          <= pending_buf_idx;
                    img_idx               <= load_idx;
                    display_image_idx     <= load_idx;
                    display_valid         <= 1'b1;
                    first_image_committed <= 1'b1;
                end
            end

            if (load_busy && transition_wait && fade_swap_pulse) begin
                disp_buf_idx <= pending_buf_idx;
                display_image_idx <= load_idx;
            end

            if (load_busy && transition_wait && fade_done_pulse) begin
                transition_wait      <= 1'b0;
                load_busy             <= 1'b0;
                source_done_seen      <= 1'b0;
                write_finish_seen     <= 1'b0;
                host_upload_done_seen <= 1'b0;
                disp_buf_idx          <= pending_buf_idx;
                img_idx               <= load_idx;
                display_image_idx     <= load_idx;
                display_valid         <= 1'b1;
                first_image_committed <= 1'b1;
            end

            // 上电后自动发起一次“扫描前 4 张 BMP”
            if (!scan_kicked && bmp_ready) begin
                scan_start_pulse      <= 1'b1;
                scan_kicked           <= 1'b1;
                first_image_committed <= 1'b0;
                auto_play_en          <= 1'b0;
                auto_cnt              <= 32'd0;
                img_found_count       <= 3'd0;
                img_idx               <= 2'd0;
                load_idx              <= 2'd0;
                pending_buf_idx       <= 2'd0;
                write_buf_idx         <= 2'd0;
                disp_buf_idx          <= 2'd0;
                next_req_pending      <= 1'b0;
                display_valid         <= 1'b0;
                load_busy             <= 1'b0;
                transition_wait      <= 1'b0;
                source_done_seen      <= 1'b0;
            end else begin
                // 忙的时候也只记 1 次“下一张”请求，不会累积成连跳两张
                if (key_next_press && scan_done && (img_found_count > 3'd0))
                    next_req_pending <= 1'b1;

                // 自动播放开/关
                if (!host_upload_start &&
                    (key_auto_press || host_auto_press) && scan_done &&
                    (img_found_count > 3'd1)) begin
                    auto_play_en <= ~auto_play_en;
                    auto_cnt     <= 32'd0;
                    auto_req_pending <= 1'b0;
                end

                // 到达轮播间隔后保持请求，直到 BMP 读取器空闲并启动下一张加载
                if (scan_done && auto_play_en && !key_auto_press && !host_auto_press &&
                    display_valid && !load_busy && first_image_committed &&
                    (img_found_count > 3'd1)) begin
                    if (auto_req_pending) begin
                        auto_cnt <= CLK_FREQ_HZ - 1;
                    end else if (auto_tick) begin
                        auto_cnt         <= CLK_FREQ_HZ - 1;
                        auto_req_pending <= 1'b1;
                    end else begin
                        auto_cnt <= auto_cnt + 32'd1;
                    end
                end else begin
                    auto_cnt <= 32'd0;
                end

                // 上位机图片先写入当前显示缓冲区之外的另一块缓存。
                if (host_upload_pending && scan_done && bmp_ready && display_valid &&
                    !load_busy && !transition_wait && !host_write_active) begin
                    host_upload_pending   <= 1'b0;
                    host_write_active     <= 1'b1;
                    host_write_req        <= 1'b1;
                    host_upload_done_seen <= 1'b0;
                    load_idx              <= img_idx;
                    pending_buf_idx       <= next_buf_lut(disp_buf_idx, display_valid);
                    write_buf_idx         <= next_buf_lut(disp_buf_idx, display_valid);
                    load_busy             <= 1'b1;
                    source_done_seen      <= 1'b0;
                    write_finish_seen     <= 1'b0;
                    auto_cnt              <= 32'd0;
                    auto_req_pending      <= 1'b0;
                    next_req_pending      <= 1'b0;
                end
                // 首图自动加载到 buffer0
                else if (!host_upload_pending && !host_write_active &&
                         scan_done && !first_image_committed && bmp_ready &&
                         !load_busy && (img_found_count != 3'd0)) begin
                    load_idx         <= 2'd0;
                    load_sector      <= img_sector0;
                    pending_buf_idx  <= 2'd0;
                    write_buf_idx    <= 2'd0;
                    load_start_pulse <= 1'b1;
                    load_busy        <= 1'b1;
                    source_done_seen <= 1'b0;
                    write_finish_seen <= 1'b0;
                    next_req_pending <= 1'b0;
                    auto_cnt         <= 32'd0;
                end
                // 手动下一张优先：写到“非当前显示”的另一块 buffer
                else if (!host_upload_pending && !host_write_active &&
                         scan_done && bmp_ready && display_valid && !load_busy &&
                         next_req_pending && (img_found_count != 3'd0)) begin
                    load_idx         <= next_from_current;
                    load_sector      <= sector_lut(next_from_current);
                    pending_buf_idx  <= next_buf_lut(disp_buf_idx, display_valid);
                    write_buf_idx    <= next_buf_lut(disp_buf_idx, display_valid);
                    load_start_pulse <= 1'b1;
                    load_busy        <= 1'b1;
                    source_done_seen <= 1'b0;
                    write_finish_seen <= 1'b0;
                    next_req_pending <= 1'b0;
                    auto_req_pending <= 1'b0;
                    auto_cnt         <= 32'd0;
                end
                // 自动播放下一张：同样写到“非当前显示”的另一块 buffer
                else if (!host_upload_pending && !host_write_active &&
                         scan_done && bmp_ready && display_valid && !load_busy &&
                         auto_play_en && !key_auto_press &&
                         (auto_req_pending || auto_tick) && (img_found_count > 3'd1)) begin
                    load_idx         <= next_from_current;
                    load_sector      <= sector_lut(next_from_current);
                    pending_buf_idx  <= next_buf_lut(disp_buf_idx, display_valid);
                    write_buf_idx    <= next_buf_lut(disp_buf_idx, display_valid);
                    load_start_pulse <= 1'b1;
                    load_busy        <= 1'b1;
                    source_done_seen <= 1'b0;
                    write_finish_seen <= 1'b0;
                    auto_req_pending <= 1'b0;
                    auto_cnt         <= 32'd0;
                end
            end
        end
    end
end

bmp_read bmp_read_m0(
    .clk                    (clk),
    .rst                    (rst),
    .ready                  (bmp_ready),

    .scan_start             (scan_start_pulse),
    .scan_start_sector      (SCAN_START_SECTOR),
    .scan_max_sector        (SCAN_MAX_SECTOR),
    .scan_target_count      (SCAN_TARGET_COUNT),
    .scan_done              (scan_done),
    .scan_found_valid       (scan_found_valid),
    .scan_found_sector      (scan_found_sector),
    .scan_found_total       (scan_found_total),
    .music_found            (music_found),
    .music_start_sector     (music_start_sector),
    .music_data_offset      (music_data_offset),
    .music_data_size        (music_data_size),
    .voice_found            (voice_found),
    .voice_start_sector     (voice_start_sector),
    .voice_data_offset      (voice_data_offset),
    .voice_data_size        (voice_data_size),

    .load_start             (load_start_pulse),
    .load_sector            (load_sector),

    .sd_init_done           (sd_init_done),
    .state_code             (bmp_state_code),
    .bmp_width              (bmp_width),
    .bmp_height             (bmp_height),
    .write_fifo_almost_full (write_fifo_almost_full),
    .write_req              (bmp_write_req),
    .write_req_ack          (host_write_active ? 1'b0 : write_req_ack),
    .sd_sec_read            (bmp_sd_sec_read),
    .sd_sec_read_addr       (bmp_sd_sec_read_addr),
    .sd_sec_read_data       (bmp_sd_sec_read_data),
    .sd_sec_read_data_valid (bmp_sd_sec_read_data_valid),
    .sd_sec_read_end        (bmp_sd_sec_read_end),
    .bmp_data_wr_en         (bmp_write_en),
    .bmp_data               (bmp_data)
);

assign bmp_write_data = {bmp_data[23:16], bmp_data[15:8], bmp_data[7:0], 8'b0};

wav_audio_reader wav_audio_reader_m0(
    .clk                    (clk),
    .rst                    (rst),
    .sd_init_done           (sd_init_done),
    .scan_done              (scan_done),
    .display_valid          (display_valid),
    .display_image_idx      (display_image_idx),
    .music_found            (music_found),
    .music_start_sector     (music_start_sector),
    .music_data_offset      (music_data_offset),
    .music_data_size        (music_data_size),
    .voice_found            (voice_found),
    .voice_start_sector     (voice_start_sector),
    .voice_data_offset      (voice_data_offset),
    .voice_data_size        (voice_data_size),
    .sd_sec_read_data_valid (wav_sd_sec_read_data_valid),
    .sd_sec_read_data       (wav_sd_sec_read_data),
    .sd_sec_read_end        (wav_sd_sec_read_end),
    .fifo_wr_level          (audio_fifo_wr_level),
    .fifo_wr_full           (audio_fifo_wr_full),
    .sd_sec_read            (wav_sd_sec_read),
    .sd_sec_read_addr       (wav_sd_sec_read_addr),
    .fifo_wr_en             (audio_fifo_wr_en),
    .fifo_wr_data           (audio_fifo_wr_data),
    .generation             (audio_generation)
);

sd_card_top #(
    .SPI_HIGH_SPEED_DIV (16'd2)
) sd_card_top_m0(
    .clk                    (clk),
    .rst                    (rst),
    .SD_nCS                 (SD_nCS),
    .SD_DCLK                (SD_DCLK),
    .SD_MOSI                (SD_MOSI),
    .SD_MISO                (SD_MISO),
    .sd_init_done           (sd_init_done),
    .sd_sec_read            (sd_sec_read),
    .sd_sec_read_addr       (sd_sec_read_addr),
    .sd_sec_read_data       (sd_raw_sec_read_data),
    .sd_sec_read_data_valid (sd_raw_sec_read_data_valid),
    .sd_sec_read_end        (sd_raw_sec_read_end),
    .sd_sec_write           (1'b0),
    .sd_sec_write_addr      (32'd0),
    .sd_sec_write_data      (),
    .sd_sec_write_data_req  (),
    .sd_sec_write_end       ()
);

endmodule

module key_press_debounce #(
    parameter integer CLK_FREQ_HZ = 100_000_000,
    parameter integer DEBOUNCE_MS = 20
)(
    input  wire clk,
    input  wire rst,
    input  wire button_in,    // 默认：松开=1，按下=0
    output reg  press_pulse
);

localparam integer DEBOUNCE_CYCLES = (CLK_FREQ_HZ / 1000) * DEBOUNCE_MS;

reg button_sync0;
reg button_sync1;
reg button_stable;
reg [31:0] cnt;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        button_sync0  <= 1'b1;
        button_sync1  <= 1'b1;
        button_stable <= 1'b1;
        cnt           <= 32'd0;
        press_pulse   <= 1'b0;
    end else begin
        button_sync0 <= button_in;
        button_sync1 <= button_sync0;
        press_pulse  <= 1'b0;

        if (button_sync1 == button_stable) begin
            cnt <= 32'd0;
        end else begin
            if (cnt >= DEBOUNCE_CYCLES - 1) begin
                if (button_stable && !button_sync1)
                    press_pulse <= 1'b1;
                button_stable <= button_sync1;
                cnt           <= 32'd0;
            end else begin
                cnt <= cnt + 32'd1;
            end
        end
    end
end

endmodule
