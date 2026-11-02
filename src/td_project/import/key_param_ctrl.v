`timescale 1ns/1ps
// =====================================================================
// key_param_ctrl : 用 KEY_3 + key1 + key2 短按/组合调节 亮度/对比度/饱和度
//
// 板上按键映射（见 README / 原理图 EG4S20BG256_MINI_V2.0）：
//   KEY_2 (B2) = key1 : 手动下一张
//   KEY_4 (C1) = key2 : 自动轮播开/关
//   KEY_3 (B1) = key3 : 参数调节选择键（新增）
//
// 操作方式（均为短按，按下=0）：
//   key3 短按循环：普通 -> 亮度 -> 对比度 -> 饱和度 -> 退出(普通) -> ...
//   调节模式（adjust_mode=1）下：
//       key1 短按 = 减小当前参数一步；按住约 0.5s 后连发减小
//       key2 短按 = 增大当前参数一步；按住约 0.5s 后连发增大
//   非调节模式下 key1/key2 原样直通（下一张 / 自动轮播），不受影响。
//
// 三个参数（8bit，默认值）：
//   亮度   brightness : 0..255, 默认 128（128 = 不增不减）
//   对比度 contrast   : 0..255, 默认 128（128 = 1.0x）
//   饱和度 saturation : 0..255, 默认 255（255 = 1.0x 原色）
// =====================================================================
module key_param_ctrl #(
    parameter integer CLK_FREQ_HZ   = 50_000_000,
    parameter integer DEBOUNCE_MS   = 10,
    parameter integer HOLD_DELAY_MS = 500,     // 按住多久后开始连发
    parameter integer REPEAT_MS     = 200,     // 连发周期
    parameter integer STEP          = 8        // 每步增减量
)(
    input  wire       clk,
    input  wire       rst,
    input  wire       key3,          // 参数选择键（短按循环）
    input  wire       key1,          // 调节模式：减小；普通模式：下一张
    input  wire       key2,          // 调节模式：增大；普通模式：自动轮播
    output reg        adjust_mode,   // 1 = 处于参数调节模式
    output reg  [1:0] active_param,  // 0=亮度 1=对比度 2=饱和度
    output reg  [7:0] brightness,
    output reg  [7:0] contrast,
    output reg  [7:0] saturation,
    output reg        key1_gated,    // 调节模式下置 1，屏蔽切图
    output reg        key2_gated     // 调节模式下置 1，屏蔽自动轮播
);

    localparam integer DEB_CNT  = (CLK_FREQ_HZ / 1000) * DEBOUNCE_MS;
    localparam integer HOLD_CNT = (CLK_FREQ_HZ / 1000) * HOLD_DELAY_MS;
    localparam integer REP_CNT  = (CLK_FREQ_HZ / 1000) * REPEAT_MS;

    // ================= 两级同步（按键为慢信号） =================
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

    // ================= 消抖（稳定判定，按下=0） =================
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

    // ================= 按下边沿检测 =================
    reg k1_st_d, k2_st_d, k3_st_d;
    always @(posedge clk or posedge rst) begin
        if (rst) begin k1_st_d <= 1'b1; k2_st_d <= 1'b1; k3_st_d <= 1'b1; end
        else begin k1_st_d <= k1_st; k2_st_d <= k2_st; k3_st_d <= k3_st; end
    end
    wire k1_press =  k1_st_d & ~k1_st;   // 1->0 下降沿 = 按下
    wire k2_press =  k2_st_d & ~k2_st;
    wire k3_press =  k3_st_d & ~k3_st;

    // ================= 调节模式 / 当前参数（key3 短按循环） =================
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            adjust_mode  <= 1'b0;
            active_param <= 2'd0;
        end else if (k3_press) begin
            if (!adjust_mode) begin
                adjust_mode  <= 1'b1;   // 进入：亮度
                active_param <= 2'd0;
            end else if (active_param == 2'd2) begin
                adjust_mode <= 1'b0;    // 饱和度之后退出
            end else begin
                active_param <= active_param + 2'd1;
            end
        end
    end

    // ================= 按住计时 / 连发 =================
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

    // 增减触发：短按边沿立即一步；按住超过 HOLD 后按 REP 连发
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

    // ================= 参数值调节（边界饱和） =================
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            brightness <= 8'd128;
            contrast   <= 8'd128;
            saturation <= 8'd255;
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

    // ================= 普通模式下直通 key1/key2，调节模式下屏蔽 =================
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            key1_gated <= 1'b1;
            key2_gated <= 1'b1;
        end else begin
            key1_gated <= adjust_mode ? 1'b1 : key1;
            key2_gated <= adjust_mode ? 1'b1 : key2;
        end
    end

endmodule
