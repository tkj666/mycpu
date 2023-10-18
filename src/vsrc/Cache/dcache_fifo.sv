`include "core_config.sv"
`include "defines.sv"

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
    logic [$clog2(DEPTH)-1:0] head, tail, read_hit_idx, write_hit_idx;
    logic [DEPTH-1:0] valid;
    logic read_hit, write_hit;

    logic full, empty;

    logic accepted;

    assign state = {full, empty};
    assign empty = (head == tail) & ~valid[head];
    assign full = (tail == head) & valid[head];

    always_ff @(posedge clk) begin : accept
        if (rst) begin
            accepted <= 0;
        end else if (axi_req_accept) begin
            accepted <= 1;
        end else if (axi_bvalid_i) begin
            accepted <= 0;
        end
    end

    always_ff @(posedge clk) begin : push_pop
        if (rst) begin
            head <= 0;
            tail <= 0;
            valid <= 0;
        end else begin
            if (axi_bvalid_i & accepted) begin
                head <= head + 1;
                valid[head] <= 0;
            end
            if (cpu_wreq_i & ~write_hit) begin
                valid[tail] <= 1;
                q_addr[tail] <= cpu_awaddr_i;
                q_data[tail] <= cpu_wdata_i;
                tail <= tail + 1;
            end
        end
    end

    always_comb begin : hit
        read_hit = 0;
        write_hit = 0;
        read_hit_idx = 0;
        write_hit_idx = 0;
        for (integer i = 0; i < DEPTH; i = i + 1) begin
            if (valid[i]) begin
                if (cpu_rreq_i & (q_addr[i] == cpu_araddr_i)) begin
                    read_hit = 1;
                    read_hit_idx = i;
                end
                if (cpu_wreq_i & (q_addr[i] == cpu_awaddr_i)) begin
                    write_hit = 1;
                    write_hit_idx = i;
                end
            end
        end
    end

    always_ff @(posedge clk) begin : hit_out
        read_hit_o <= read_hit;
        write_hit_o <= write_hit;
        if (read_hit) begin
            cpu_rdata_o <= q_data[read_hit_idx];
        end
        if (write_hit) begin
            q_data[write_hit_idx] <= cpu_wdata_i;
        end
    end

    assign axi_wen_o = ~empty & ~accepted;
    assign axi_wdata_o = q_data[head];
    assign axi_awaddr_o = q_addr[head];


endmodule
