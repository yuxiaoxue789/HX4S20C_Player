`timescale 1ns/1ps
// =====================================================================
// video_adjust : 亮度 / 对比度 / 饱和度 像素处理（纯组合逻辑）
//
// 输入 RGB888，输出按 对比度 -> 亮度 -> 饱和度 顺序处理后的 RGB888：
//   对比度   out = (p - 128) * contrast / 128 + 128        （contrast=128 -> 1.0x）
//   亮度     out = out + (brightness - 128)                 （brightness=128 -> 0）
//   饱和度   gray = (R*77 + G*150 + B*29) / 256
//            out = gray + (out - gray) * saturation / 256   （saturation=255 -> 原色）
// 中间结果均做 0..255 饱和钳位。所有乘法可由 DSP 单元推断实现。
// =====================================================================
module video_adjust (
    input  wire [23:0] pixel,      // {R[23:16], G[15:8], B[7:0]}
    input  wire [7:0]  brightness, // 0..255, 128=中性
    input  wire [7:0]  contrast,   // 0..255, 128=1.0x
    input  wire [7:0]  saturation, // 0..255, 255=1.0x
    output wire [23:0] dout
);

    wire [7:0] r = pixel[23:16];
    wire [7:0] g = pixel[15:8];
    wire [7:0] b = pixel[7:0];

    // ---- 0..255 饱和钳位 ----
    function [7:0] clamp8(input signed [23:0] v);
        begin
            if (v[23])                 clamp8 = 8'd0;        // 负 -> 0
            else if (v[22:8] != 0)     clamp8 = 8'd255;      // >255 -> 255
            else                       clamp8 = v[7:0];
        end
    endfunction

    // ---- 单通道 对比度 + 亮度 ----
    function [7:0] cb(input [7:0] p);
        reg signed [23:0] t;
        begin
            t = ($signed({1'b0, p}) - 24'sd128) * $signed({1'b0, contrast});
            t = t + 24'sd16384;                      // 128 << 7
            t = t >>> 7;
            t = t + ($signed({1'b0, brightness}) - 24'sd128);
            cb = clamp8(t);
        end
    endfunction

    wire [7:0] rc = cb(r);
    wire [7:0] gc = cb(g);
    wire [7:0] bc = cb(b);

    // ---- 亮度（灰度）----
    wire [15:0] gray_t = rc*8'd77 + gc*8'd150 + bc*8'd29;
    wire [7:0]  gray   = gray_t[15:8];

    // ---- 单通道 饱和度混合 ----
    function [7:0] satb(input [7:0] c);
        reg signed [23:0] t;
        begin
            t = ($signed({1'b0, c}) - $signed({1'b0, gray})) * $signed({1'b0, saturation});
            t = t >>> 8;
            t = t + $signed({1'b0, gray});
            satb = clamp8(t);
        end
    endfunction

    assign dout = {satb(rc), satb(gc), satb(bc)};

endmodule
