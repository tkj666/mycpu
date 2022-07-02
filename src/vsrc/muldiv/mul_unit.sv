`include "core_types.sv"
`include "core_config.sv"
`include "defines.sv"

module mul_unit
    import core_types::*;
    import core_config::*;
(
    input logic clk,
    input logic rst,

    input logic [`RegBus] rs1,
    input logic [`RegBus] rs2,
    input logic [1:0] op,

    input logic mul_ack,

    output logic ready,
    output logic done,
    output logic [`RegBus] mul_result

);

    logic signed [63:0] result;
    logic mulh [2];
    logic valid [2];


    logic rs1_is_signed, rs2_is_signed;
    logic signed [32:0] rs1_ext, rs2_ext;
    logic signed [32:0] rs1_r, rs2_r;

    logic stage1_advance;
    logic stage2_advance;

    assign rs1_is_signed = op[1:0] inside {2'b01, 2'b10};//MUL doesn't matter
    assign rs2_is_signed = op[1:0] inside {2'b00, 2'b01};//MUL doesn't matter

    assign rs1_ext = signed'({rs1[31] & rs1_is_signed, rs1});
    assign rs2_ext = signed'({rs2[31] & rs2_is_signed, rs2});

    assign ready = stage1_advance;
    assign stage1_advance = ~valid[0] | stage2_advance;
    assign stage2_advance = ~valid[1] | mul_ack;

     always_ff @ (posedge clk) begin
        if (stage1_advance) begin
            rs1_r <= rs1_ext;
            rs2_r <= rs2_ext;
        end
        if (stage2_advance) begin
            result <= 64'(rs1_r * rs2_r);
        end
    end

    always_ff @ (posedge clk) begin
        if (stage1_advance) begin
            mulh[0] <= (op[1:0] != 2'b01);
    //        id[0] <= issue.id;
        end
        if (stage2_advance) begin
            mulh[1] <= mulh[0];
    //        id[1] <= id[0];
        end
    end

    always_ff @ (posedge clk) begin
        if (rst)
            valid <= '{default: 0};
        else begin
            valid[0] <= stage1_advance ? 0:0;//issue.new_request : valid[0];
            valid[1] <= stage2_advance ? valid[0] : valid[1];
        end
    end

    assign mul_result = mulh[1] ? result[63:32] : result[31:0];
    assign done = valid[1];


endmodule
