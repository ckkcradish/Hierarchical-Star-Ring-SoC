`include "sub_hub.sv"
// -----------------------------------------------------------------------------
// Module Name: hub (Top-Level Hub)
// Description: Contains 1 TB Controller and 4 Engine Sub-Hubs.
//              Responsible for routing Write Requests from the TB to the
//              correct Sub-Hub.
// Version: v2 (Token Mirroring Update)
// -----------------------------------------------------------------------------

import defs::*; // Import definitions package

module hub (
    input  logic clk,
    input  logic reset, // Active High Reset

    // TB Ring Interface
    input  RBUS tbin,
    output RBUS tbout,

    // Engine Ring 0 Interface
    input  RBUS R0in,
    output RBUS R0out,

    // Engine Ring 1 Interface
    input  RBUS R1in,
    output RBUS R1out,

    // Engine Ring 2 Interface
    input  RBUS R2in,
    output RBUS R2out,

    // Engine Ring 3 Interface
    input  RBUS R3in,
    output RBUS R3out
);

    // =========================================================================
    // 1. TB Ring Controller (Main Control Logic)
    // =========================================================================
    // Responsibilities:
    // 1. Initialize the TB Ring.
    // 2. Receive Write Requests from TB.
    // 3. [Update] Token Mirroring: Decide the outgoing TokenOnly T value
    //    based on the input T value.
    // 4. Dispatch the Write Request to the corresponding Sub-Hub.

    typedef enum logic [1:0] {
        TB_RESET,
        TB_INIT_SWEEP,
        TB_ACTIVE
    } tb_state_t;

    tb_state_t tb_state, tb_next_state;

    // Routing signals
    logic [3:0] write_req_dest;
    logic       write_req_valid;
    RBUS        write_req_data;

    // FSM: Manages TB Ring initialization and reception
    always_ff @(posedge clk or posedge reset) begin
        if (reset) tb_state <= TB_RESET;
        else       tb_state <= tb_next_state;
    end

    always_comb begin
        tb_next_state = tb_state;
        
        // Default: forward TB messages
        tbout = tbin;
        
        // Router default values
        write_req_valid = 0;
        write_req_data  = tbin; // Default source data
        write_req_dest  = tbin.Destination;

        case (tb_state)
            TB_RESET: begin
                tbout = '{Opcode:EMPTY, Source:0, Destination:0, Token:0, Data:'0};
                if (!reset) tb_next_state = TB_INIT_SWEEP;
            end

            TB_INIT_SWEEP: begin
                // Force sending TokenOnly(T=0) until echo is received
                tbout = '{Opcode:TOKEN_ONLY, Source:0, Destination:0, Token:0, Data:'0};
                
                if (tbin.Opcode == TOKEN_ONLY && tbin.Token == 0) begin
                    // Loop closed, inject Token (T=1)
                    tbout = '{Opcode:TOKEN_ONLY, Source:0, Destination:0, Token:1, Data:'0};
                    tb_next_state = TB_ACTIVE;
                end
            end

            TB_ACTIVE: begin
                // 1. When Idle/Empty -> output T=0
                if (tbin.Opcode == IDLE || tbin.Opcode == EMPTY) begin
                    tbout = '{Opcode:TOKEN_ONLY, Source:0, Destination:0, Token:0, Data:'0};
                end
                
                // 2. Receive Write Req (from TB)
                else if (tbin.Opcode == WRITE_REQ) begin
                    // Hub consumes this message and replies with TokenOnly
                    // [Update] Token Mirroring:
                    // If TB sends T=1 (Piggyback), we return T=1 (release)
                    // If TB sends T=0 (Hold), we return T=0 (hold)
                    tbout = '{Opcode:TOKEN_ONLY, Source:0, Destination:0, Token:tbin.Token, Data:'0};
                    
                    // Trigger routing logic (Store)
                    write_req_valid = 1;
                end
                
                // 3. Received TokenOnly (T=1)
                else if (tbin.Opcode == TOKEN_ONLY && tbin.Token == 1) begin
                    // Simply forward token
                    tbout = tbin;
                end
            end
        endcase
    end


    // =========================================================================
    // 2. Router (Router / Demux)
    // =========================================================================
    // Distribute the Write Req from TB to the 4 Engine Sub-Hubs
    
    logic task_valid_0, task_valid_1, task_valid_2, task_valid_3;

    always_comb begin
        task_valid_0 = 0;
        task_valid_1 = 0;
        task_valid_2 = 0;
        task_valid_3 = 0;

        if (write_req_valid) begin
            case (write_req_dest)
                4'd9:  task_valid_0 = 1; // Device 0
                4'd11: task_valid_1 = 1; // Device 1
                4'd13: task_valid_2 = 1; // Device 2
                4'd15: task_valid_3 = 1; // Device 3
                default: ; // Invalid address, drop
            endcase
        end
    end


    // =========================================================================
    // 3. Instantiate 4 Engine Sub-Hubs
    // =========================================================================
    // Each Sub-Hub independently manages an Engine Ring’s token and task dispatch

    sub_hub u_sub_hub_0 (
        .clk(clk), .reset(reset),
        .task_valid(task_valid_0), .task_data(write_req_data),
        .ring_in(R0in), .ring_out(R0out)
    );

    sub_hub u_sub_hub_1 (
        .clk(clk), .reset(reset),
        .task_valid(task_valid_1), .task_data(write_req_data),
        .ring_in(R1in), .ring_out(R1out)
    );

    sub_hub u_sub_hub_2 (
        .clk(clk), .reset(reset),
        .task_valid(task_valid_2), .task_data(write_req_data),
        .ring_in(R2in), .ring_out(R2out)
    );

    sub_hub u_sub_hub_3 (
        .clk(clk), .reset(reset),
        .task_valid(task_valid_3), .task_data(write_req_data),
        .ring_in(R3in), .ring_out(R3out)
    );

endmodule : hub
