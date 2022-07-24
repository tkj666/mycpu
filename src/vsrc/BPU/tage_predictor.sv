// TAGE predictor
// This is the main predictor

`include "defines.sv"
`include "core_config.sv"
`include "BPU/include/bpu_defines.sv"
`include "BPU/include/bpu_types.sv"

`include "utils/cva5_priority_encoder.sv"
`include "utils/lfsr.sv"

// Components
`include "BPU/components/base_predictor.sv"
`include "BPU/components/tagged_predictor.sv"


module tage_predictor
    import core_config::*;
    import bpu_types::*;
(
    input logic clk,
    input logic rst,

    // Query signal
    input logic [ADDR_WIDTH-1:0] pc_i,
    output bpu_ftq_meta_t bpu_meta_o,
    output logic predict_branch_taken_o,
    output logic predict_valid_o,

    // Update signals
    input logic [ADDR_WIDTH-1:0] update_pc_i,
    input tage_predictor_update_info_t update_info_i,

    // PMU
    output logic [5*32-1:0] perf_tag_hit_counter
);

    // Parameters
    localparam GHR_DEPTH = BPU_GHR_LENGTH;
    localparam TAG_COMPONENT_AMOUNT = BPU_TAG_COMPONENT_NUM;
    localparam integer HISTORY_LENGTH[TAG_COMPONENT_AMOUNT] = BPU_COMPONENT_HISTORY_LENGTH;
    localparam integer PHT_DEPTH[TAG_COMPONENT_AMOUNT+1] = BPU_COMPONENT_TABLE_DEPTH;


    // Reset
    logic rst_n;
    assign rst_n = ~rst;

    // Signals
    // Query
    logic [TAG_COMPONENT_AMOUNT:0] taken;  // All components taken {tag_taken, base_taken}
    // Base predictor
    logic base_taken;
    logic [BPU_COMPONENT_CTR_WIDTH[0]-1:0] base_ctr;
    // Tagged predictor
    // The provider id of the accepted prediction, selected using priority encoder
    logic [$clog2(TAG_COMPONENT_AMOUNT+1)-1:0] pred_prediction_id;
    // The provider id of the last hit provider
    logic [$clog2(TAG_COMPONENT_AMOUNT+1)-1:0] altpred_prediction_id;
    // For example, provider 2,4 hit, and provider 1,3 missed
    // then pred is 4, and altpred is 2
    logic [TAG_COMPONENT_AMOUNT-1:0] tag_taken;
    logic [TAG_COMPONENT_AMOUNT-1:0] tag_hit;
    logic query_is_useful;  // Indicates whether the pred component is useful

    // Meta
    logic [TAG_COMPONENT_AMOUNT-1:0][2:0] tag_ctr;
    logic [TAG_COMPONENT_AMOUNT-1:0][2:0] tag_useful;
    logic [TAG_COMPONENT_AMOUNT-1:0][15:0] tag_query_tag;
    logic [TAG_COMPONENT_AMOUNT-1:0][15:0] tag_orgin_tag;
    logic [TAG_COMPONENT_AMOUNT-1:0][15:0] tag_hit_index;

    // Update
    logic [ADDR_WIDTH-1:0] update_pc;
    logic base_update_ctr;
    logic update_valid;
    logic update_predict_correct;
    logic update_branch_taken;
    logic update_is_conditional;
    logic [$clog2(TAG_COMPONENT_AMOUNT+1)-1:0] update_provider_id;
    logic [TAG_COMPONENT_AMOUNT:0] update_ctr;  // Whether a component should updated its ctr
    logic [TAG_COMPONENT_AMOUNT-1:0] tag_update_ctr;
    logic [TAG_COMPONENT_AMOUNT-1:0] tag_update_useful;
    logic [TAG_COMPONENT_AMOUNT-1:0] tag_update_inc_useful;
    logic [TAG_COMPONENT_AMOUNT-1:0] tag_update_realloc_entry;
    logic [TAG_COMPONENT_AMOUNT-1:0][BPU_COMPONENT_USEFUL_WIDTH[1]-1:0] tag_update_query_useful;
    // Indicates the longest history component which useful is 0
    logic [$clog2(TAG_COMPONENT_AMOUNT+1)-1:0] tag_update_useful_zero_id;

    // pingpong counter & lfsr
    // is a random number array
    logic [31:0] random_r;
    logic [1:0] tag_update_useful_pingpong_counter[TAG_COMPONENT_AMOUNT];

    ////////////////////////////////////////////////////////////////////////////////////////////
    // END of Defines
    ////////////////////////////////////////////////////////////////////////////////////////////



    // Global History Register
    logic [GHR_DEPTH-1:0] GHR;
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            GHR <= 0;
        end else if (update_valid) begin
            // Shift left for every valid branch
            GHR <= {GHR[GHR_DEPTH-2:0], update_branch_taken};
        end
    end




    ////////////////////////////////////////////////////////////////////////////////////////////
    // Query Logic
    ////////////////////////////////////////////////////////////////////////////////////////////

    // Base Predictor
    base_predictor u_base_predictor (
        .clk         (clk),
        .rst         (rst),
        .pc_i        (pc_i),
        .update_valid(base_update_ctr),
        .taken       (base_taken),
        .ctr         (base_ctr),
        .update_pc_i (update_pc),
        .inc_ctr     (update_branch_taken),
        .update_ctr_i(update_info_i.provider_ctr_bits)
    );
    // Tagged Predictor
    generate
        for (
            genvar provider_id = 0; provider_id < TAG_COMPONENT_AMOUNT; provider_id++
        ) begin : tagged_gen
            tagged_predictor #(
                .INPUT_GHR_LENGTH(HISTORY_LENGTH[provider_id+1]),
                .PHT_DEPTH(PHT_DEPTH[provider_id+1]),
                .PHT_USEFUL_WIDTH(BPU_COMPONENT_USEFUL_WIDTH[provider_id+1])
            ) u_tagged_predictor (
                .clk                 (clk),
                .rst                 (rst),
                .global_history_i    (GHR[HISTORY_LENGTH[provider_id]:0]),
                .pc_i                (pc_i),
                .useful_bits_o       (tag_useful[provider_id]),
                .ctr_bits_o          (tag_ctr[provider_id]),
                .query_tag_o         (tag_query_tag[provider_id]),
                .origin_tag_o        (tag_orgin_tag[provider_id]),
                .hit_index_o         (tag_hit_index[provider_id]),
                .taken_o             (tag_taken[provider_id]),
                .tag_hit_o           (tag_hit[provider_id]),
                .update_valid        (update_valid),
                .update_useful       (tag_update_useful[provider_id]),
                .inc_useful          (tag_update_inc_useful[provider_id]),
                .update_useful_bits_i(),
                .update_ctr          (tag_update_ctr[provider_id]),
                .inc_ctr             (update_branch_taken),
                .update_ctr_bits_i   (update_info_i.provider_ctr_bits),
                .update_tag_i        (),
                .update_index_i      ()
            );
        end
    endgenerate

    assign query_is_useful = (taken[pred_prediction_id] != taken[altpred_prediction_id]);

    // Select the longest match provider
    cva5_priority_encoder #(
        .WIDTH(5)
    ) pred_select (
        .priority_vector({tag_hit, 1'b1}),
        .encoded_result (pred_prediction_id)
    );
    // Select altpred
    logic [TAG_COMPONENT_AMOUNT:0] altpred_pool;
    always_comb begin
        altpred_pool = {tag_hit, 1'b1};
        if (pred_prediction_id != 0) begin
            altpred_pool[pred_prediction_id] = 1'b0;
        end
    end
    cva5_priority_encoder #(
        .WIDTH(5)
    ) altpred_select (
        .priority_vector(altpred_pool),
        .encoded_result (altpred_prediction_id)
    );

    // Output logic
    assign predict_valid_o = 1;
    assign taken = {tag_taken, base_taken};
    assign predict_branch_taken_o = taken[pred_prediction_id];
    // Meta
    assign bpu_meta_o.provider_ctr_bits = base_ctr;






    ////////////////////////////////////////////////////////////////////////////////////////////
    // Update policy
    ////////////////////////////////////////////////////////////////////////////////////////////

    // CTR policy
    // Update on a correct prediction: update the ctr bits of the provider
    // Update on a wrong prediction: update the ctr bits of the provider, then allocate an entry in a longer history component
    // Useful policy
    // if pred != altpred, then the pred is useful, and the provider is updated when result come
    // if pred is correct, then increase useful counter, else decrese


    // Update structs
    assign tag_update_ctr = update_ctr[TAG_COMPONENT_AMOUNT:1];
    assign base_update_ctr = update_ctr[0];
    // update-prefixed signals are updated related 
    assign update_valid = update_info_i.valid;
    assign update_predict_correct = update_info_i.predict_correct;
    assign update_branch_taken = update_info_i.branch_taken;
    assign update_is_conditional = update_info_i.is_conditional;
    assign update_provider_id = update_info_i.pred_provider_id;
    assign update_pc = update_pc_i;

    assign tag_update_query_useful = update_info_i.tag_predictor_useful_bits;



    // Get the ID of desired allocate component
    // This block finds the ID of useful == 0 component
    logic [TAG_COMPONENT_AMOUNT-1:0] tag_update_query_useful_match;
    always_comb begin
        for (integer i = 0; i < TAG_COMPONENT_AMOUNT; i++) begin
            tag_update_query_useful_match[i] = (tag_update_query_useful[i] == 0);
        end
    end
    // Allocation policy, according to TAGE essay
    // Shorter history component has a higher chance of chosen
    always_comb begin
        tag_update_useful_zero_id = 0;  // default 0
        for (integer i = TAG_COMPONENT_AMOUNT - 1; i >= 0; i--) begin
            if (tag_update_query_useful_match[i]) begin
                // 1/2 probability when longer history tag want to be selected
                if (tag_update_useful_pingpong_counter[i] != 2'b00) begin
                    tag_update_useful_zero_id = i + 1;
                end
            end
        end
    end

    // LFSR & Ping-pong counter
    lfsr #(
        .WIDTH(32),
    ) u_pingpong_lfsr (
        .clk  (clk),
        .rst  (rst),
        .en   (1'b1),
        .value(random_r)
    );
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (integer i = 0; i < TAG_COMPONENT_AMOUNT; i++) begin
                tag_update_useful_pingpong_counter[i] <= 2'b00;
            end
        end else begin
            tag_update_useful_pingpong_counter[0] <= random_r[1:0];
            for (integer i = 1; i < TAG_COMPONENT_AMOUNT; i++) begin
                tag_update_useful_pingpong_counter[i] <= tag_update_useful_pingpong_counter[i-1];
            end
        end
    end




    // Fill update structs
    // update_ctr
    always_comb begin : update_ctr_policy
        // update_ctr, default 0
        for (integer i = 0; i < TAG_COMPONENT_AMOUNT + 1; i++) begin
            update_ctr[i] = 1'b0;
        end
        if (update_is_conditional) begin  // Only update on conditional branches
            update_ctr[update_provider_id] = 1'b1;  // One hot
        end
    end

    // tag_update_useful & tag_update_inc_useful & tag_update_realloc_entry
    always_comb begin : tag_update_policy
        // Default 0
        for (integer i = 0; i < TAG_COMPONENT_AMOUNT; i++) begin
            tag_update_useful[i] = 1'b0;
            tag_update_inc_useful[i] = 1'b0;
            tag_update_realloc_entry[i] = 1'b0;
        end
        if (update_is_conditional) begin  // Only update on conditional branches
            // If useful, update useful bits
            tag_update_useful[update_provider_id-1] = update_info_i.pred_useful;
            // Increase if correct, else decrease
            tag_update_inc_useful[update_provider_id-1] = update_info_i.predict_correct;

            // Allocate new entry if mispredict
            if (~update_info_i.predict_correct) begin
                // Allocate entry in longer history component
                if (tag_update_useful_zero_id > update_provider_id) begin  // Have found a slot to allocate
                    tag_update_realloc_entry[tag_update_useful_zero_id-1] = 1'b1;
                end else begin  // No slot to allocate, decrease all useful bits of longer history components
                    for (integer i = 0; i < TAG_COMPONENT_AMOUNT; i++) begin
                        if (i >= update_provider_id - 1) begin
                            tag_update_useful[i] = 1'b1;
                            tag_update_inc_useful[i] = 1'b0;
                        end
                    end
                end
            end
        end
    end


    // Counter
    generate
        genvar i;
        for (i = 0; i < 5; i = i + 1) begin
            always @(posedge clk) begin
                perf_tag_hit_counter[i*32+31:i*32] <= perf_tag_hit_counter[i*32+31:i*32] + {31'b0,(i == pred_prediction_id)};
            end
        end
    endgenerate




endmodule  // tage_predictor
