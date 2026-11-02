module hdmi_audio_tone_i2s_64fs #(
    parameter integer NOTE_HOLD_FRAMES = 19200
)(
    input  wire       I_mclk,
    input  wire       I_rst,
    input  wire [1:0] I_track_idx,
    input  wire       I_enable,
    output reg        O_i2s_BCLK,
    output reg        O_i2s_LRCK,
    output reg        O_i2s_DOUT
);

reg [1:0] S_track_meta;
reg [1:0] S_track_sync;
reg [1:0] S_track_active;
reg [1:0] S_enable_sync;
reg [5:0] S_bit_cnt;
reg [63:0] S_shift_reg;
reg [31:0] S_melody_phase;
reg [31:0] S_bass_phase;
reg signed [23:0] S_sample_word;
reg signed [23:0] S_sample_next;
reg [2:0] S_step_idx;
reg [15:0] S_step_frame_cnt;

function [2:0] melody_note_lut;
    input [1:0] track;
    input [2:0] step;
    begin
        case (track)
            2'd0: begin
                case (step)
                    3'd0: melody_note_lut = 3'd0;
                    3'd1: melody_note_lut = 3'd4;
                    3'd2: melody_note_lut = 3'd3;
                    3'd3: melody_note_lut = 3'd2;
                    3'd4: melody_note_lut = 3'd1;
                    3'd5: melody_note_lut = 3'd2;
                    3'd6: melody_note_lut = 3'd3;
                    default: melody_note_lut = 3'd4;
                endcase
            end
            2'd1: begin
                case (step)
                    3'd0: melody_note_lut = 3'd0;
                    3'd1: melody_note_lut = 3'd2;
                    3'd2: melody_note_lut = 3'd4;
                    3'd3: melody_note_lut = 3'd5;
                    3'd4: melody_note_lut = 3'd4;
                    3'd5: melody_note_lut = 3'd2;
                    3'd6: melody_note_lut = 3'd1;
                    default: melody_note_lut = 3'd0;
                endcase
            end
            2'd2: begin
                case (step)
                    3'd0: melody_note_lut = 3'd2;
                    3'd1: melody_note_lut = 3'd3;
                    3'd2: melody_note_lut = 3'd4;
                    3'd3: melody_note_lut = 3'd3;
                    3'd4: melody_note_lut = 3'd2;
                    3'd5: melody_note_lut = 3'd1;
                    3'd6: melody_note_lut = 3'd0;
                    default: melody_note_lut = 3'd2;
                endcase
            end
            default: begin
                case (step)
                    3'd0: melody_note_lut = 3'd4;
                    3'd1: melody_note_lut = 3'd3;
                    3'd2: melody_note_lut = 3'd2;
                    3'd3: melody_note_lut = 3'd0;
                    3'd4: melody_note_lut = 3'd2;
                    3'd5: melody_note_lut = 3'd3;
                    3'd6: melody_note_lut = 3'd4;
                    default: melody_note_lut = 3'd5;
                endcase
            end
        endcase
    end
endfunction

function [2:0] bass_note_lut;
    input [1:0] track;
    input [1:0] phrase_step;
    begin
        case (track)
            2'd0: begin
                case (phrase_step)
                    2'd0: bass_note_lut = 3'd0;
                    2'd1: bass_note_lut = 3'd3;
                    2'd2: bass_note_lut = 3'd1;
                    default: bass_note_lut = 3'd3;
                endcase
            end
            2'd1: begin
                case (phrase_step)
                    2'd0: bass_note_lut = 3'd0;
                    2'd1: bass_note_lut = 3'd0;
                    2'd2: bass_note_lut = 3'd3;
                    default: bass_note_lut = 3'd0;
                endcase
            end
            2'd2: begin
                case (phrase_step)
                    2'd0: bass_note_lut = 3'd2;
                    2'd1: bass_note_lut = 3'd4;
                    2'd2: bass_note_lut = 3'd1;
                    default: bass_note_lut = 3'd2;
                endcase
            end
            default: begin
                case (phrase_step)
                    2'd0: bass_note_lut = 3'd4;
                    2'd1: bass_note_lut = 3'd2;
                    2'd2: bass_note_lut = 3'd3;
                    default: bass_note_lut = 3'd4;
                endcase
            end
        endcase
    end
endfunction

function [31:0] melody_phase_inc;
    input [2:0] note;
    begin
        case (note)
            3'd0: melody_phase_inc = 32'd23409862; // C4
            3'd1: melody_phase_inc = 32'd26276681; // D4
            3'd2: melody_phase_inc = 32'd29494578; // E4
            3'd3: melody_phase_inc = 32'd35075155; // G4
            3'd4: melody_phase_inc = 32'd39370534; // A4
            3'd5: melody_phase_inc = 32'd46819716; // C5
            default: melody_phase_inc = 32'd52553362; // D5
        endcase
    end
endfunction

function [31:0] bass_phase_inc;
    input [2:0] note;
    begin
        case (note)
            3'd0: bass_phase_inc = 32'd11704931; // C3
            3'd1: bass_phase_inc = 32'd13138340; // D3
            3'd2: bass_phase_inc = 32'd14747289; // E3
            3'd3: bass_phase_inc = 32'd17537578; // G3
            default: bass_phase_inc = 32'd19685267; // A3
        endcase
    end
endfunction

function signed [15:0] quarter_wave;
    input [4:0] index;
    begin
        case (index)
            5'd0:  quarter_wave = 16'sd0;
            5'd1:  quarter_wave = 16'sd3212;
            5'd2:  quarter_wave = 16'sd6393;
            5'd3:  quarter_wave = 16'sd9512;
            5'd4:  quarter_wave = 16'sd12539;
            5'd5:  quarter_wave = 16'sd15446;
            5'd6:  quarter_wave = 16'sd18204;
            5'd7:  quarter_wave = 16'sd20787;
            5'd8:  quarter_wave = 16'sd23170;
            5'd9:  quarter_wave = 16'sd25330;
            5'd10: quarter_wave = 16'sd27245;
            5'd11: quarter_wave = 16'sd28898;
            5'd12: quarter_wave = 16'sd30273;
            5'd13: quarter_wave = 16'sd31356;
            5'd14: quarter_wave = 16'sd32137;
            5'd15: quarter_wave = 16'sd32609;
            default: quarter_wave = 16'sd32767;
        endcase
    end
endfunction

function signed [15:0] sine_lut;
    input [5:0] phase;
    reg signed [15:0] wave;
    begin
        case (phase[5:4])
            2'd0: wave = quarter_wave({1'b0, phase[3:0]});
            2'd1: wave = quarter_wave(5'd16 - {1'b0, phase[3:0]});
            2'd2: wave = -quarter_wave({1'b0, phase[3:0]});
            default: wave = -quarter_wave(5'd16 - {1'b0, phase[3:0]});
        endcase
        sine_lut = wave;
    end
endfunction

wire [2:0] W_step_for_sound = (S_track_sync != S_track_active)
    ? 3'd0 : S_step_idx;
wire [2:0] W_melody_note = melody_note_lut(S_track_sync, W_step_for_sound);
wire [2:0] W_bass_note = bass_note_lut(S_track_sync, W_step_for_sound[2:1]);
wire [31:0] W_melody_inc = melody_phase_inc(W_melody_note);
wire [31:0] W_bass_inc = bass_phase_inc(W_bass_note);
wire signed [15:0] W_melody_wave = sine_lut(S_melody_phase[31:26]);
wire signed [15:0] W_bass_wave = sine_lut(S_bass_phase[31:26]);
wire signed [23:0] W_melody_sample =
    {{4{W_melody_wave[15]}}, W_melody_wave, 4'b0000};
wire signed [23:0] W_bass_sample =
    {{5{W_bass_wave[15]}}, W_bass_wave, 3'b000};
wire signed [24:0] W_mixed_sample =
    {W_melody_sample[23], W_melody_sample}
    + {W_bass_sample[23], W_bass_sample};

always @(posedge I_mclk or posedge I_rst) begin
    if (I_rst) begin
        S_track_meta      <= 2'd0;
        S_track_sync      <= 2'd0;
        S_track_active    <= 2'd0;
        S_enable_sync     <= 2'b00;
        O_i2s_BCLK        <= 1'b0;
        O_i2s_LRCK        <= 1'b0;
        O_i2s_DOUT        <= 1'b0;
        S_bit_cnt         <= 6'd0;
        S_shift_reg       <= 64'd0;
        S_melody_phase    <= 32'd0;
        S_bass_phase      <= 32'd0;
        S_sample_word     <= 24'sd0;
        S_sample_next     <= 24'sd0;
        S_step_idx        <= 3'd0;
        S_step_frame_cnt  <= 16'd0;
    end else begin
        S_track_meta  <= I_track_idx;
        S_track_sync  <= S_track_meta;
        S_enable_sync <= {S_enable_sync[0], I_enable};

        O_i2s_BCLK <= ~O_i2s_BCLK;

        if (O_i2s_BCLK) begin
            O_i2s_DOUT  <= S_shift_reg[63];
            S_shift_reg <= {S_shift_reg[62:0], 1'b0};

            if (S_bit_cnt == 6'd63) begin
                S_bit_cnt <= 6'd0;

                if (O_i2s_LRCK == 1'b0) begin
                    O_i2s_LRCK  <= 1'b1;
                    S_shift_reg <= {S_sample_word, 40'd0};
                end else begin
                    O_i2s_LRCK <= 1'b0;

                    if (S_enable_sync[1]) begin
                        S_melody_phase <= S_melody_phase + W_melody_inc;
                        S_bass_phase   <= S_bass_phase + W_bass_inc;
                        S_sample_next  <= W_mixed_sample[23:0];

                        if (S_track_sync != S_track_active) begin
                            S_track_active   <= S_track_sync;
                            S_step_idx       <= 3'd0;
                            S_step_frame_cnt <= 16'd0;
                        end else if (S_step_frame_cnt == NOTE_HOLD_FRAMES - 1) begin
                            S_step_frame_cnt <= 16'd0;
                            S_step_idx <= (S_step_idx == 3'd7)
                                ? 3'd0 : S_step_idx + 3'd1;
                        end else begin
                            S_step_frame_cnt <= S_step_frame_cnt + 16'd1;
                        end
                    end else begin
                        S_track_active   <= S_track_sync;
                        S_melody_phase   <= 32'd0;
                        S_bass_phase     <= 32'd0;
                        S_sample_next    <= 24'sd0;
                        S_step_idx       <= 3'd0;
                        S_step_frame_cnt <= 16'd0;
                    end

                    S_shift_reg <= {S_sample_next, 40'd0};
                    S_sample_word <= S_sample_next;
                end
            end else begin
                S_bit_cnt <= S_bit_cnt + 6'd1;
            end
        end
    end
end

endmodule
