// -----------------------------------------------------------------------------
// Module Name: sub_hub (Sub-Hub for Engine Side)
// Description: Responsible for managing communication for a single Engine Ring
//              (Ring 0~3).
//              1. Handles ring initialization (send T=0 sweep, then inject T=1
//                 once echo is received).
//              2. Buffers Write Requests received from the TB.
//              3. When a Token (T=1) is received, intercepts the token and
//                 sends the buffered task.
// -----------------------------------------------------------------------------
import defs::*;
module sub_hub (
    input  logic clk,
    input  logic reset, // Active High Reset

    // Interface connected to the Top Hub Router (receiving tasks)
    input  logic        task_valid, // Router indicates a new task is available
    input  RBUS         task_data,  // Task content (Write Req)
    
    // Interface connected to the Engine/Mem Ring
    input  RBUS         ring_in,    // Ring input
    output RBUS         ring_out    // Ring output
);

    // FSM state definitions
    typedef enum logic [2:0] {
        S_RESET,        // Reset state
        S_INIT_SWEEP,   // Initialization sweep: send TokenOnly(T=0)
        S_ACTIVE,       // Normal operation: forward or send a task
        S_SEND_PREP     // Send preparation: token captured, occupy the bus
                        // for one cycle (send T=0)
    } state_t;

    state_t current_state, next_state;

    // Task buffer (Store-and-Forward)
    // Since TB issues requests sequentially (waits for result before sending
    // the next), depth=1 is sufficient.
    RBUS  task_buffer;
    logic has_pending_task;

    // -------------------------------------------------------------------------
    // 1. Task Buffer Logic (Task Buffering)
    // -------------------------------------------------------------------------
    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            task_buffer      <= '0;
            has_pending_task <= 0;
        end else begin
            // Write into buffer: when router sends data and we currently have
            // no pending task (or upper layer guarantees no overflow)
            if (task_valid) begin
                task_buffer      <= task_data;
                has_pending_task <= 1;
            end
            // Clear buffer: after task is successfully sent (the cycle after
            // S_SEND_PREP)
            else if (current_state == S_SEND_PREP) begin
                has_pending_task <= 0;
            end
        end
    end

    // -------------------------------------------------------------------------
    // 2. Main FSM (Main State Machine)
    // -------------------------------------------------------------------------
    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            current_state <= S_RESET;
        end else begin
            current_state <= next_state;
        end
    end

    always_comb begin
        next_state = current_state;
        
        // Default output: forward ring input (pass-through)
        ring_out = ring_in; 

        case (current_state)
            S_RESET: begin
                // During reset, output Empty
                ring_out = '{Opcode:EMPTY, Source:0, Destination:0, Token:0, Data:'0};
                if (!reset) next_state = S_INIT_SWEEP;
            end

            S_INIT_SWEEP: begin
                // Initialization sweep: force output TokenOnly(T=0)
                ring_out = '{Opcode:TOKEN_ONLY, Source:0, Destination:0, Token:0, Data:'0};

                // Check whether we received our own TokenOnly(T=0)
                // Note: This also handles the rule that receiving Idle/Empty
                // should be converted into TokenOnly(T=0)
                if (ring_in.Opcode == TOKEN_ONLY && ring_in.Token == 0) begin
                    // Loop closure detected; enter Active and inject Token (T=1)
                    // Here we simply switch state—next cycle S_ACTIVE will
                    // handle the injection logic.
                    next_state = S_ACTIVE;

                    // Special case: do we need to send T=1 in this same cycle?
                    // According to the protocol, when the Hub receives T=0,
                    // it forwards T=1.
                    ring_out = '{Opcode:TOKEN_ONLY, Source:0, Destination:0, Token:1, Data:'0};
                end
            end

            S_ACTIVE: begin
                // -------------------------------------------------------------
                // Rule 1: Receiving Idle or Empty -> force output TokenOnly(T=0)
                // -------------------------------------------------------------
                if (ring_in.Opcode == IDLE || ring_in.Opcode == EMPTY) begin
                    ring_out = '{Opcode:TOKEN_ONLY, Source:0, Destination:0, Token:0, Data:'0};
                end
                
                // -------------------------------------------------------------
                // Rule 2: Receive TokenOnly(T=1) AND we have a pending task
                //         -> Capture Token
                // -------------------------------------------------------------
                else if (ring_in.Opcode == TOKEN_ONLY && ring_in.Token == 1) begin
                    if (has_pending_task) begin
                        // Capture token:
                        // 1. This cycle: output TokenOnly(T=0) to hold the bus
                        ring_out = '{Opcode:TOKEN_ONLY, Source:0, Destination:0, Token:0, Data:'0};
                        // 2. Next cycle prepare to send task
                        next_state = S_SEND_PREP;
                    end else begin
                        // No pending task → simply forward Token(T=1)
                        ring_out = ring_in;
                    end
                end
                
                // Other cases (e.g., ReadReq, RData): directly forward
                // In Star Topology, all Engines are on the same local ring;
                // the Hub acts as a bridge here.
            end

            S_SEND_PREP: begin
                // Task sending state (Piggyback Token)
                // We already occupied the bus last cycle; now send Write Req
                ring_out = task_buffer;
                ring_out.Token = 1; // Rule: Write Req must piggyback Token(T=1)
                
                // Task sent; return to Active state
                next_state = S_ACTIVE;
            end
        endcase
    end

endmodule : sub_hub
