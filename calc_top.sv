`include "fpm.sv"
`include "fpa.sv" // Includes fpa and fpa_top
`timescale 1ns / 1ps

module calc_top (
    input  logic         clk,
    input  logic         reset,
    
    // Control Signal
    input  logic         pushin,      
    
    // Data Inputs (Flattened Vectors)
    input  logic [503:0] data_in,     
    input  logic [503:0] coef_in,     
    
    // Outputs
    output logic         pushout,     
    output logic [47:0]  result       
);

    // 1. Internal Signals & Unpacking
    logic [11:0] data_array [0:41];
    logic [11:0] coef_array [0:41];
    
    // [Change] Wires connecting FPM outputs to FPA tree inputs are now 48-bit
    logic signed [47:0] fpm_results [0:41];
    logic               fpm_pushouts [0:41]; 

    // Unpack the flattened input vectors
    always_comb begin
        for (int i = 0; i < 42; i++) begin
            data_array[i] = data_in[(i*12) +: 12];
            coef_array[i] = coef_in[(i*12) +: 12];
        end
    end

    // 2. Instantiate 42 Multipliers (FPM)
    genvar i;
    generate
        for (i = 0; i < 42; i++) begin : gen_fpm
            fpm u_fpm (
                .clk(clk),
                .reset(reset),
                .A(data_array[i]),
                .B(coef_array[i]),
                .pushin(pushin),
                .pushout(fpm_pushouts[i]),
                .Z(fpm_results[i])       // Output is now 48-bit Fixed Point
            );
        end
    endgenerate

    // 3. Instantiate Adder Tree (FPA_TOP)
    fpa_top u_adder_tree (
        .clk(clk),
        .reset(reset),
        .inputs(fpm_results),        // Feed all 42 fixed-point results
        .pushin(fpm_pushouts[0]),    // Use valid signal from first FPM
        .pushout(pushout),           // Final valid signal out to FSM
        .result(result)              // Final 48-bit sum
    );

endmodule
