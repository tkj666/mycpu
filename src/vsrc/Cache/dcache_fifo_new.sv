`include "core_config.sv"
`include "defines.sv"
`include "utils/lutram_1w_mr.sv"

module dcache_fifo
    import core_config::*;
(
    input clk,
    input rst,
    //CPU write request
    input logic cpu_wreq_i,
    input logic [`DataAddrBus] cpu_awaddr_i,
    input logic [DCACHELINE_WIDTH-1:0] cpu_wdata_i,
    output logic write_hit_o,
    //CPU read request and response
    input logic cpu_rreq_i,
    input logic [`DataAddrBus] cpu_araddr_i,
    output logic read_hit_o,
    output logic [DCACHELINE_WIDTH-1:0] cpu_rdata_o,
    //FIFO state
    output logic [1:0] state,
    //write to memory 
    input logic axi_bvalid_i,
    input logic axi_req_accept,
    output logic axi_wen_o,
    output logic [DCACHELINE_WIDTH-1:0] axi_wdata_o,
    output logic [`DataAddrBus] axi_awaddr_o

);

    // Parameters 
    localparam DEPTH = DCACHE_FIFO_DEPTH;

    logic [DEPTH-1:0][DCACHELINE_WIDTH-1:0] q_data;
    logic [DEPTH-1:0][`DataAddrBus] q_addr;
    logic [$clog2(DEPTH)-1:0] head, tail;
    logic [DEPTH-1:0] read_hit;
    logic [DEPTH-1:0] write_hit;
    logic [DEPTH-1:0] valid;

    logic full, empty;

    assign state = {full, empty};
    assign empty = (head == tail) & ~valid[head];
    assign full = (tail == head) & valid[head];

    always_ff @(posedge clk) begin
        if (rst) begin
            head <= 0;
            tail <= 0;
            valid <= 0;
        end else begin
            if (axi_bvalid_i) begin
                head <= head + 1;
            end
        end
    end

    always_ff @(posedge clk) begin : hit
        read_hit_o <= 0;
        write_hit_o <= 0;
        for (integer i = 0; i < DEPTH; i = i + 1) begin
            if (valid[i]) begin
                if (cpu_rreq_i & (q_addr[i] == cpu_araddr_i)) begin
                    read_hit_o <= 1;
                    cpu_rdata_o <= q_data[i];
                end
                if (cpu_wreq_i & (q_addr[i] == cpu_awaddr_i)) begin
                    write_hit_o <= 1;
                    q_data[i] <= cpu_wdata_i;
                end
            end
        end
    end

    assign axi_wen_o = ~empty;
    assign axi_wdata_o = q_data[head];
    assign axi_wdata_o = q_addr[head];



endmodule
