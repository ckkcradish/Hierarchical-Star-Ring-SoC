`timescale 1ns / 1ps

module fpm(
    input         clk,
    input         reset,
    input  [11:0] A,    // E5M6: {S, Exp[4:0], Frac[5:0]}
    input  [11:0] B,    // E5M6: {S, Exp[4:0], Frac[5:0]}
    input         pushin,
    output reg    pushout,      
    output reg signed [47:0] Z // Output: 24.24 Fixed Point (2's Complement)
);

    // ==========================================
    // Parameters & Constants
    // ==========================================
    localparam signed [7:0] BIAS        = 8'sd15;
    localparam signed [7:0] UF_MIN      = 8'sd2;    // Exponents below 2 -> 0 (FTZ)
    localparam signed [7:0] EXP_MAX_SAT = 8'sd30;   // Saturate at Exp 30
    
    // Max Saturation Value (24.24 format)
    // Hex: 0x00E0_0000_0000 -> 224.0 in decimal
    localparam signed [47:0] FIXED_MAX     = 48'h00E0_0000_0000;
    localparam signed [47:0] FIXED_MAX_NEG = -FIXED_MAX;

    // =========================================================================
    // Stage 1: Decode, Multiply, Initial Exp Calculation
    // (This stage maintains full precision 14-bit product)
    // =========================================================================
    
    // --- Stage 1 Combinational Logic Signals ---
    logic [4:0]  s1_c_expA, s1_c_expB;
    logic [5:0]  s1_c_fracA, s1_c_fracB;
    logic        s1_c_zeroA, s1_c_zeroB;
    logic        s1_c_is_zero;
    logic [6:0]  s1_c_mantA, s1_c_mantB;
    logic [13:0] s1_c_prod;       // 7x7 = 14 bits (Full Precision)
    logic        s1_c_sign;
    logic [5:0]  s1_c_eff_expA, s1_c_eff_expB;
    logic signed [7:0] s1_c_exp_sum;

    // --- Stage 1 Pipeline Registers ---
    logic        s1_r_valid;
    logic        s1_r_sign;
    logic signed [7:0] s1_r_exp_sum;
    logic [13:0] s1_r_prod;
    logic        s1_r_is_zero;

    // --- Stage 1 Combinational Logic Block ---
    always_comb begin
        // 1. Decode
        s1_c_expA  = A[10:6];
        s1_c_expB  = B[10:6];
        s1_c_fracA = A[5:0];
        s1_c_fracB = B[5:0];

        // 2. Zero Check
        s1_c_zeroA = (s1_c_expA == 0 && s1_c_fracA == 0);
        s1_c_zeroB = (s1_c_expB == 0 && s1_c_fracB == 0);
        s1_c_is_zero = (s1_c_zeroA || s1_c_zeroB);

        // 3. Mantissa Restoration (Handle Subnormals as Normal)
        s1_c_mantA = {1'b1, s1_c_fracA};
        s1_c_mantB = {1'b1, s1_c_fracB};

        // 4. Multiply (7x7 = 14 bits)
        s1_c_prod = s1_c_mantA * s1_c_mantB;

        // 5. Sign Calculation
        s1_c_sign = A[11] ^ B[11];

        // 6. Exponent Calculation (Unbiased Sum) (Handle Subnormals as Normal)
        s1_c_eff_expA = {1'b0, s1_c_expA};
        s1_c_eff_expB = {1'b0, s1_c_expB};
        
        // exp_sum = (ExpA + ExpB - BIAS)
        s1_c_exp_sum = $signed({2'b0, s1_c_eff_expA}) + $signed({2'b0, s1_c_eff_expB}) - BIAS;
    end

    // --- Stage 1 Sequential Logic ---
    always_ff @(posedge clk) begin
        if (reset) begin
            s1_r_valid   <= 0;
            s1_r_sign    <= 0;
            s1_r_exp_sum <= 0;
            s1_r_prod    <= 0;
            s1_r_is_zero <= 0;
        end else begin
            s1_r_valid   <= pushin;
            s1_r_sign    <= s1_c_sign;
            s1_r_exp_sum <= s1_c_exp_sum;
            s1_r_prod    <= s1_c_prod;
            s1_r_is_zero <= s1_c_is_zero;
        end
    end


    // =========================================================================
    // Stage 2: Exception Detection & Shift Calculation (NO MANTISSA SHIFT)
    // 
    // We calculate the shifted exponent here only to determine Saturation/FTZ.
    // The Mantissa remains untouched (14-bit).
    // =========================================================================
    
    // --- Stage 2 Combinational Logic Signals ---
    logic [13:0] s2_c_prod_raw;       // Pass through raw product
    logic signed [7:0] s2_c_shift_exp; // For flag checking only
    logic signed [7:0] s2_c_shift_amt;// Shift amount for Stage 3
    logic        s2_c_force_zero;
    logic        s2_c_force_sat;
    
    logic        s2_c_mant_sat_check; // Check for mantissa overflow condition
    logic signed [7:0] s2_c_rel_exp_adj; // Normalization offset (virtual)

    // --- Stage 2 Pipeline Registers ---
    logic        s2_r_valid;
    logic        s2_r_sign;
    logic [13:0] s2_r_prod;           // Raw 14-bit product
    logic signed [7:0] s2_r_shift_amt;
    logic        s2_r_force_zero;
    logic        s2_r_force_sat;

    // --- Stage 2 Combinational Logic Block ---
    always_comb begin
        // 1. Pass through the raw product
        s2_c_prod_raw = s1_r_prod;

        // 2. Determine Shifted Exponent for Saturation Logic
        // We simulate normalization to check if result exceeds limits.
        // s1_r_prod is 14 bits. 
        
        s2_c_mant_sat_check = 0;
        s2_c_rel_exp_adj    = 0;

        // Priority Encoder to find MSB position
        if (s1_r_prod[13]) begin 
            s2_c_rel_exp_adj = 1;
            // Check if mantissa is large enough to trigger saturation if Exp == MAX
            s2_c_mant_sat_check = (s1_r_prod[13:11] == 3'b111); 
        end else if (s1_r_prod[12]) begin
            s2_c_rel_exp_adj = 0;
            s2_c_mant_sat_check = (s1_r_prod[12:10] == 3'b111);
        end else if (s1_r_prod[11]) begin
            s2_c_rel_exp_adj = -1;
            s2_c_mant_sat_check = (s1_r_prod[11:9] == 3'b111);
        end else if (s1_r_prod[10]) begin
            s2_c_rel_exp_adj = -2;
            s2_c_mant_sat_check = 0; 
        end else if (s1_r_prod[9])  s2_c_rel_exp_adj = -3;
        else if (s1_r_prod[8])      s2_c_rel_exp_adj = -4;
        else if (s1_r_prod[7])      s2_c_rel_exp_adj = -5;
        else if (s1_r_prod[6])      s2_c_rel_exp_adj = -6;
        else if (s1_r_prod[5])      s2_c_rel_exp_adj = -7;
        else if (s1_r_prod[4])      s2_c_rel_exp_adj = -8;
        else if (s1_r_prod[3])      s2_c_rel_exp_adj = -9;
        else if (s1_r_prod[2])      s2_c_rel_exp_adj = -10;
        else if (s1_r_prod[1])      s2_c_rel_exp_adj = -11;
        else if (s1_r_prod[0])      s2_c_rel_exp_adj = -12;
        else                        s2_c_rel_exp_adj = -13; // Zero case

        // Calculate Shifted Exponent
        s2_c_shift_exp = s1_r_exp_sum + s2_c_rel_exp_adj;

        // 3. Exception Flags (FTZ / Saturation)
        if (s1_r_is_zero || (s2_c_shift_exp < UF_MIN)) begin
            s2_c_force_zero = 1;
            s2_c_force_sat  = 0;
        end else if ( (s2_c_shift_exp > EXP_MAX_SAT) || 
                      ((s2_c_shift_exp == EXP_MAX_SAT) && s2_c_mant_sat_check) ) begin
            s2_c_force_zero = 0;
            s2_c_force_sat  = 1;
        end else begin
            s2_c_force_zero = 0;
            s2_c_force_sat  = 0;
        end

        // 4. Calculate Final Shift Amount for Stage 3
         s2_c_shift_amt = s1_r_exp_sum - 8'd3;
    end

    // --- Stage 2 Sequential Logic ---
    always_ff @(posedge clk) begin
        if (reset) begin
            s2_r_valid      <= 0;
            s2_r_sign       <= 0;
            s2_r_prod       <= 0;
            s2_r_shift_amt  <= 0;
            s2_r_force_zero <= 0;
            s2_r_force_sat  <= 0;
        end else begin
            s2_r_valid      <= s1_r_valid;
            s2_r_sign       <= s1_r_sign;
            s2_r_prod       <= s2_c_prod_raw;  // Keep 14-bit
            s2_r_shift_amt  <= s2_c_shift_amt; // Pre-calculated shift
            s2_r_force_zero <= s2_c_force_zero;
            s2_r_force_sat  <= s2_c_force_sat;
        end
    end


    // =========================================================================
    // Stage 3: Sign Extension, Arithmetic Shift & Output
    // 
    // *KEY CHANGE*: For negative numbers, we convert to 2's complement BEFORE
    // shifting. This ensures that when we shift right, we are flooring
    // (rounding towards -infinity) rather than truncating towards zero.
    // =========================================================================
    
    // --- Stage 3 Combinational Logic Signals ---
    logic signed [63:0] s3_c_pre_shift_val; // Signed container
    logic signed [63:0] s3_c_shifted_val;   // Result after shift
    logic signed [47:0] s3_c_fixed_final;   // Final Q24.24 result

    // --- Stage 3 Combinational Logic Block ---
    always_comb begin
        s3_c_pre_shift_val = 0;
        s3_c_shifted_val   = 0;
        s3_c_fixed_final   = 0;

        // 1. Prepare Signed Value (Negate BEFORE Shift)
        // If sign is negative, we negate the unsigned product immediately.
        // We use a 64-bit signed container to prevent overflow during left shifts.
        if (s2_r_sign) begin
            // Convert to 2's Complement Negative
            s3_c_pre_shift_val = -signed'({50'd0, s2_r_prod});
        end else begin
            // Keep Positive
            s3_c_pre_shift_val = signed'({50'd0, s2_r_prod});
        end

        // 2. Arithmetic Shift
        // Uses '>>>' for Arithmetic Right Shift (preserves sign bit)
        if (s2_r_shift_amt >= 0) begin
            // Shift Left (Value increases)
            s3_c_shifted_val = s3_c_pre_shift_val <<< s2_r_shift_amt;
        end else begin
            // Shift Right (Value decreases)
            // Because s3_c_pre_shift_val is signed, >>> performs sign extension.
            // For negative numbers, this effectively floors the result.
            s3_c_shifted_val = s3_c_pre_shift_val >>> (-s2_r_shift_amt);
        end

        // 3. Exception Mux & Truncation
        if (s2_r_force_zero) begin
            s3_c_fixed_final = 48'sd0;
        end else if (s2_r_force_sat) begin
            s3_c_fixed_final = s2_r_sign ? FIXED_MAX_NEG : FIXED_MAX;
        end else begin
            // Truncate to 48 bits
            s3_c_fixed_final = s3_c_shifted_val[47:0];
        end
    end

    // --- Stage 3 Sequential Logic (Output) ---
    always_ff @(posedge clk) begin
        if (reset) begin
            pushout <= 0;
            Z       <= 0;
        end else begin
            pushout <= s2_r_valid;
            if (s2_r_valid) begin
                Z <= s3_c_fixed_final;
            end
        end
    end

endmodule
