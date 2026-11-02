`timescale 1ns/1ps
// =====================================================================
// video_pp : 图像后处理（亮度/对比度/饱和度 + OSD 参数面板叠加）
//
// 1) 对来自 video_scaler 的像素做 亮度/对比度/饱和度 处理（例化 video_adjust）。
// 2) 生成 OSD：调节模式(adjust_mode=1)下，在画面左上角绘制参数面板，
//    每行显示一个参数的 标签 / 彩色进度条 / 数值，当前被选中的参数行高亮。
//
// 输入 de/vs 为 video_scaler 输出的（延迟后）时序信号，本模块为纯组合的
// 像素处理 + 组合 OSD 叠加，不改变 de/vs/hs 的时序，故下游直接沿用原 de/vs/hs。
//
// 跨时钟域：brightness/contrast/saturation/active_param/adjust_mode 来自
// 50MHz 域（key_param_ctrl），本模块在 video_clk 域内做 2 级同步后使用。
// 这些信号变化极慢，多比特同步的一拍毛刺对显示无影响。
// =====================================================================
module video_pp #(
    parameter ACTIVE_W = 640,
    parameter ACTIVE_H = 480
)(
    input  wire       video_clk,
    input  wire       rst,
    input  wire       de,
    input  wire       vs,
    input  wire [23:0] pixel_in,      // RGB888，de 有效
    // 来自 50MHz 域（异步），内部同步
    input  wire [7:0]  brightness,
    input  wire [7:0]  contrast,
    input  wire [7:0]  saturation,
    input  wire [1:0]  active_param,  // 0=亮度 1=对比度 2=饱和度
    input  wire        adjust_mode,
    input  wire        image_visible, // 滑动时裁切图像，OSD 保持显示
    output wire [23:0] pixel_out
);

    // ================= 跨时钟域同步 =================
    reg [7:0] br_s0, br_s1, co_s0, co_s1, sa_s0, sa_s1;
    reg [1:0] ap_s0, ap_s1;
    reg       am_s0, am_s1;
    always @(posedge video_clk or posedge rst) begin
        if (rst) begin
            br_s0 <= 8'd128; br_s1 <= 8'd128;
            co_s0 <= 8'd128; co_s1 <= 8'd128;
            sa_s0 <= 8'd255; sa_s1 <= 8'd255;
            ap_s0 <= 2'd0;   ap_s1 <= 2'd0;
            am_s0 <= 1'b0;   am_s1 <= 1'b0;
        end else begin
            br_s0 <= brightness; br_s1 <= br_s0;
            co_s0 <= contrast;   co_s1 <= co_s0;
            sa_s0 <= saturation; sa_s1 <= sa_s0;
            ap_s0 <= active_param; ap_s1 <= ap_s0;
            am_s0 <= adjust_mode; am_s1 <= am_s0;
        end
    end
    wire [7:0]  brightness_s = br_s1;
    wire [7:0]  contrast_s   = co_s1;
    wire [7:0]  saturation_s = sa_s1;
    wire [1:0]  active_param_s = ap_s1;
    wire        adjust_mode_s  = am_s1;

    // ================= 像素处理 =================
    wire [23:0] adj_px;
    video_adjust u_adj(
        .pixel      (pixel_in),
        .brightness (brightness_s),
        .contrast   (contrast_s),
        .saturation (saturation_s),
        .dout       (adj_px)
    );

    // ================= 坐标计数 =================
    // 注意：640x480 的场同步 vs 是负脉冲（帧同步期间为低，其余为高），
    // 因此用 vs 上升沿（vs && ~vs_d0）作为帧起始来复位 y，与 video_scaler 一致。
    reg [11:0] x, y;
    reg        vs_d0;
    always @(posedge video_clk or posedge rst) begin
        if (rst) begin
            x     <= 12'd0;
            y     <= 12'd0;
            vs_d0 <= 1'b0;
        end else begin
            vs_d0 <= vs;
            if (!de) x <= 12'd0;
            else     x <= x + 12'd1;
            if (vs && ~vs_d0)  y <= 12'd0;                 // vs 上升沿 = 帧起始
            else if (de && x == 12'd639) y <= y + 12'd1;
        end
    end

    // ================= OSD 面板几何 =================
    localparam PX = 12'd8;          // 面板左上角 X
    localparam PY = 12'd8;          // 面板左上角 Y
    localparam PW = 12'd180;        // 面板宽
    localparam PH = 12'd48;         // 面板高（3 行 * 16）
    localparam ROW_H    = 16;
    localparam CHAR_W   = 6;
    localparam LABEL_X  = 4;        // 标签起点
    localparam LABEL_W  = 18;       // 3 字符
    localparam BAR_X0   = 28;       // 进度条起点
    localparam BAR_W    = 120;
    localparam BAR_Y    = 4;
    localparam BAR_H    = 8;
    localparam VAL_X    = 156;      // 数值起点
    localparam VAL_W    = 18;       // 3 数字
    localparam NEUTRAL_X = BAR_X0 + (128 * BAR_W) / 256;  // 128 对应刻度

    wire signed [12:0] dx = $signed({1'b0, x}) - $signed(13'd8);
    wire signed [12:0] dy = $signed({1'b0, y}) - $signed(13'd8);

    wire       in_panel = (dx >= 0) && (dx < PW) && (dy >= 0) && (dy < PH);
    wire [1:0] row      = dy[5:4];      // 0..2
    wire [3:0] ly       = dy[3:0];      // 行内 0..15
    wire [11:0] lx      = dx[11:0];

    // ---- 当前行参数值 ----
    reg [7:0] row_value;
    always @(*) begin
        case (row)
            2'd0: row_value = brightness_s;
            2'd1: row_value = contrast_s;
            2'd2: row_value = saturation_s;
            default: row_value = 8'd0;
        endcase
    end

    // ================= 5x7 点阵字库（本工程所需字符） =================
    // 每字符 7 行 x 5 列，打包为 35bit，MSB 为左上像素。
    function [4:0] glyph_row(input [7:0] ch, input [2:0] rowidx);
        reg [34:0] g;
        begin
            if (rowidx >= 3'd7) begin
                glyph_row = 5'd0;
            end else begin
                case (ch)
                    " ": g = 35'd0;
                    "0": g = 35'b01110_10001_10011_10101_11001_10001_01110;
                    "1": g = 35'b00100_01100_00100_00100_00100_00100_01110;
                    "2": g = 35'b01110_10001_00001_00010_00100_01000_11111;
                    "3": g = 35'b11111_00010_00100_00010_00001_10001_01110;
                    "4": g = 35'b00010_00110_01010_10010_11111_00010_00010;
                    "5": g = 35'b11111_10000_11110_00001_00001_10001_01110;
                    "6": g = 35'b00110_01000_10000_11110_10001_10001_01110;
                    "7": g = 35'b11111_00001_00010_00100_01000_01000_01000;
                    "8": g = 35'b01110_10001_10001_01110_10001_10001_01110;
                    "9": g = 35'b01110_10001_10001_01111_00001_00010_01100;
                    "A": g = 35'b01110_10001_10001_11111_10001_10001_10001;
                    "B": g = 35'b11110_10001_10001_11110_10001_10001_11110;
                    "C": g = 35'b01110_10001_10000_10000_10000_10001_01110;
                    "N": g = 35'b10001_11001_10101_10011_10001_10001_10001;
                    "O": g = 35'b01110_10001_10001_10001_10001_10001_01110;
                    "R": g = 35'b11110_10001_10001_11110_10100_10010_10001;
                    "S": g = 35'b01111_10000_10000_01110_00001_00001_11110;
                    "T": g = 35'b11111_00100_00100_00100_00100_00100_00100;
                    default: g = 35'd0;
                endcase
                glyph_row = g >> ((6 - rowidx) * 5);
            end
        end
    endfunction

    // ---- 标签字符串（3 字符/行）----
    function [7:0] label_char(input [1:0] r, input [1:0] i);
        case (r)
            2'd0: case (i) 2'd0: label_char = "B"; 2'd1: label_char = "R"; 2'd2: label_char = "T"; default: label_char = " "; endcase
            2'd1: case (i) 2'd0: label_char = "C"; 2'd1: label_char = "O"; 2'd2: label_char = "N"; default: label_char = " "; endcase
            2'd2: case (i) 2'd0: label_char = "S"; 2'd1: label_char = "A"; 2'd2: label_char = "T"; default: label_char = " "; endcase
            default: label_char = " ";
        endcase
    endfunction

    // ---- 数值三位十进制 ----
    wire [7:0] hun = row_value / 100;          // 0..2
    wire [7:0] ten = (row_value / 10) % 10;
    wire [7:0] uni = row_value % 10;

    // ---- 标签像素 ----
    wire       label_on  = (lx >= LABEL_X) && (lx < LABEL_X + LABEL_W);
    wire [2:0] label_i   = (lx - LABEL_X) / CHAR_W;      // 0..2
    wire [2:0] label_px  = (lx - LABEL_X) % CHAR_W;      // 0..5
    wire [7:0] lch       = label_char(row, label_i);
    wire [4:0] lrow      = glyph_row(lch, ly[2:0]);
    wire       label_px_on = label_on && (label_px < 3'd5) && lrow[4 - label_px];

    // ---- 数值像素 ----
    wire       val_on    = (lx >= VAL_X) && (lx < VAL_X + VAL_W);
    wire [2:0] val_i     = (lx - VAL_X) / CHAR_W;
    wire [2:0] val_px    = (lx - VAL_X) % CHAR_W;
    wire [7:0] vch       = (val_i == 0) ? ("0" + hun) :
                           (val_i == 1) ? ("0" + ten) : ("0" + uni);
    wire [4:0] vrow      = glyph_row(vch, ly[2:0]);
    wire       val_px_on = val_on && (val_px < 3'd5) && vrow[4 - val_px];

    // ---- 进度条 ----
    wire       bar_region = (lx >= BAR_X0) && (lx < BAR_X0 + BAR_W) &&
                            (ly >= BAR_Y) && (ly < BAR_Y + BAR_H);
    wire [7:0] fill       = (row_value * BAR_W) >> 8;         // 0..120
    wire       bar_on     = bar_region && (lx < BAR_X0 + fill);
    wire       tick_on    = (row != 2'd2) && (lx == NEUTRAL_X) &&
                            (ly >= BAR_Y) && (ly < BAR_Y + BAR_H);

    // ---- 高亮 / 边框 ----
    wire active      = adjust_mode_s && (row == active_param_s);
    wire act_border  = active && ((lx == 0) || (lx == PW - 1) || (ly == 0) || (ly == ROW_H - 1));
    wire panel_border= (dx == 0) || (dx == PW - 1) || (dy == 0) || (dy == PH - 1);

    // ---- 颜色 ----
    localparam COL_BG      = 24'h101010;  // 面板底
    localparam COL_BORDER  = 24'h808080;  // 面板边框
    localparam COL_EMPTY   = 24'h303030;  // 进度条空槽
    localparam COL_ACT     = 24'h00FF00;  // 选中行边框
    wire [23:0] label_col  = active ? 24'hFFFF00 : 24'hFFFFFF;
    wire [23:0] val_col    = active ? 24'hFFFF00 : 24'hFFFFFF;
    wire [23:0] fill_col   = (row == 2'd0) ? 24'hFFFFFF :
                             (row == 2'd1) ? 24'hFFFF00 : 24'h00FFFF;

    // ---- OSD 叠加 ----
    reg osd_en;
    reg [23:0] osd_rgb;
    always @(*) begin
        osd_en  = 1'b0;
        osd_rgb = 24'h0;
        if (adjust_mode_s && de && in_panel) begin
            osd_en  = 1'b1;
            osd_rgb = COL_BG;
            if (bar_region && !bar_on) osd_rgb = COL_EMPTY;
            if (bar_on)                osd_rgb = fill_col;
            if (tick_on)               osd_rgb = 24'hFFFFFF;
            if (label_px_on)           osd_rgb = label_col;
            if (val_px_on)             osd_rgb = val_col;
            if (act_border)            osd_rgb = COL_ACT;
            if (panel_border)          osd_rgb = COL_BORDER;
        end
    end

    assign pixel_out = osd_en ? osd_rgb : (image_visible ? adj_px : 24'd0);

endmodule

// =====================================================================
// key_param_ctrl : brightness / contrast / saturation adjustment control
//
// Board key mapping (see README / schematic EG4S20BG256_MINI_V2.0):
//   KEY_2 (B2) = key1 : manual next image
//   KEY_4 (C1) = key2 : auto slideshow on/off
//   KEY_3 (B1) = key3 : parameter select key (added)
//
// Operation (all short presses; active-low, pressed = 0):
//   key3 short press cycles: normal -> brightness -> contrast -> saturation -> exit(normal) -> ...
//   In adjust mode (adjust_mode=1):
//       key1 short press = decrease current parameter by one step;
//                          hold ~0.5s to auto-repeat decrease
//       key2 short press = increase current parameter by one step;
//                          hold ~0.5s to auto-repeat increase
//   In normal mode key1/key2 pass through unchanged (next image / auto slideshow).
//
// Three parameters (8bit, defaults):
//   brightness : 0..255, default 128 (128 = no change)
//   contrast   : 0..255, default 128 (128 = 1.0x)
//   saturation : 0..255, default 255 (255 = 1.0x original)
//
// NOTE: this module is intentionally defined in the same file as video_pp
// (already registered in the project) to avoid a separate source-file
// registration step that the tool keeps dropping.
// =====================================================================
module key_param_ctrl #(
    parameter integer CLK_FREQ_HZ   = 50_000_000,
    parameter integer DEBOUNCE_MS   = 10,
    parameter integer HOLD_DELAY_MS = 500,
    parameter integer REPEAT_MS     = 200,
    parameter integer STEP          = 8
)(
    input  wire       clk,
    input  wire       rst,
    input  wire       key3,          // parameter select (short press cycles)
    input  wire       key1,          // adjust mode: decrease; normal: next image
    input  wire       key2,          // adjust mode: increase; normal: auto slideshow
    input  wire       host_key3_press,
    input  wire       host_param_write,
    input  wire [1:0] host_param_select,
    input  wire [7:0] host_param_value,
    output reg        adjust_mode,   // 1 = in parameter adjust mode
    output reg  [1:0] active_param,  // 0=brightness 1=contrast 2=saturation
    output reg  [7:0] brightness,
    output reg  [7:0] contrast,
    output reg  [7:0] saturation,
    output reg        key1_gated,    // forced to 1 in adjust mode (blocks next image)
    output reg        key2_gated     // forced to 1 in adjust mode (blocks auto slideshow)
);

    localparam integer DEB_CNT  = (CLK_FREQ_HZ / 1000) * DEBOUNCE_MS;
    localparam integer HOLD_CNT = (CLK_FREQ_HZ / 1000) * HOLD_DELAY_MS;
    localparam integer REP_CNT  = (CLK_FREQ_HZ / 1000) * REPEAT_MS;

    // ================= 2-stage synchronizer (keys are slow signals) =================
    reg [1:0] k1_s, k2_s, k3_s;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            k1_s <= 2'b11; k2_s <= 2'b11; k3_s <= 2'b11;
        end else begin
            k1_s <= {k1_s[0], key1};
            k2_s <= {k2_s[0], key2};
            k3_s <= {k3_s[0], key3};
        end
    end

    // ================= debounce (stable level; pressed = 0) =================
    reg [31:0] k1_cnt, k2_cnt, k3_cnt;
    reg        k1_st, k2_st, k3_st;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            k1_cnt <= 32'd0; k2_cnt <= 32'd0; k3_cnt <= 32'd0;
            k1_st  <= 1'b1;  k2_st  <= 1'b1;  k3_st  <= 1'b1;
        end else begin
            if (k1_s[1] != k1_st) begin
                if (k1_cnt >= DEB_CNT - 1) begin k1_st <= k1_s[1]; k1_cnt <= 32'd0; end
                else k1_cnt <= k1_cnt + 32'd1;
            end else k1_cnt <= 32'd0;

            if (k2_s[1] != k2_st) begin
                if (k2_cnt >= DEB_CNT - 1) begin k2_st <= k2_s[1]; k2_cnt <= 32'd0; end
                else k2_cnt <= k2_cnt + 32'd1;
            end else k2_cnt <= 32'd0;

            if (k3_s[1] != k3_st) begin
                if (k3_cnt >= DEB_CNT - 1) begin k3_st <= k3_s[1]; k3_cnt <= 32'd0; end
                else k3_cnt <= k3_cnt + 32'd1;
            end else k3_cnt <= 32'd0;
        end
    end

    // ================= press edge detection =================
    reg k1_st_d, k2_st_d, k3_st_d;
    always @(posedge clk or posedge rst) begin
        if (rst) begin k1_st_d <= 1'b1; k2_st_d <= 1'b1; k3_st_d <= 1'b1; end
        else begin k1_st_d <= k1_st; k2_st_d <= k2_st; k3_st_d <= k3_st; end
    end
    wire k1_press =  k1_st_d & ~k1_st;   // 1->0 falling edge = press
    wire k2_press =  k2_st_d & ~k2_st;
    wire k3_press = (k3_st_d & ~k3_st) | host_key3_press;

    // ================= adjust mode / active param (key3 short press cycles) =================
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            adjust_mode  <= 1'b0;
            active_param <= 2'd0;
        end else if (k3_press) begin
            if (!adjust_mode) begin
                adjust_mode  <= 1'b1;   // enter: brightness
                active_param <= 2'd0;
            end else if (active_param == 2'd2) begin
                adjust_mode <= 1'b0;    // exit after saturation
            end else begin
                active_param <= active_param + 2'd1;
            end
        end
    end

    // ================= hold timer / auto-repeat =================
    reg [31:0] hold_cnt;
    always @(posedge clk or posedge rst) begin
        if (rst) hold_cnt <= 32'd0;
        else if (adjust_mode && (k1_st == 1'b0 || k2_st == 1'b0)) begin
            if (hold_cnt < HOLD_CNT - 1) hold_cnt <= hold_cnt + 32'd1;
        end else hold_cnt <= 32'd0;
    end
    wire hold_ready = (hold_cnt >= HOLD_CNT - 1);

    reg [31:0] rep_cnt;
    always @(posedge clk or posedge rst) begin
        if (rst) rep_cnt <= 32'd0;
        else if (rep_cnt >= REP_CNT - 1) rep_cnt <= 32'd0;
        else rep_cnt <= rep_cnt + 32'd1;
    end
    wire rep_tick = (rep_cnt == REP_CNT - 1);

    // inc/dec trigger: short press edge = one step; hold past HOLD then repeat on REP
    reg inc, dec;
    always @* begin
        dec = 1'b0;
        inc = 1'b0;
        if (adjust_mode) begin
            if (k1_press)          dec = 1'b1;
            else if (k2_press)     inc = 1'b1;
            else if (hold_ready && rep_tick) begin
                if      (k1_st == 1'b0) dec = 1'b1;
                else if (k2_st == 1'b0) inc = 1'b1;
            end
        end
    end

    // ================= parameter value update (saturate at bounds) =================
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            brightness <= 8'd128;
            contrast   <= 8'd128;
            saturation <= 8'd255;
        end else if (host_param_write) begin
            case (host_param_select)
                2'd0: brightness <= host_param_value;
                2'd1: contrast   <= host_param_value;
                2'd2: saturation <= host_param_value;
                default: ;
            endcase
        end else if (adjust_mode) begin
            case (active_param)
                2'd0: begin
                    if (dec)      brightness <= (brightness >= STEP) ? (brightness - STEP) : 8'd0;
                    else if (inc) brightness <= (brightness <= 8'd255 - STEP) ? (brightness + STEP) : 8'd255;
                end
                2'd1: begin
                    if (dec)      contrast <= (contrast >= STEP) ? (contrast - STEP) : 8'd0;
                    else if (inc) contrast <= (contrast <= 8'd255 - STEP) ? (contrast + STEP) : 8'd255;
                end
                2'd2: begin
                    if (dec)      saturation <= (saturation >= STEP) ? (saturation - STEP) : 8'd0;
                    else if (inc) saturation <= (saturation <= 8'd255 - STEP) ? (saturation + STEP) : 8'd255;
                end
                default: ;
            endcase
        end
    end

    // Manual-key debounce runs in the top-level system-clock domain before
    // its toggle is transferred to the SD-card clock domain.
    always @* begin
        key1_gated = adjust_mode ? 1'b1 : key1;
        key2_gated = adjust_mode ? 1'b1 : key2;
    end

endmodule
