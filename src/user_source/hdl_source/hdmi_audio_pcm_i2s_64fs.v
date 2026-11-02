module hdmi_audio_pcm_i2s_64fs(
    input              I_mclk,
    input              I_rst,
    input              I_enable,
    input      [16:0]   I_fifo_data,
    input              I_fifo_valid,
    input              I_fifo_empty,
    input              I_generation,
    output reg         O_fifo_rd_en,
    output reg         O_i2s_BCLK,
    output reg         O_i2s_LRCK,
    output reg         O_i2s_DOUT
);

reg [1:0] S_enable_sync;
reg [1:0] S_generation_sync;
reg [5:0] S_bit_cnt;
reg [63:0] S_shift_reg;
reg signed [23:0] S_sample_word;
reg signed [23:0] S_sample_next;
reg [16:0] S_pcm_prefetch;
reg S_pcm_valid;

wire signed [23:0] W_pcm_sample =
    {S_pcm_prefetch[15:0], 8'd0};

always @(posedge I_mclk or posedge I_rst) begin
    if (I_rst) begin
        S_enable_sync <= 2'b00;
        S_generation_sync <= 2'b00;
        S_bit_cnt <= 6'd0;
        S_shift_reg <= 64'd0;
        S_sample_word <= 24'sd0;
        S_sample_next <= 24'sd0;
        S_pcm_prefetch <= 17'd0;
        S_pcm_valid <= 1'b0;
        O_fifo_rd_en <= 1'b0;
        O_i2s_BCLK <= 1'b0;
        O_i2s_LRCK <= 1'b0;
        O_i2s_DOUT <= 1'b0;
    end else begin
        S_enable_sync <= {S_enable_sync[0], I_enable};
        S_generation_sync <= {S_generation_sync[0], I_generation};
        if (I_fifo_valid) begin
            S_pcm_prefetch <= I_fifo_data;
            S_pcm_valid <= 1'b1;
        end
        O_fifo_rd_en <= 1'b0;
        O_i2s_BCLK <= ~O_i2s_BCLK;

        if (O_i2s_BCLK) begin
            O_i2s_DOUT <= S_shift_reg[63];
            S_shift_reg <= {S_shift_reg[62:0], 1'b0};

            if (S_bit_cnt == 6'd63) begin
                S_bit_cnt <= 6'd0;
                if (O_i2s_LRCK == 1'b0) begin
                    O_i2s_LRCK <= 1'b1;
                    S_shift_reg <= {S_sample_word, 40'd0};
                end else begin
                    O_i2s_LRCK <= 1'b0;
                    if (S_enable_sync[1] && S_pcm_valid) begin
                        if (S_pcm_prefetch[16] == S_generation_sync[1])
                            S_sample_next <= W_pcm_sample;
                        else
                            S_sample_next <= 24'sd0;
                    end else begin
                        S_sample_next <= 24'sd0;
                    end
                    S_pcm_valid <= 1'b0;
                    if (S_enable_sync[1] && !I_fifo_empty)
                        O_fifo_rd_en <= 1'b1;
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
