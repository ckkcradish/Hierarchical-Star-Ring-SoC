`timescale 1ns / 1ps

// ---------------------------------------------------------
// Module: fpa (4-Input Fixed Point Adder - 4 Stage Pipeline)
// Description: Adds 4 signed 48-bit fixed point numbers.
//              Uses CSA tree logic for high-speed addition.
//              Pipeline depth: 5 cycles.
//              Architecture:
//              [Stage 1] Latch Inputs
//              [Stage 2] CSA Level 1 (4 -> 3)
//              [Stage 3] CSA Level 2 (3 -> 2)
//              [Stage 4] CPA (Final Addition) and output result
// ---------------------------------------------------------
module fpa (
    input  logic        clk,
    input  logic        reset,
    input  logic signed [47:0] A,
    input  logic signed [47:0] B,
    input  logic signed [47:0] C,
    input  logic signed [47:0] D,
    input  logic        pushin,
    output logic        pushout,
    output logic signed [47:0] Z
);

    // =========================
    // Valid Signal Pipeline (Adjusted to 4 stages)
    // =========================
    logic [3:0] valid_pipe;

    // =========================
    // Data Path Pipeline
    // =========================

    // --- Stage 1: Latch Inputs ---
    logic signed [47:0] s1_A, s1_B, s1_C, s1_D;

    always_ff @(posedge clk) begin
        if (reset) begin
            valid_pipe <= 4'd0;
            s1_A <= 0; s1_B <= 0; s1_C <= 0; s1_D <= 0;
        end else begin
            valid_pipe <= {valid_pipe[2:0], pushin};
            s1_A <= A; s1_B <= B; s1_C <= C; s1_D <= D;
        end
    end

    // --- Stage 2: CSA Level 1 (4 inputs -> 3 outputs) ---
    // Logic: Sum = A^B^C, Carry = Majority(A,B,C) << 1
    logic signed [47:0] s2_sum, s2_carry, s2_D;

    always_ff @(posedge clk) begin
        if (reset) begin
            s2_sum <= 0; s2_carry <= 0; s2_D <= 0;
        end else begin
            s2_sum   <= s1_A ^ s1_B ^ s1_C;
            s2_carry <= ((s1_A & s1_B) | (s1_B & s1_C) | (s1_A & s1_C)) << 1;
            s2_D     <= s1_D;
        end
    end

    // --- Stage 3: CSA Level 2 (3 inputs -> 2 outputs) ---
    logic signed [47:0] s3_sum, s3_carry;

    always_ff @(posedge clk) begin
        if (reset) begin
            s3_sum <= 0; s3_carry <= 0;
        end else begin
            s3_sum   <= s2_sum ^ s2_carry ^ s2_D;
            s3_carry <= ((s2_sum & s2_carry) | (s2_carry & s2_D) | (s2_sum & s2_D)) << 1;
        end
    end

    // --- Stage 4: CPA (Carry Propagate Adder) ---
    logic signed [47:0] s4_result;

    always_ff @(posedge clk) begin
        if (reset) s4_result <= 0;
        else       s4_result <= s3_sum + s3_carry;
    end


    // Output Assignment
    // Valid signal comes from the end of the 4-stage pipe (index 4)
    assign pushout = valid_pipe[3];
    assign Z       = s4_result;

endmodule

// ---------------------------------------------------------
// Module: fpa_top (Adder Tree Top Level)
// Description: Reduces 42 inputs to 1 output.
// ---------------------------------------------------------
module fpa_top (
    input  logic        clk,
    input  logic        reset,
    input  logic signed [47:0] inputs [0:41], // 42 Inputs
    input  logic        pushin,
    output logic        pushout,
    output logic signed [47:0] result
);

    // ======================================
    // Layer 1: 42 inputs -> 11 outputs
    // Need ceil(42/4) = 11 FPAs. 
    // ======================================
    logic signed [47:0] l1_out [0:10];
    logic               l1_pushout [0:10];
    
    genvar i;
    generate
        for (i = 0; i < 11; i++) begin : gen_l1
            logic signed [47:0] in_c, in_d;
            
            // Handle padding for the last block (i=10)
            // FPA 10 uses inputs 40, 41, 42(X), 43(X)
            assign in_c = ((i*4 + 2) < 42) ? inputs[i*4 + 2] : 48'sd0;
            assign in_d = ((i*4 + 3) < 42) ? inputs[i*4 + 3] : 48'sd0;

            fpa u_fpa_l1 (
                .clk(clk), .reset(reset),
                .A(inputs[i*4]),
                .B(inputs[i*4 + 1]),
                .C(in_c),
                .D(in_d),
                .pushin(pushin),
                .pushout(l1_pushout[i]),
                .Z(l1_out[i])
            );
        end
    endgenerate

    // ======================================
    // Layer 2: 11 inputs -> 3 outputs
    // Need ceil(11/4) = 3 FPAs.
    // ======================================
    logic signed [47:0] l2_out [0:2];
    logic               l2_pushout [0:2];

    generate
        for (i = 0; i < 3; i++) begin : gen_l2
            logic signed [47:0] in_b, in_c, in_d;
            
            assign in_b = ((i*4 + 1) < 11) ? l1_out[i*4 + 1] : 48'sd0;
            assign in_c = ((i*4 + 2) < 11) ? l1_out[i*4 + 2] : 48'sd0;
            assign in_d = ((i*4 + 3) < 11) ? l1_out[i*4 + 3] : 48'sd0;

            fpa u_fpa_l2 (
                .clk(clk), .reset(reset),
                // Use pushout from previous layer.
                // Since L1 blocks are parallel, l1_pushout[0] is representative.
                .pushin(l1_pushout[0]), 
                .pushout(l2_pushout[i]),
                .A(l1_out[i*4]),
                .B(in_b),
                .C(in_c),
                .D(in_d),
                .Z(l2_out[i])
            );
        end
    endgenerate

    // ======================================
    // Layer 3: 3 inputs -> 1 output
    // Need 1 FPA.
    // ======================================
    fpa u_fpa_l3 (
        .clk(clk), .reset(reset),
        .A(l2_out[0]),
        .B(l2_out[1]),
        .C(l2_out[2]),
        .D(48'sd0),             // Pad unused input
        .pushin(l2_pushout[0]),
        .pushout(pushout),      // Final Valid Signal
        .Z(result)              // Final Result
    );

endmodule
