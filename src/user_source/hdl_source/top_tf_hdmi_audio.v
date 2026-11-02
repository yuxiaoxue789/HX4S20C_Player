
module top(
    input                       clk,
    input                       rst_n,
    input                       key1,           // 手动下一张
    input                       key2,           // 自动播放 开/关
    input                       key3,           // 参数调节选择键（短按循环 亮度/对比度/饱和度）
    input                       uart_rx,

    output [5:0]                seg_sel,
    output [7:0]                seg_data,

    // HDMI TMDS
    output                      HDMI_CLK_P,
    output                      HDMI_D2_P,
    output                      HDMI_D1_P,
    output                      HDMI_D0_P,

    // HDMI DDC
    output                      HDMI_DDC_SCL,
    inout                       HDMI_DDC_SDA,

    // TF card SPI
    output                      sd_ncs,
    output                      sd_dclk,
    output                      sd_mosi,
    input                       sd_miso
);

parameter MEM_DATA_BITS = 32;
parameter ADDR_BITS     = 21;
parameter BUSRT_BITS    = 10;
parameter FRAME_PIXELS  = 24'd307200;   // 640*480
parameter BUF0_ADDR     = 24'd0;
parameter BUF1_ADDR     = FRAME_PIXELS;

wire Sdr_init_done;
wire Sdr_init_ref_vld;
wire Sdr_busy;

wire sd_card_clk;
wire ext_mem_clk;
wire ext_mem_clk_sft;
wire video_clk;
wire hdmi_5x_clk;

wire hs;
wire vs;
wire de;

wire [23:0] vout_data_raw;
wire [23:0] vout_data;
wire [23:0] vout_data_overlay;
wire [23:0] vout_data_visualized;
wire        display_valid;
wire [4:0]  fade_level;
wire        fade_start_toggle;
wire        fade_swap_toggle;
wire        fade_done_toggle;
wire        slide_active;
wire [9:0]  slide_offset;
wire        video_frame_start;
reg         video_vs_0_d;
reg  [9:0]  video_pixel_x;
wire [10:0] slide_threshold;
wire        slide_pixel_visible;
wire [11:0] fade_red_product;
wire [11:0] fade_green_product;
wire [11:0] fade_blue_product;

// 显示参数（亮度/对比度/饱和度）调节
wire        adjust_mode;     // 参数调节模式（长按 key2 切换）
wire [1:0]  active_param;    // 当前参数 0=亮度 1=对比度 2=饱和度
wire [7:0]  brightness;
wire [7:0]  contrast;
wire [7:0]  saturation;
wire [23:0] vout_data_pp;    // 经参数处理 + OSD 叠加后的像素
wire        key1_gated;      // 调节模式下被屏蔽的切图信号
wire        key2_gated;      // 调节模式下被屏蔽的自动轮播信号
wire        manual_next_press;
reg         manual_next_toggle;
wire        host_next_toggle;
wire        host_auto_toggle;
wire        host_param_panel_toggle;
wire        host_param_write_toggle;
wire [1:0]  host_param_select_sd;
wire [7:0]  host_param_value_sd;
wire        host_upload_start;
wire        host_upload_done;
wire        host_upload_active;
wire        host_pixel_valid;
wire [31:0] host_pixel_data;
wire        host_packet_busy;
reg  [2:0]  host_param_panel_sync;
reg  [2:0]  host_param_write_sync;
reg  [1:0]  host_param_select_meta;
reg  [1:0]  host_param_select_sync;
reg  [7:0]  host_param_value_meta;
reg  [7:0]  host_param_value_sync;
reg  [1:0]  host_packet_busy_video_sync;
wire        host_key3_press;
wire        host_param_write;
wire        host_uart_text_rx;

wire [3:0]  state_code;
wire [6:0]  seg_data_0;

wire        video_read_req;
wire        video_read_req_ack;
wire        video_read_en;
wire [31:0] video_read_data;

wire        sd_card_write_en;
wire [31:0] sd_card_write_data;
wire        sd_card_write_req;
wire        sd_card_write_req_ack;
wire        frame_write_finish;
wire        frame_write_fifo_almost_full;
reg         frame_write_toggle_mem;

wire [1:0]  write_buf_idx;
wire [1:0]  disp_buf_idx;
wire [1:0]  display_image_idx;

wire App_rd_en;
wire [ADDR_BITS-1:0] App_rd_addr;
wire Sdr_rd_en;
wire [MEM_DATA_BITS-1:0] Sdr_rd_dout;
wire App_wr_en;
wire [ADDR_BITS-1:0] App_wr_addr;
wire [MEM_DATA_BITS-1:0] App_wr_din;
wire [3:0] App_wr_dm;

wire hs_0;
wire vs_0;
wire de_0;

// HDMI 1.4b 音频发射相关
wire        audio_pll_lock;
wire        rst_audio;
wire        audio_mclk;
wire        audio_i2s_bclk;
wire        audio_i2s_lrck;
wire        audio_i2s_dout;
wire        audio_valid;
wire [23:0] audio_left_data;
wire [23:0] audio_right_data;
wire        audio_fifo_wr_en;
wire [16:0] audio_fifo_wr_data;
wire        audio_fifo_wr_full;
wire [10:0] audio_fifo_wr_level;
wire        audio_fifo_rd_en;
wire        audio_fifo_empty;
wire        audio_fifo_rd_valid;
wire [16:0] audio_fifo_rd_data;
wire        audio_generation;
wire        acr_valid;
wire [19:0] acr_cts;
wire [19:0] acr_n;

wire        axis_s_user;
wire        axis_s_valid;
wire        axis_s_last;
wire [23:0] axis_s_data;
wire        axis_s_ready;

wire        edid_trig;
wire        edid_valid;
wire [7:0]  edid_data;

wire [9:0]  tmds_ch0_data;
wire [9:0]  tmds_ch1_data;
wire [9:0]  tmds_ch2_data;
wire [9:0]  tmds_clk_data;

// 统一复位：TF 图像链路 + HDMI 音频链路
wire rst_all;
assign rst_all = ~rst_n;
assign rst_audio = ~rst_n | ~audio_pll_lock;
assign host_key3_press = host_param_panel_sync[2] ^ host_param_panel_sync[1];
assign host_param_write = host_param_write_sync[2] ^ host_param_write_sync[1];
assign host_uart_text_rx = host_packet_busy_video_sync[1] ? 1'b1 : uart_rx;

always @(posedge clk or posedge rst_all) begin
    if (rst_all) begin
        host_param_panel_sync <= 3'b000;
        host_param_write_sync <= 3'b000;
        host_param_select_meta <= 2'b00;
        host_param_select_sync <= 2'b00;
        host_param_value_meta <= 8'd0;
        host_param_value_sync <= 8'd0;
    end else begin
        host_param_panel_sync <= {host_param_panel_sync[1:0], host_param_panel_toggle};
        host_param_write_sync <= {host_param_write_sync[1:0], host_param_write_toggle};
        host_param_select_meta <= host_param_select_sd;
        host_param_select_sync <= host_param_select_meta;
        host_param_value_meta <= host_param_value_sd;
        host_param_value_sync <= host_param_value_meta;
    end
end

always @(posedge video_clk or posedge rst_all) begin
    if (rst_all)
        host_packet_busy_video_sync <= 2'b00;
    else
        host_packet_busy_video_sync <= {host_packet_busy_video_sync[0], host_packet_busy};
end

key_press_debounce #(
    .CLK_FREQ_HZ (50_000_000),
    .DEBOUNCE_MS (20)
) u_manual_next_debounce (
    .clk        (clk),
    .rst        (rst_all),
    .button_in  (key1_gated),
    .press_pulse(manual_next_press)
);

always @(posedge clk or posedge rst_all) begin
    if (rst_all)
        manual_next_toggle <= 1'b0;
    else if (manual_next_press)
        manual_next_toggle <= ~manual_next_toggle;
end

always @(posedge video_clk or posedge rst_all) begin
    if (rst_all)
        video_vs_0_d <= 1'b0;
    else
        video_vs_0_d <= vs_0;
end

assign video_frame_start = video_vs_0_d && !vs_0;
assign slide_threshold = {1'b0, slide_offset} + 11'd1;
assign slide_pixel_visible = !slide_active ||
                             ({1'b0, video_pixel_x} >= slide_threshold);

always @(posedge video_clk or posedge rst_all) begin
    if (rst_all) begin
        video_pixel_x <= 10'd0;
    end else begin
        if (!de)
            video_pixel_x <= 10'd0;
        else
            video_pixel_x <= video_pixel_x + 10'd1;
    end
end

video_frame_fade u_video_frame_fade(
    .I_clk                       (video_clk),
    .I_rst                       (rst_all),
    .I_frame_start               (video_frame_start),
    .I_transition_start_toggle   (fade_start_toggle),
    .I_display_buf_idx           (disp_buf_idx),
    .I_display_image_idx         (display_image_idx),
    .O_buffer_swap_toggle        (fade_swap_toggle),
    .O_transition_done_toggle    (fade_done_toggle),
    .O_level                     (fade_level),
    .O_slide_active              (slide_active),
    .O_slide_offset              (slide_offset)
);

// 保持你原来的 TF / SDRAM / video 时钟
sys_pll sys_pll_m0(
    .refclk     (clk),
    .clk0_out   (sd_card_clk),
    .clk1_out   (ext_mem_clk),
    .clk2_out   (ext_mem_clk_sft),
    .reset      (1'b0)
);

video_pll video_pll_m0(
    .refclk     (clk),
    .clk0_out   (video_clk),
    .clk1_out   (hdmi_5x_clk),
    .reset      (1'b0)
);

// 复用你 I2S->HDMI 工程里的 PLL，只取 12.288MHz 音频主时钟
PLL_HDMI_AUDIO u_audio_pll(
    .refclk     (clk),
    .reset      (1'b0),
    .extlock    (audio_pll_lock),
    .clk0_out   (),
    .clk1_out   (),
    .clk2_out   (audio_mclk)
);

// mem_clk 域把 write_finish 单拍转成 toggle，供 sd_card_clk 域可靠同步
always @(posedge ext_mem_clk or posedge rst_all) begin
    if (rst_all)
        frame_write_toggle_mem <= 1'b0;
    else if (frame_write_finish)
        frame_write_toggle_mem <= ~frame_write_toggle_mem;
end

// ===================== TF 多图扫描与缓存（双缓冲） =====================
sd_card_bmp #(
    .CLK_FREQ_HZ       (100_000_000),
    .SCAN_START_SECTOR (32'd0),
    .SCAN_MAX_SECTOR   (32'd131071),
    .SCAN_TARGET_COUNT (3'd4)
) sd_card_bmp_m0(
    .clk               (sd_card_clk),
    .rst               (rst_all),
    .key_next_toggle   (manual_next_toggle),
    .host_next_toggle  (host_next_toggle),
    .host_auto_toggle  (host_auto_toggle),
    .key_auto          (key2_gated),
    .host_upload_start (host_upload_start),
    .host_upload_done  (host_upload_done),
    .host_pixel_valid  (host_pixel_valid),
    .host_pixel_data   (host_pixel_data),
    .state_code        (state_code),
    .bmp_width         (16'd640),
    .bmp_height        (16'd480),
    .write_fifo_almost_full (frame_write_fifo_almost_full),
    .display_valid     (display_valid),

    .write_finish_toggle(frame_write_toggle_mem),
    .fade_swap_toggle   (fade_swap_toggle),
    .fade_done_toggle  (fade_done_toggle),
    .fade_start_toggle (fade_start_toggle),
    .write_buf_idx     (write_buf_idx),
    .disp_buf_idx      (disp_buf_idx),
    .display_image_idx (display_image_idx),

    .write_req         (sd_card_write_req),
    .write_req_ack     (sd_card_write_req_ack),
    .write_en          (sd_card_write_en),
    .write_data        (sd_card_write_data),
    .audio_fifo_wr_level (audio_fifo_wr_level),
    .audio_fifo_wr_full  (audio_fifo_wr_full),
    .audio_fifo_wr_en    (audio_fifo_wr_en),
    .audio_fifo_wr_data  (audio_fifo_wr_data),
    .audio_generation    (audio_generation),
    .SD_nCS            (sd_ncs),
    .SD_DCLK           (sd_dclk),
    .SD_MOSI           (sd_mosi),
    .SD_MISO           (sd_miso)
);

host_uart_ctrl #(
    .CLK_FREQ_HZ (100_000_000),
    .BAUD_RATE   (115_200)
) u_host_uart_ctrl (
    .clk                 (sd_card_clk),
    .rst                 (rst_all),
    .uart_rx             (uart_rx),
    .next_toggle         (host_next_toggle),
    .auto_toggle         (host_auto_toggle),
    .param_panel_toggle  (host_param_panel_toggle),
    .param_write_toggle  (host_param_write_toggle),
    .param_select        (host_param_select_sd),
    .param_value         (host_param_value_sd),
    .upload_start        (host_upload_start),
    .upload_done         (host_upload_done),
    .upload_active       (host_upload_active),
    .pixel_valid         (host_pixel_valid),
    .pixel_data          (host_pixel_data),
    .packet_busy         (host_packet_busy)
);

seg_decoder seg_decoder_m0(
    .bin_data          (state_code),
    .seg_data          (seg_data_0)
);

seg_scan seg_scan_m0(
    .clk               (clk),
    .rst_n             (rst_n),
    .seg_sel           (seg_sel),
    .seg_data          (seg_data),
    .seg_data_0        ({1'b1,7'b1111_111}),
    .seg_data_1        ({1'b1,7'b1111_111}),
    .seg_data_2        ({1'b1,7'b1111_111}),
    .seg_data_3        ({1'b1,7'b1111_111}),
    .seg_data_4        ({1'b1,7'b1111_111}),
    .seg_data_5        ({1'b1,seg_data_0})
);

// ===================== 显示参数（亮度/对比度/饱和度）调节 =====================
// key3（板上 KEY3）短按循环选择参数：普通->亮度->对比度->饱和度->退出；
// 调节模式下 key1 减小、key2 增大，并屏蔽其原功能（下一张/自动轮播）。
key_param_ctrl key_param_ctrl_m0(
    .clk               (clk),
    .rst               (rst_all),
    .key3              (key3),
    .key1              (key1),
    .key2              (key2),
    .host_key3_press   (host_key3_press),
    .host_param_write  (host_param_write),
    .host_param_select (host_param_select_sync),
    .host_param_value  (host_param_value_sync),
    .adjust_mode       (adjust_mode),
    .active_param      (active_param),
    .brightness        (brightness),
    .contrast          (contrast),
    .saturation        (saturation),
    .key1_gated        (key1_gated),
    .key2_gated        (key2_gated)
);

// ===================== 原图像时序与帧缓存 =====================
video_timing_data video_timing_data_m0(
    .video_clk         (video_clk),
    .rst               (rst_all),
    .read_req          (video_read_req),
    .read_req_ack      (video_read_req_ack),
    .hs                (hs_0),
    .vs                (vs_0),
    .de                (de_0)
);

video_delay video_delay_m0(
    .video_clk         (video_clk),
    .rst               (rst_all),
    .read_en           (video_read_en),
    .read_data         (video_read_data[31:8]),
    .hs                (hs_0),
    .vs                (vs_0),
    .de                (de_0),
    .hs_r              (hs),
    .vs_r              (vs),
    .de_r              (de),
    .vout_data         (vout_data_raw)
);

assign fade_red_product   = vout_data_raw[23:16] * fade_level;
assign fade_green_product = vout_data_raw[15:8]  * fade_level;
assign fade_blue_product  = vout_data_raw[7:0]   * fade_level;
assign vout_data = display_valid
    ? {fade_red_product[11:4], fade_green_product[11:4], fade_blue_product[11:4]}
    : 24'd0;

// 亮度/对比度/饱和度处理 + OSD 参数面板叠加
video_pp video_pp_m0(
    .video_clk         (video_clk),
    .rst               (rst_all),
    .de                (de),
    .vs                (vs),
    .pixel_in          (vout_data),
    .brightness        (brightness),
    .contrast          (contrast),
    .saturation        (saturation),
    .active_param      (active_param),
    .adjust_mode       (adjust_mode),
    .image_visible     (slide_pixel_visible),
    .pixel_out         (vout_data_pp)
);

hdmi_text_overlay #(
    .CLK_FREQ_HZ (25_000_000),
    .BAUD_RATE   (115_200),
    .TEXT_MAX    (32)
) u_hdmi_text_overlay (
    .I_clk      (video_clk),
    .I_rst      (rst_all),
    .I_uart_rx  (host_uart_text_rx),
    .I_de       (de),
    .I_vs       (vs),
    .I_rgb      (vout_data_pp),
    .O_rgb      (vout_data_overlay)
);

hdmi_audio_visualizer u_hdmi_audio_visualizer(
    .I_clk              (video_clk),
    .I_rst              (rst_all),
    .I_de               (de),
    .I_vs               (vs),
    .I_audio_valid      (audio_valid),
    .I_audio_left_data  (audio_left_data),
    .I_audio_right_data (audio_right_data),
    .I_rgb              (vout_data_overlay),
    .O_rgb              (vout_data_visualized)
);

frame_read_write #(
    .WRITE_V_FLIP     (1),
    .FRAME_WIDTH      (640),
    .FRAME_HEIGHT     (480)
) frame_read_write_m0(
    .mem_clk           (ext_mem_clk),
    .rst               (rst_all),
    .Sdr_init_done     (Sdr_init_done),
    .Sdr_init_ref_vld  (Sdr_init_ref_vld),
    .Sdr_busy          (Sdr_busy),

    .App_rd_en         (App_rd_en),
    .App_rd_addr       (App_rd_addr),
    .Sdr_rd_en         (Sdr_rd_en),
    .Sdr_rd_dout       (Sdr_rd_dout),

    .read_clk          (video_clk),
    .read_req          (video_read_req),
    .read_req_ack      (video_read_req_ack),
    .read_finish       (),
    .read_addr_0       (BUF0_ADDR),
    .read_addr_1       (BUF1_ADDR),
    .read_addr_2       (24'd0),
    .read_addr_3       (24'd0),
    .read_addr_index   (disp_buf_idx),
    .read_len          (FRAME_PIXELS),
    .read_en           (video_read_en),
    .read_data         (video_read_data),

    .App_wr_en         (App_wr_en),
    .App_wr_addr       (App_wr_addr),
    .App_wr_din        (App_wr_din),
    .App_wr_dm         (App_wr_dm),

    .write_clk         (sd_card_clk),
    .write_req         (sd_card_write_req),
    .write_req_ack     (sd_card_write_req_ack),
    .write_finish      (frame_write_finish),
    .write_fifo_almost_full (frame_write_fifo_almost_full),
    .write_addr_0      (BUF0_ADDR),
    .write_addr_1      (BUF1_ADDR),
    .write_addr_2      (24'd0),
    .write_addr_3      (24'd0),
    .write_addr_index  (write_buf_idx),
    .write_len         (FRAME_PIXELS),
    .write_en          (sd_card_write_en),
    .write_data        (sd_card_write_data)
);

sdram U3(
    .Clk               (ext_mem_clk),
    .Clk_sft           (ext_mem_clk_sft),
    .Rst               (rst_all),
    .Sdr_init_done     (Sdr_init_done),
    .Sdr_init_ref_vld  (Sdr_init_ref_vld),
    .Sdr_busy          (Sdr_busy),
    .App_wr_en         (App_wr_en),
    .App_wr_addr       (App_wr_addr),
    .App_wr_dm         (App_wr_dm),
    .App_wr_din        (App_wr_din),
    .App_rd_en         (App_rd_en),
    .App_rd_addr       (App_rd_addr),
    .Sdr_rd_en         (Sdr_rd_en),
    .Sdr_rd_dout       (Sdr_rd_dout)
);

audio_sample_async_fifo #(
    .ADDR_WIDTH (10)
) u_audio_sample_async_fifo (
    .wr_clk   (sd_card_clk),
    .rd_clk   (audio_mclk),
    .rst      (rst_all),
    .wr_en    (audio_fifo_wr_en),
    .wr_data  (audio_fifo_wr_data),
    .wr_full  (audio_fifo_wr_full),
    .wr_level (audio_fifo_wr_level),
    .rd_en    (audio_fifo_rd_en),
    .rd_empty (audio_fifo_empty),
    .rd_valid (audio_fifo_rd_valid),
    .rd_data  (audio_fifo_rd_data)
);

// ===================== 音频：从 TF 卡读取 WAV 并经 HDMI 输出 =====================
hdmi_audio_pcm_i2s_64fs u_hdmi_audio_pcm_i2s_64fs (
    .I_mclk        (audio_mclk),
    .I_rst         (rst_audio),
    .I_enable      (display_valid),
    .I_fifo_data   (audio_fifo_rd_data),
    .I_fifo_valid  (audio_fifo_rd_valid),
    .I_fifo_empty  (audio_fifo_empty),
    .I_generation  (audio_generation),
    .O_fifo_rd_en  (audio_fifo_rd_en),
    .O_i2s_BCLK    (audio_i2s_bclk),
    .O_i2s_LRCK    (audio_i2s_lrck),
    .O_i2s_DOUT    (audio_i2s_dout)
);

I2S_receiver u_I2S_receiver(
    .I_clk              (video_clk),
    .I_rst              (rst_audio),
    .I_i2s_BCLK         (audio_i2s_bclk),
    .I_i2s_LRCK         (audio_i2s_lrck),
    .I_i2s_DOUT         (audio_i2s_dout),
    .O_audio_valid      (audio_valid),
    .O_audio_left_data  (audio_left_data),
    .O_audio_right_data (audio_right_data)
);

audio_arc_calculate #(
    .ACR_N         (6144)
) u_audio_arc_calculate (
    .I_clk         (video_clk),
    .I_rst         (rst_audio),
    .I_audio_valid (audio_valid),
    .O_acr_valid   (acr_valid),
    .O_acr_cts     (acr_cts),
    .O_acr_n       (acr_n)
);

// ===================== RGB/DE 转 AXIS 视频 =====================
video_rgb_to_axis_640x480 u_video_rgb_to_axis_640x480(
    .I_clk         (video_clk),
    .I_rst         (rst_all),
    .I_vs          (vs),
    .I_de          (de),
    .I_rgb         (vout_data_visualized),
    .O_video_user  (axis_s_user),
    .O_video_valid (axis_s_valid),
    .O_video_last  (axis_s_last),
    .O_video_data  (axis_s_data)
);

// 上电后自动打一拍，触发一次 EDID 读取
startup_pulse #(
    .CNT_MAX(20'd100000)
) u_startup_pulse (
    .I_clk   (video_clk),
    .I_rst   (rst_all),
    .O_pulse (edid_trig)
);

// ===================== 带音频的 HDMI 1.4b 发射 =====================
hdmi_1_4b_transmitter_core_wrapper #(
    .DEVICE                 ( "EG"       ),
    .HTOTAL                 ( 800        ),
    .HSA                    ( 96         ),
    .HFP                    ( 16         ),
    .HBP                    ( 48         ),
    .HACTIVE                ( 640        ),
    .VTOTAL                 ( 525        ),
    .VSA                    ( 2          ),
    .VFP                    ( 10         ),
    .VBP                    ( 33         ),
    .VACTIVE                ( 480        ),
    .VIDEO_VIC              ( 1          ),
    .VIDEO_TPG              ( "Disable"  ),
    .VIDEO_FORMAT           ( "RGB"      ),
    .AUDIO_SAMPLE_RATE      ( "48K"      ),
    .IIC_SCL_DIV            ( 250        )
) u_hdmi_1_4b_transmitter_core_wrapper(
    .I_pixel_clk        (video_clk),
    .I_rst              (rst_all),
    .I_edid_read_trig   (edid_trig),
    .O_edid_read_valid  (edid_valid),
    .O_edid_read_data   (edid_data),

    .I_axis_s_user      (axis_s_user),
    .I_axis_s_valid     (axis_s_valid),
    .I_axis_s_last      (axis_s_last),
    .I_axis_s_data      (axis_s_data),
    .O_axis_s_ready     (axis_s_ready),

    .I_audio_valid      (audio_valid),
    .I_audio_left_data  (audio_left_data),
    .I_audio_right_data (audio_right_data),
    .I_acr_valid        (acr_valid),
    .I_acr_cts          (acr_cts),
    .I_acr_n            (acr_n),

    .O_video_locked     (),
    .O_ddc_scl          (HDMI_DDC_SCL),
    .IO_ddc_sda         (HDMI_DDC_SDA),

    .O_ch0_tmds_data    (tmds_ch0_data),
    .O_ch1_tmds_data    (tmds_ch1_data),
    .O_ch2_tmds_data    (tmds_ch2_data),
    .O_clk_tmds_data    (tmds_clk_data)
);

hdmi_phy_wrapper #(
    .DEVICE ( "EG" )
) u_hdmi2phy_wrapper(
    .I_pixel_clk        (video_clk),
    .I_serial_clk       (hdmi_5x_clk),
    .I_rst              (rst_all),
    .I_tmds_channel_0   (tmds_ch0_data),
    .I_tmds_channel_1   (tmds_ch1_data),
    .I_tmds_channel_2   (tmds_ch2_data),
    .I_tmds_channel_clk (tmds_clk_data),
    .O_tmds_ch0_p       (HDMI_D0_P),
    .O_tmds_ch1_p       (HDMI_D1_P),
    .O_tmds_ch2_p       (HDMI_D2_P),
    .O_tmds_clk_p       (HDMI_CLK_P)
);

endmodule
