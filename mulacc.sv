`include "calc_top.sv"

import defs::*; // System definitions provided by instructor

// -----------------------------------------------------------------------------
// Module Name: mulacc (Multiply Accumulate Engine)
// Description: EE272 Project Engine Implementation
//              Contains 3 interacting Logic Blocks: Bus Loader, FIFO Manager, Compute Feeder
// Version: v22 (Final Fix: FIFO Empty Logic to prevent Read-Write Race Condition)
// -----------------------------------------------------------------------------

module mulacc(
    input  logic        clk,
    input  logic        reset, // Active High Reset
    
    // RBUS Interface (Using struct typedefs from p25intr.sv)
    input  RBUS         bin,
    output RBUS         bout,
    
    // Result Interface (Using struct typedef from p25intr.sv)
    output RESULT       resout,
    
    // -------------------------------------------------------------------------
    // FIFORAM 1 (Data) Interface
    // -------------------------------------------------------------------------
    // Write Path (Used by Bus FSM to write to FIFO)
    output FifoAddr     f1wadr,  // Write Address (Wrapper naming fix: connects to wrapper f1in.wa)
    output FifoData     f1wdata, // Write Data
    output logic        f1write, // Write Enable
    
    // Read Path (Used by Compute FSM to read from FIFO)
    output FifoAddr     f1radr,  // Read Address (Wrapper naming fix: connects to wrapper f1out.ra)
    input  FifoData     f1rdata, // Read Data (Input)
    
    // -------------------------------------------------------------------------
    // FIFORAM 2 (Coef) Interface
    // -------------------------------------------------------------------------
    // Write Path
    output FifoAddr     f2wadr,
    output FifoData     f2wdata,
    output logic        f2write,
    
    // Read Path
    output FifoAddr     f2radr,
    input  FifoData     f2rdata,
    
    input  logic [3:0]  device_id
);

    // =========================================================================
    // 1. Internal Signal Aliasing & Address Encoding
    // =========================================================================
    // Purpose: Use clear, binary pointers internally for calculation.
    // Confirmed: FifoAddr is Binary Coded.
    // Mapping 3-bit internal pointer to 8-bit external address via Zero Extension.
    
    // --- FIFO Write Control (Driven by Bus FSM & FIFO FSM) ---
    // Internal use: 3-bit binary counters (0~7).
    logic [2:0]    fifo_wr_ptr_1; // Data FIFO Write Pointer (Binary)
    logic [2:0]    fifo_wr_ptr_2; // Coef FIFO Write Pointer (Binary)
    logic [1007:0] fifo_wr_data;  // Data to be written
    logic          fifo_wr_en_1;  
    logic          fifo_wr_en_2;  

    // [Binary Extension] Convert 3-bit Internal Ptr to 8-bit Address
    // Example: ptr=1 -> addr=00000001
    assign f1wadr  = {5'd0, fifo_wr_ptr_1}; 
    assign f1wdata = fifo_wr_data;
    assign f1write = fifo_wr_en_1;

    assign f2wadr  = {5'd0, fifo_wr_ptr_2}; 
    assign f2wdata = fifo_wr_data;
    assign f2write = fifo_wr_en_2;

    // --- FIFO Read Control (Driven by Compute FSM) ---
    // Internal use: 3-bit binary counter
    logic [2:0]    comp_rd_ptr;           // Read Pointer (Binary, shared by both FIFOs)
    logic [1007:0] fifo_rd_data_from_f1;  
    logic [1007:0] fifo_rd_data_from_f2;  

    // [Binary Extension] Convert 3-bit Internal Ptr to 8-bit Address
    assign f1radr  = {5'd0, comp_rd_ptr};
    assign fifo_rd_data_from_f1 = f1rdata; 

    assign f2radr  = {5'd0, comp_rd_ptr};
    assign fifo_rd_data_from_f2 = f2rdata; 


    // =========================================================================
    // 2. Inter-FSM Handshake Signals
    // =========================================================================
    
    // Bus FSM -> FIFO FSM
    logic          valid_data_arrival; // Pulse: Valid data received from bus
    logic          is_coef_type;       // 0 = Data, 1 = Coef
    
    // FIFO FSM -> Bus FSM
    logic [3:0]    vacancy_1;          // Data FIFO Remaining Space (Words)
    logic [3:0]    vacancy_2;          // Coef FIFO Remaining Space (Words)

    // FIFO FSM -> Compute FSM
    logic          fifo_empty;         // True if FIFO is empty OR about to be empty

    // Compute FSM -> FIFO FSM
    logic          word_consumed;      // Pulse: Compute FSM finished consuming one full Word

    // Bus FSM -> FIFO FSM & Compute FSM (Global Sync)
    logic          task_start;         // Critical: Pulse to reset all pointers at task start
    logic [31:0]   total_groups;       // Total groups for the current task


    // =========================================================================
    // 3. FSM 1: Bus Message FSM (The Loader)
    // =========================================================================
    // Responsibility: Handle RBUS protocol, Piggyback Token, Flow Control, move data to FIFO

    typedef enum logic [2:0] {
        BUS_RESET,         // Reset state
        BUS_IDLE,          // Idle: Wait for task or forward messages
        BUS_CALC_BURST,    // Calculate burst size for transmission
        BUS_SEND_REQ_DATA, // Send Read Request for Data
        BUS_WAIT_DATA,     // Wait for Data return
        BUS_SEND_REQ_COEF, // Send Read Request for Coef
        BUS_WAIT_COEF      // Wait for Coef return
    } bus_state_t;

    bus_state_t bus_curr_state, bus_next_state;

    // Task Parameter Registers (Stored from Write Req)
    logic [47:0] reg_DataAddress;
    logic [47:0] reg_CoefAddress;
    logic [31:0] reg_NumGroups;
    
    // Dynamic Address Tracking
    logic [47:0] cur_DataAddress;
    logic [47:0] cur_CoefAddress;

    // Flow Control Counters
    logic [31:0] total_words_needed; // Total Words needed for this task
    logic [31:0] words_fetched;      // Words already fetched
    logic [31:0] remaining_words;    // Remaining Words to fetch
    logic [3:0]  reg_burst_len;      // Actual Length sent to Memory (1-based: 1=1pkt, 8=8pkts)
    
    // Target Memory ID Calculation (Spec: MemID = DeviceID - 1)
    logic [3:0]  target_mem_id;
    assign target_mem_id = device_id - 4'd1;

    // Helper Calculation: 1 Word (1008-bit) = 2 Groups (Lower 504 + Upper 504)
    // If NumGroups is odd (e.g., 1), needs 1 Word. If 2, needs 1 Word.
    assign total_words_needed = (reg_NumGroups[0]) ? (reg_NumGroups >> 1) + 1 : (reg_NumGroups >> 1);
    assign remaining_words = total_words_needed - words_fetched;

    // Helper signal for signed comparison of incoming NumGroups
    logic signed [31:0] incoming_num_groups;
    assign incoming_num_groups = bin.Data[127:96];

    // --- [Refactored] Threshold & Limit Calculation Logic ---
    // Extracting this logic out of the FSM blocks to avoid duplication and errors.
    logic [31:0] space_limit;
    logic threshold_met;

    always_comb begin
        // Hardware constraint: FIFO depth is 8
        space_limit = (vacancy_1 >= 8) ? 32'd8 : {28'd0, vacancy_1};
        
        // Threshold: Space >= 4 OR Space enough for all remaining
        if (remaining_words > 0)
            threshold_met = (space_limit >= 4) || (space_limit >= remaining_words);
        else
            threshold_met = 0;
    end

    // --- Bus FSM Sequential Logic ---
    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            bus_curr_state <= BUS_RESET;
            reg_DataAddress <= '0;
            reg_CoefAddress <= '0;
            reg_NumGroups   <= '0;
            cur_DataAddress <= '0;
            cur_CoefAddress <= '0;
            words_fetched   <= '0;
            reg_burst_len   <= '0;
        end else begin
            bus_curr_state <= bus_next_state;

            // Internal Register Updates
            case (bus_curr_state)
                BUS_IDLE: begin
                    // Receive New Task (Write Req, Dst=Me, Token=1)
                    if (bin.Opcode == WRITE_REQ && bin.Destination == device_id && bin.Token == 1) begin
                        // Check if NumGroups > 0 (Positive Signed Integer)
                        if (incoming_num_groups > 0) begin
                            // Valid Task: Parse fields
                            reg_DataAddress <= bin.Data[47:0];
                            reg_CoefAddress <= bin.Data[95:48];
                            reg_NumGroups   <= bin.Data[127:96];
                            
                            // Initialize dynamic addresses and counters
                            cur_DataAddress <= bin.Data[47:0];
                            cur_CoefAddress <= bin.Data[95:48];
                            words_fetched   <= 0;
                        end
                        // Else: If NumGroups <= 0, do NOT update registers. 
                        // The Token will be passed in Comb logic.
                    end
                end

                BUS_CALC_BURST: begin
                    // Use the extracted threshold logic to latch the burst length
                    if (threshold_met) begin
                        if (remaining_words < space_limit)
                            reg_burst_len <= remaining_words[3:0]; // Fetch all remaining
                        else
                            reg_burst_len <= space_limit[3:0];     // Fetch max possible
                    end
                end

                BUS_WAIT_DATA: begin
                    // Monitor incoming Data for self, increment address for next use
                    if (bin.Opcode == RDATA && bin.Destination == device_id) begin
                        cur_DataAddress <= cur_DataAddress + 1;
                    end
                end

                BUS_WAIT_COEF: begin
                    // Monitor incoming Coef for self
                    if (bin.Opcode == RDATA && bin.Destination == device_id) begin
                        cur_CoefAddress <= cur_CoefAddress + 1;
                        if (bin.Token == 1) begin
                            // Received last packet (T=1), burst complete
                            // Update total fetched count (Length is 1-based, directly add)
                            words_fetched <= words_fetched + reg_burst_len;
                        end
                    end
                end
            endcase
        end
    end

    // --- Bus FSM Combinational Logic (Next State & Output) ---
    always_comb begin
        bus_next_state = bus_curr_state;
        
        // Default Output: Send IDLE (Token=0)
        bout = '{Opcode:IDLE, Source:device_id, Destination:0, Token:0, Data:'0};
        
        // Internal control signals defaults
        valid_data_arrival = 0;
        is_coef_type = 0;
        fifo_wr_data = bin.Data; // Direct connection from Bus data to FIFO input
        task_start = 0;

        case (bus_curr_state)
            BUS_RESET: begin
                // Output Empty during Reset
                bout = '{Opcode:EMPTY, Source:device_id, Destination:0, Token:0, Data:'0};
                if (!reset) bus_next_state = BUS_IDLE;
            end

            BUS_IDLE: begin
                if (bin.Opcode != IDLE && bin.Opcode != EMPTY && bin.Opcode != TOKEN_ONLY) begin
                    if (bin.Destination != device_id) begin
                        // 1. Forward messages not for me
                        bout = bin; 
                    end else if (bin.Opcode == WRITE_REQ && bin.Token == 1) begin
                        // 2. Received task for me (with Token)
                        if (incoming_num_groups > 0) begin
                            // Valid Task: Consume & Start
                            // Output TokenOnly (T=0) for current cycle consumption
                            bout = '{Opcode:TOKEN_ONLY, Source:device_id, Destination:0, Token:0, Data:'0};
                            
                            // Issue Pulse, notify other FSMs to reset pointers
                            task_start = 1; 
                            bus_next_state = BUS_CALC_BURST; // Implicitly holding Token
                        end else begin
                            // Invalid Task (NumGroups <= 0): Ignore & Pass Token
                            // Output TokenOnly with Token=1 immediately
                            bout = '{Opcode:TOKEN_ONLY, Source:device_id, Destination:0, Token:1, Data:'0};
                            
                            task_start = 0;
                            bus_next_state = BUS_IDLE; // Stay in IDLE
                        end
                    end
                end else if (bin.Opcode == TOKEN_ONLY) begin
                    // Forward ALL TokenOnly messages (both T=1 and T=0).
                    // T=0 is critical for the Hub's Initialization Handshake loop.
                    bout = bin; 
                end
            end

            BUS_CALC_BURST: begin
                if (remaining_words == 0) begin
                    // Task Complete, Release Token!
                    bout = '{Opcode:TOKEN_ONLY, Source:device_id, Destination:0, Token:1, Data:'0};
                    bus_next_state = BUS_IDLE; 
                end else begin
                    // Use the extracted threshold logic to determine transition
                    if (threshold_met && vacancy_1 > 0) begin
                        // Threshold met & Space available -> Initiate Request (Token held)
                        bus_next_state = BUS_SEND_REQ_DATA;
                    end
                    // Else: Stall in CALC_BURST (Sending IDLE T=0, holding Token safely)
                end
            end

            BUS_SEND_REQ_DATA: begin
                // Construct Read Req for Data (Piggyback Token T=1)
                logic [1007:0] req_payload;
                req_payload = '0;
                req_payload[47:0] = cur_DataAddress; // Address [47:0]
                
                // Length field is at [51:48]
                req_payload[51:48] = reg_burst_len; 

                bout = '{Opcode:READ_REQ, Source:device_id, Destination:target_mem_id, Token:1, Data:req_payload};
                // Hand over Token, enter Wait
                bus_next_state = BUS_WAIT_DATA;
            end

            BUS_WAIT_DATA: begin
                if (bin.Opcode == RDATA && bin.Destination == device_id) begin
                    valid_data_arrival = 1;
                    is_coef_type = 0; // Data Type
                    
                    // Consume message
                    bout = '{Opcode:TOKEN_ONLY, Source:device_id, Destination:0, Token:0, Data:'0};
                    
                    if (bin.Token == 1) begin
                        // Received last packet and regained Token -> Immediately fetch Coef (Zero Latency)
                        bus_next_state = BUS_SEND_REQ_COEF;
                    end
                end else if (bin.Destination != device_id && bin.Opcode != IDLE) begin
                    bout = bin; // Forward
                end
            end

            BUS_SEND_REQ_COEF: begin
                // Construct Read Req for Coef (Piggyback Token T=1)
                logic [1007:0] req_payload;
                req_payload = '0;
                req_payload[47:0] = cur_CoefAddress; // Address [47:0]
                
                // Length field is at [51:48]
                req_payload[51:48] = reg_burst_len; 

                bout = '{Opcode:READ_REQ, Source:device_id, Destination:target_mem_id, Token:1, Data:req_payload};
                bus_next_state = BUS_WAIT_COEF;
            end

            BUS_WAIT_COEF: begin
                if (bin.Opcode == RDATA && bin.Destination == device_id) begin
                    valid_data_arrival = 1;
                    is_coef_type = 1; // Coef Type
                    
                    // Consume message
                    bout = '{Opcode:TOKEN_ONLY, Source:device_id, Destination:0, Token:0, Data:'0};
                    
                    if (bin.Token == 1) begin
                        // Received last packet and regained Token -> Loop back to Calc Burst
                        bus_next_state = BUS_CALC_BURST;
                    end
                end else if (bin.Destination != device_id && bin.Opcode != IDLE) begin
                    bout = bin; // Forward
                end
            end
        endcase
    end
    
    // Output total groups to Compute FSM
    // [Fix v21] When task_start is high, pass Bus data directly to avoid timing gap.
    assign total_groups = (task_start) ? bin.Data[127:96] : reg_NumGroups;


    // =========================================================================
    // 4. FSM 2: FIFO FSM (Storage Manager)
    // =========================================================================
    // Responsibility: Maintain FIFO write pointers, calculate vacancy, handle simultaneous read/write
    
    logic [3:0] count_1; // Data FIFO Counter (0~8)
    logic [3:0] count_2; // Coef FIFO Counter (0~8)
    
    // [Fix v20] Moved variable declarations here for clarity
    logic write_1; // Internal signal: Data FIFO Write Enable
    logic write_2; // Internal signal: Coef FIFO Write Enable

    assign vacancy_1 = 4'd8 - count_1; // Data FIFO Vacancy
    assign vacancy_2 = 4'd8 - count_2; // Coef FIFO Vacancy
    
    // [Fix v22] Conservative FIFO Empty Logic
    // If count is 1 AND we are consuming it, force empty to stall Compute FSM.
    // This prevents reading valid address before new data is stable (Read-Write Race).
    assign fifo_empty = (count_1 == 0) || (count_1 == 1 && word_consumed) || 
                        (count_2 == 0) || (count_2 == 1 && word_consumed); 

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            fifo_wr_ptr_1 <= 0;
            fifo_wr_ptr_2 <= 0;
            count_1 <= 0;
            count_2 <= 0;
        end else begin
            // [Sync Fix] Forced reset at task start
            if (task_start) begin
                fifo_wr_ptr_1 <= 0; 
                fifo_wr_ptr_2 <= 0; 
                count_1 <= 0;
                count_2 <= 0;
            end else begin
                // --- FIFO 1 (Data) Logic ---
                if (write_1) fifo_wr_ptr_1 <= fifo_wr_ptr_1 + 1; 

                // Counter Update: Handle simultaneous write(Bus) and consume(Compute)
                case ({write_1, word_consumed})
                    2'b10: if (count_1 < 8) count_1 <= count_1 + 1; // Write Only
                    2'b01: if (count_1 > 0) count_1 <= count_1 - 1; // Read Only
                    2'b11: count_1 <= count_1; // Both (No change)
                    default: count_1 <= count_1;
                endcase

                // --- FIFO 2 (Coef) Logic ---
                if (write_2) fifo_wr_ptr_2 <= fifo_wr_ptr_2 + 1; 

                case ({write_2, word_consumed})
                    2'b10: if (count_2 < 8) count_2 <= count_2 + 1;
                    2'b01: if (count_2 > 0) count_2 <= count_2 - 1;
                    2'b11: count_2 <= count_2; 
                    default: count_2 <= count_2;
                endcase
            end
        end
    end
    
    // Write Enable Combinational Logic
    always_comb begin
        write_1 = 0;
        write_2 = 0;
        if (valid_data_arrival) begin
            if (is_coef_type == 0) write_1 = 1;
            else                   write_2 = 1;
        end
    end
    
    // Drive external/module-level write enable signals
    assign fifo_wr_en_1 = write_1;
    assign fifo_wr_en_2 = write_2;


    // =========================================================================
    // 5. FSM 3: Compute FSM (The Feeder)
    // =========================================================================
    // Responsibility: Read Word from FIFO, disassemble into Sets (Ping-Pong), Feed Pipeline
    
    typedef enum logic [2:0] {
        COMP_IDLE,
        COMP_FETCH_LOWER, // Phase 0: Read FIFO, push Lower half, save Upper half
        COMP_EXEC_UPPER,  // Phase 1: Push Saved Upper half
        COMP_WAIT_DATA    // Stall: Waiting for data
    } comp_state_t;

    comp_state_t comp_curr_state, comp_next_state;

    // [Fix v20] Removed duplicate declaration of comp_rd_ptr
    
    logic [31:0] rem_feeder_groups;  // Remaining groups to feed
    
    // Result Signals from Wrapper
    logic [47:0] adder_tree_out;     
    logic        adder_tree_pushout; 
    
    // Ping-Pong Buffer Registers
    logic [503:0] holding_data_upper;
    logic [503:0] holding_coef_upper;
    
    // Wrapper Control Signals
    logic pushin;
    logic [503:0] pipe_in_data;
    logic [503:0] pipe_in_coef;
    
    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            comp_curr_state <= COMP_IDLE;
            comp_rd_ptr <= 0;
            rem_feeder_groups <= 0;
            holding_data_upper <= '0;
            holding_coef_upper <= '0;
        end else begin
            comp_curr_state <= comp_next_state;
            
            // [Sync Fix] Reset pointer at task start
            if (task_start) begin
                rem_feeder_groups <= total_groups;
                comp_rd_ptr <= 0; 
            end else begin
                case (comp_curr_state)
                    COMP_FETCH_LOWER: begin
                        // Read happens here, latch Upper Half for next phase
                        holding_data_upper <= fifo_rd_data_from_f1[1007:504];
                        holding_coef_upper <= fifo_rd_data_from_f2[1007:504];
                        if (rem_feeder_groups > 0) rem_feeder_groups <= rem_feeder_groups - 1;
                    end
                    
                    COMP_EXEC_UPPER: begin
                        // Word consumed, move pointer
                        comp_rd_ptr <= comp_rd_ptr + 1; 
                        if (rem_feeder_groups > 0) rem_feeder_groups <= rem_feeder_groups - 1;
                    end
                endcase
            end
        end
    end

    always_comb begin
        comp_next_state = comp_curr_state;
        
        pushin = 0;
        word_consumed = 0;
        pipe_in_data = '0;
        pipe_in_coef = '0;

        case (comp_curr_state)
            COMP_IDLE: begin
                if (rem_feeder_groups > 0 && !fifo_empty) begin
                    comp_next_state = COMP_FETCH_LOWER;
                end
            end

            COMP_FETCH_LOWER: begin
                // Use Lower Half
                pushin = 1;
                pipe_in_data = fifo_rd_data_from_f1[503:0];
                pipe_in_coef = fifo_rd_data_from_f2[503:0];
                
                if (rem_feeder_groups == 1) begin
                    // Boundary Case: Last group of odd count
                    // Although only half word used, entire word is consumed
                    word_consumed = 1; 
                    comp_next_state = COMP_IDLE; 
                end else begin
                    comp_next_state = COMP_EXEC_UPPER;
                end
            end

            COMP_EXEC_UPPER: begin
                // Use Saved Upper Half
                pushin = 1;
                pipe_in_data = holding_data_upper;
                pipe_in_coef = holding_coef_upper;
                
                // Real consumption of a full Word (Notify FIFO FSM)
                word_consumed = 1; 

                if (rem_feeder_groups == 1) begin
                    comp_next_state = COMP_IDLE; 
                end else begin
                    if (fifo_empty) comp_next_state = COMP_WAIT_DATA;
                    else            comp_next_state = COMP_FETCH_LOWER;
                end
            end

            COMP_WAIT_DATA: begin
                pushin = 0; // Stall pipeline
                // Wait for FIFO water
                if (!fifo_empty) comp_next_state = COMP_FETCH_LOWER;
            end
        endcase
    end

    // =========================================================================
    // 6. Result Output
    // =========================================================================
    // [Fix v21] Reset Protection for Result Interface
    assign resout.result  = (reset) ? 48'd0 : adder_tree_out;
    assign resout.pushOut = (reset) ? 1'b0  : adder_tree_pushout;


    // =========================================================================
    // 7. Compute Module Instantiation & Connection
    // =========================================================================
    /* Instantiate your Calculator Wrapper here */
    
    calc_top u_calc_top (
        .clk     (clk),
        .reset   (reset),
        
        // Control Signal
        .pushin  (pushin),             // From FSM: Start calculation
        
        // Data Inputs (Flattened Vectors)
        .data_in (pipe_in_data),       // Vector of 42 data samples (504 bits)
        .coef_in (pipe_in_coef),       // Vector of 42 coefficients (504 bits)
        
        // Outputs
        .pushout (adder_tree_pushout), // To FSM: Result is valid
        .result  (adder_tree_out)      // To FSM: Final accumulated result
    );

endmodule

