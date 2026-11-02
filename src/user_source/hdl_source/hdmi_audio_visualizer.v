module hdmi_audio_visualizer(
    input  wire        I_clk,
    input  wire        I_rst,
    input  wire        I_de,
    input  wire        I_vs,
    input  wire        I_audio_valid,
    input  wire [23:0] I_audio_left_data,
    input  wire [23:0] I_audio_right_data,
    input  wire [23:0] I_rgb,
    output reg  [23:0] O_rgb
);

localparam FFT_IDLE = 2'd0;
localparam FFT_RUN  = 2'd1;
localparam FFT_MAG  = 2'd2;

reg [7:0] waveform_samples [0:63];
reg [5:0] write_index;
reg [3:0] sample_count;
reg signed [11:0] sample_accumulator;
reg [3:0] fft_capture_index;
reg [1:0] fft_state;
reg [1:0] fft_stage;
reg [2:0] fft_butterfly_index;
reg [1:0] fft_product_phase;
reg [2:0] fft_magnitude_index;
reg signed [7:0] fft_real [0:15];
reg signed [7:0] fft_imag [0:15];
reg [8:0] spectrum [0:7];
reg signed [15:0] fft_product_rr;
reg signed [15:0] fft_product_ii;
reg signed [15:0] fft_product_ri;
reg de_d;
reg vs_d;
reg [9:0] pixel_x;
reg [9:0] pixel_y;
reg signed [7:0] pcm_sample_a;
reg signed [7:0] pcm_sample_b;
reg signed [8:0] pcm_sample_sum;
reg signed [7:0] pcm_sample_average;
reg signed [10:0] pcm_bar_y;
reg [3:0] fft_a_index;
reg [3:0] fft_b_index;
reg [2:0] fft_twiddle_index;
reg signed [7:0] fft_twiddle_real;
reg signed [7:0] fft_twiddle_imag;
wire signed [7:0] fft_multiplier_input =
    fft_product_phase[0] ? fft_imag[fft_b_index] : fft_real[fft_b_index];
wire signed [7:0] fft_multiplier_twiddle =
    (fft_product_phase[1] ^ fft_product_phase[0]) ?
        fft_twiddle_imag : fft_twiddle_real;
wire signed [15:0] fft_product =
    $signed(fft_multiplier_input) * $signed(fft_multiplier_twiddle);
reg [2:0] bar_index;
reg [7:0] bar_height;
integer reset_index;

function [3:0] bit_reverse4;
    input [3:0] value;
    begin
        bit_reverse4 = {value[0], value[1], value[2], value[3]};
    end
endfunction

wire signed [24:0] stereo_sum =
    $signed({I_audio_left_data[23], I_audio_left_data}) +
    $signed({I_audio_right_data[23], I_audio_right_data});
wire signed [7:0] stereo_sample = stereo_sum[20:13];
wire signed [11:0] accumulated_sample =
    sample_accumulator + {{4{stereo_sample[7]}}, stereo_sample};
wire signed [7:0] averaged_sample = accumulated_sample >>> 4;
wire [4:0] pcm_bar_index = (pixel_x - 10'd48) >> 3;
wire [5:0] pcm_sample_index = write_index + {pcm_bar_index, 1'b0};
wire [5:0] pcm_next_sample_index = pcm_sample_index + 6'd1;
wire [3:0] fft_bin_index = {1'b0, fft_magnitude_index} + 4'd1;
wire [7:0] fft_abs_real =
    fft_real[fft_bin_index][7] ?
        (~fft_real[fft_bin_index] + 8'd1) : fft_real[fft_bin_index];
wire [7:0] fft_abs_imag =
    fft_imag[fft_bin_index][7] ?
        (~fft_imag[fft_bin_index] + 8'd1) : fft_imag[fft_bin_index];
wire [8:0] fft_magnitude =
    {1'b0, fft_abs_real} + {1'b0, fft_abs_imag};
wire signed [16:0] fft_rotated_real_full =
    {{1{fft_product_rr[15]}}, fft_product_rr} -
    {{1{fft_product_ii[15]}}, fft_product_ii};
wire signed [16:0] fft_rotated_imag_full =
    {{1{fft_product_ri[15]}}, fft_product_ri} +
    {{1{fft_product[15]}}, fft_product};
wire signed [8:0] fft_rotated_real = fft_rotated_real_full >>> 7;
wire signed [8:0] fft_rotated_imag = fft_rotated_imag_full >>> 7;
wire signed [9:0] fft_sum_real =
    $signed({{2{fft_real[fft_a_index][7]}}, fft_real[fft_a_index]}) +
    $signed({fft_rotated_real[8], fft_rotated_real});
wire signed [9:0] fft_diff_real =
    $signed({{2{fft_real[fft_a_index][7]}}, fft_real[fft_a_index]}) -
    $signed({fft_rotated_real[8], fft_rotated_real});
wire signed [9:0] fft_sum_imag =
    $signed({{2{fft_imag[fft_a_index][7]}}, fft_imag[fft_a_index]}) +
    $signed({fft_rotated_imag[8], fft_rotated_imag});
wire signed [9:0] fft_diff_imag =
    $signed({{2{fft_imag[fft_a_index][7]}}, fft_imag[fft_a_index]}) -
    $signed({fft_rotated_imag[8], fft_rotated_imag});
wire in_plot = (pixel_x >= 10'd40) && (pixel_x < 10'd600) &&
               (pixel_y >= 10'd390) && (pixel_y < 10'd438);
wire in_waveform_panel = (pixel_x >= 10'd40) && (pixel_x < 10'd312);
wire in_spectrum_panel = (pixel_x >= 10'd328) && (pixel_x < 10'd600);
wire plot_grid = (pixel_x == 10'd104) || (pixel_x == 10'd168) ||
                 (pixel_x == 10'd232) || (pixel_x == 10'd319) ||
                 (pixel_x == 10'd320);
wire plot_pcm_centerline =
    in_waveform_panel && (pixel_y == 10'd414);
wire plot_spectrum_baseline =
    in_spectrum_panel && (pixel_y == 10'd432);
wire plot_border = (pixel_x == 10'd40) || (pixel_x == 10'd311) ||
                   (pixel_x == 10'd328) || (pixel_x == 10'd599) ||
                   (pixel_y == 10'd390) || (pixel_y == 10'd437);
wire signed [10:0] pcm_bar_top = pcm_bar_y - 11'sd2;
wire signed [10:0] pcm_bar_bottom = pcm_bar_y + 11'sd2;
wire pcm_bar_pixel = in_waveform_panel &&
                     (pixel_x >= 10'd48) && (pixel_x < 10'd304) &&
                     (pixel_x[2:0] >= 3'd1) &&
                     (pixel_x[2:0] <= 3'd6) &&
                     ($signed({1'b0, pixel_y}) >= pcm_bar_top) &&
                     ($signed({1'b0, pixel_y}) < pcm_bar_bottom);
wire spectrum_bar_pixel = in_spectrum_panel &&
                          (pixel_x >= 10'd336) && (pixel_x < 10'd592) &&
                          (pixel_x[4:0] >= 5'd3) &&
                          (pixel_x[4:0] <= 5'd28) &&
                          (pixel_y >= (10'd432 - {2'd0, bar_height})) &&
                          (pixel_y < 10'd432);

always @* begin
    pcm_sample_a = $signed(waveform_samples[pcm_sample_index]);
    pcm_sample_b = $signed(waveform_samples[pcm_next_sample_index]);
    pcm_sample_sum = {pcm_sample_a[7], pcm_sample_a} +
                     {pcm_sample_b[7], pcm_sample_b};
    pcm_sample_average = pcm_sample_sum >>> 1;
    pcm_bar_y = 11'sd414 - (pcm_sample_average >>> 3);
end

always @* begin
    fft_a_index = 4'd0;
    fft_b_index = 4'd1;
    fft_twiddle_index = 3'd0;
    case (fft_stage)
        2'd0: begin
            fft_a_index = {fft_butterfly_index, 1'b0};
            fft_b_index = fft_a_index + 4'd1;
        end
        2'd1: begin
            fft_a_index = {fft_butterfly_index[2:1], 2'b00} +
                          {3'd0, fft_butterfly_index[0]};
            fft_b_index = fft_a_index + 4'd2;
            fft_twiddle_index = {fft_butterfly_index[0], 2'b00};
        end
        2'd2: begin
            fft_a_index = {fft_butterfly_index[2], 3'b000} +
                          {2'd0, fft_butterfly_index[1:0]};
            fft_b_index = fft_a_index + 4'd4;
            fft_twiddle_index = {fft_butterfly_index[1:0], 1'b0};
        end
        2'd3: begin
            fft_a_index = {1'b0, fft_butterfly_index};
            fft_b_index = fft_a_index + 4'd8;
            fft_twiddle_index = fft_butterfly_index;
        end
        default: begin
            fft_a_index = 4'd0;
            fft_b_index = 4'd1;
            fft_twiddle_index = 3'd0;
        end
    endcase

    case (fft_twiddle_index)
        3'd0: begin fft_twiddle_real =  8'sd127; fft_twiddle_imag =   8'sd0;   end
        3'd1: begin fft_twiddle_real =  8'sd117; fft_twiddle_imag = - 8'sd49;  end
        3'd2: begin fft_twiddle_real =  8'sd90;  fft_twiddle_imag = - 8'sd90;  end
        3'd3: begin fft_twiddle_real =  8'sd49;  fft_twiddle_imag = - 8'sd117; end
        3'd4: begin fft_twiddle_real =  8'sd0;   fft_twiddle_imag = - 8'sd127; end
        3'd5: begin fft_twiddle_real = -8'sd49;  fft_twiddle_imag = - 8'sd117; end
        3'd6: begin fft_twiddle_real = -8'sd90;  fft_twiddle_imag = - 8'sd90;  end
        default: begin fft_twiddle_real = -8'sd117; fft_twiddle_imag = - 8'sd49; end
    endcase
end

always @* begin
    if ((pixel_x >= 10'd336) && (pixel_x < 10'd592)) begin
        bar_index = (pixel_x - 10'd336) >> 5;
        bar_height = spectrum[bar_index] >> 1;
        if (bar_height > 8'd34)
            bar_height = 8'd34;
    end else begin
        bar_index = 3'd0;
        bar_height = 8'd0;
    end
end

always @(posedge I_clk or posedge I_rst) begin
    if (I_rst) begin
        write_index <= 7'd0;
        sample_count <= 4'd0;
        sample_accumulator <= 12'sd0;
        fft_capture_index <= 4'd0;
        fft_state <= FFT_IDLE;
        fft_stage <= 2'd0;
        fft_butterfly_index <= 3'd0;
        fft_product_phase <= 2'd0;
        fft_magnitude_index <= 3'd0;
        fft_product_rr <= 16'sd0;
        fft_product_ii <= 16'sd0;
        fft_product_ri <= 16'sd0;
        de_d <= 1'b0;
        vs_d <= 1'b0;
        pixel_x <= 10'd0;
        pixel_y <= 10'd0;
        for (reset_index = 0; reset_index < 64; reset_index = reset_index + 1)
            waveform_samples[reset_index] <= 8'd0;
        for (reset_index = 0; reset_index < 16; reset_index = reset_index + 1) begin
            fft_real[reset_index] <= 8'sd0;
            fft_imag[reset_index] <= 8'sd0;
        end
        for (reset_index = 0; reset_index < 8; reset_index = reset_index + 1)
            spectrum[reset_index] <= 9'd0;
    end else begin
        de_d <= I_de;
        vs_d <= I_vs;

        if (I_audio_valid) begin
            if (sample_count == 4'd15) begin
                waveform_samples[write_index] <= averaged_sample;
                write_index <= write_index + 6'd1;
                sample_count <= 4'd0;
                sample_accumulator <= 12'sd0;
                if (fft_state == FFT_IDLE) begin
                    fft_real[bit_reverse4(fft_capture_index)] <= averaged_sample;
                    fft_imag[bit_reverse4(fft_capture_index)] <= 8'sd0;
                    if (fft_capture_index == 4'd15) begin
                        fft_capture_index <= 4'd0;
                        fft_stage <= 2'd0;
                        fft_butterfly_index <= 3'd0;
                        fft_product_phase <= 2'd0;
                        fft_state <= FFT_RUN;
                    end else begin
                        fft_capture_index <= fft_capture_index + 4'd1;
                    end
                end
            end else begin
                sample_count <= sample_count + 4'd1;
                sample_accumulator <= accumulated_sample;
            end
        end

        case (fft_state)
            FFT_RUN: begin
                case (fft_product_phase)
                    2'd0: begin
                        fft_product_rr <= fft_product;
                        fft_product_phase <= 2'd1;
                    end
                    2'd1: begin
                        fft_product_ii <= fft_product;
                        fft_product_phase <= 2'd2;
                    end
                    2'd2: begin
                        fft_product_ri <= fft_product;
                        fft_product_phase <= 2'd3;
                    end
                    default: begin
                        fft_real[fft_a_index] <=
                            fft_sum_real >>> 1;
                        fft_imag[fft_a_index] <=
                            fft_sum_imag >>> 1;
                        fft_real[fft_b_index] <=
                            fft_diff_real >>> 1;
                        fft_imag[fft_b_index] <=
                            fft_diff_imag >>> 1;
                        fft_product_phase <= 2'd0;
                        if (fft_butterfly_index == 3'd7) begin
                            fft_butterfly_index <= 3'd0;
                            if (fft_stage == 2'd3) begin
                                fft_state <= FFT_MAG;
                                fft_magnitude_index <= 3'd0;
                            end else begin
                                fft_stage <= fft_stage + 2'd1;
                            end
                        end else begin
                            fft_butterfly_index <= fft_butterfly_index + 3'd1;
                        end
                    end
                endcase
            end
            FFT_MAG: begin
                spectrum[fft_magnitude_index] <= fft_magnitude;
                if (fft_magnitude_index == 3'd7) begin
                    fft_magnitude_index <= 3'd0;
                    fft_state <= FFT_IDLE;
                end else begin
                    fft_magnitude_index <= fft_magnitude_index + 3'd1;
                end
            end
            default: begin
            end
        endcase

        if (vs_d && !I_vs) begin
            pixel_x <= 10'd0;
            pixel_y <= 10'd0;
        end else if (I_de) begin
            if (pixel_x < 10'd639)
                pixel_x <= pixel_x + 10'd1;
        end else if (de_d) begin
            pixel_x <= 10'd0;
            if (pixel_y < 10'd479)
                pixel_y <= pixel_y + 10'd1;
        end
    end
end

always @* begin
    O_rgb = I_rgb;
    if (in_plot)
        O_rgb = 24'h08131E;
    if (in_plot && plot_grid)
        O_rgb = 24'h102532;
    if (in_plot && plot_pcm_centerline)
        O_rgb = 24'h29495A;
    if (in_plot && plot_spectrum_baseline)
        O_rgb = 24'h29495A;
    if (in_plot && plot_border)
        O_rgb = 24'h527080;
    if (pcm_bar_pixel)
        O_rgb = 24'h28A8FF;
    if (spectrum_bar_pixel)
        O_rgb = 24'hFFA84A;
end

endmodule
