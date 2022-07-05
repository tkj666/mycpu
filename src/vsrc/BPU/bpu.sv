// BPU is the Branch Predicting Unit
// BPU does the following things:
// 1. accept update info from FTQ
// 2. provide update to tage predictor
// 3. send pc into tage predictor and generate FTQ block

`include "core_config.sv"
`include "core_types.sv"
`include "BPU/include/bpu_types.sv"
`include "frontend/frontend_defines.sv"

`include "BPU/components/ftb.sv"
`include "BPU/tage_predictor.sv"


module bpu
    import core_config::*;
    import core_types::*;
    import bpu_types::*;
(
    input logic clk,
    input logic rst,

    // FTQ
    // Predict
    input [ADDR_WIDTH-1:0] pc_i,
    input logic ftq_full_i,
    output bpu_ftq_t ftq_predict_o,
    // Train
    input ftq_bpu_meta_t ftq_meta_i

    // PMU
    // TODO: use PMU to monitor miss-prediction rate and each component useful rate

);
    ////////////////////////////////////////////////////////////////////////////////////
    // Query logic
    ////////////////////////////////////////////////////////////////////////////////////
    // FTB
    logic ftb_hit;
    ftb_entry_t ftb_entry;
    // TAGE
    logic predict_taken, predict_valid;


    // FTQ Output generate
    logic is_cross_page;
    assign is_cross_page = pc_i[11:0] > 12'hff0;  // if 4 instr already cross the page limit
    always_comb begin
        if (ftb_hit & predict_valid) begin  // There is a branch within FETCH_WIDTH
            // TODO: check cross page
            ftq_predict_o.valid = 1;
            ftq_predict_o.is_cross_cacheline = ftb_entry.is_cross_cacheline;
            ftq_predict_o.start_pc = pc_i;
            ftq_predict_o.length = predict_taken ? ftb_entry.fall_through_address - pc_i : FETCH_WIDTH;
        end else begin  // No branch is recorded, generate full FETCH_WIDTH
            if (is_cross_page) begin
                ftq_predict_o.length = (12'h000 - pc_i[11:0]) >> 2;
            end else begin
                ftq_predict_o.length = 4;
            end
            ftq_predict_o.start_pc = pc_i;
            ftq_predict_o.valid = 1;
            // If cross page, length will be cut, so ensures no cacheline cross
            ftq_predict_o.is_cross_cacheline = (pc_i[3:2] != 2'b00) & ~is_cross_page;
        end
    end

    ftb u_ftb (
        .clk(clk),
        .rst(rst),

        // Query
        .query_pc_i(pc_i),
        .query_entry_o(ftb_entry),
        .hit(ftb_hit),

        // Update
        .update_pc_i(),
        .update_valid_i(),
        .update_entry_i()
    );

    tage_predictor u_tage_predictor (
        .clk                      (clk),
        .rst                      (rst),
        .pc_i                     (pc_i),
        .base_predictor_update_i  (),
        .predicted_branch_target_o(),
        .predict_branch_taken_o   (predict_taken),
        .predict_valid_o          (predict_valid_o),
        .perf_tag_hit_counter     ()
    );


endmodule
