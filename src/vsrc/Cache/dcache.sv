`include "core_config.sv"
`include "defines.sv"
`include "utils/dual_port_lutram.sv"
`include "utils/lfsr.sv"

module dcache
    import core_config::*;
(
    input logic clk,
    input logic rst,

    //cache与CPU流水线的交互接
    input logic valid,  //表明请求有效
    input logic op,  // 1:write 0: read
    input logic [31:0] pc,
    input logic uncache,  //标志uncache指令，高位有效
    input logic [7:0] index,  // 地址的index域(addr[11:4])
    input logic [19:0] tag,  //从TLB查到的pfn形成的tag
    input logic [3:0] offset,  //地址的offset域addr[3:0]
    input logic [3:0] wstrb,  //写字节使能信号
    input logic [31:0] wdata,  //写数据
    input logic [2:0] rd_type_i, //读请求类型：3'b000: 字节；3'b001: 半字；3'b010: 字；3'b100：Cache行
    input logic [2:0] wr_type_i,
    input logic [31:0] flush_pc,
    input logic flush_i, // 冲刷信号，如果出于某种原因需要取消写事务，CPU拉高此信号
    output logic cache_ack,
    output logic addr_ok,             //该次请求的地址传输OK，读：地址被接收；写：地址和数据被接收
    output logic data_ok,             //该次请求的数据传输Ok，读：数据返回；写：数据写入完成
    output logic [31:0] rdata,  //读Cache的结果

    //cache与AXI总线的交互接口
    output logic rd_req,  //读请求有效信号。高电平有效
    output logic [2:0] rd_type,              //读请求类型：3'b000: 字节；3'b001: 半字；3'b010: 字；3'b100：Cache行
    output logic [31:0] rd_addr,  //读请求起始地址
    input logic rd_rdy,  //读请求能否被接收的握手信号。高电平有效
    input logic ret_valid,  //返回数据有效。高电平有效。
    input logic ret_last,  //返回数据是一次读请求对应的最后一个返回数据
    input logic [127:0] ret_data,  //读返回数据
    output logic wr_req,  //写请求有效信号。高电平有效
    output logic [2:0] wr_type,              //写请求类型：3'b000: 字节；3'b001: 半字；3'b010: 字；3'b100：Cache行
    output logic [31:0] wr_addr,  //写请求起始地址
    output logic [15:0] wr_wstrb,  //写操作的字节掩码。16bits for AXI128
    output logic [127:0] wr_data,  //写数据
    input logic wr_rdy  //写请求能否被接受的握手信号。具体见p2234.
);

    localparam NWAY = DCACHE_NWAY;
    localparam NSET = DCACHE_NSET;

    enum int {
        IDLE,
        LOOK_UP,
        READ_REQ,
        READ_WAIT,
        WRITE_REQ
    }
        state, next_state;


    logic valid_buffer;
    logic op_buffer;
    logic uncache_buffer;
    logic [31:0] pc_buffer;
    logic [7:0] index_buffer;
    logic [19:0] tag_buffer;
    logic [3:0] offset_buffer;
    logic [3:0] wstrb_buffer;
    logic [31:0] wdata_buffer;
    logic [2:0] rd_type_buffer;
    logic [2:0] wr_type_buffer;

    logic [15:0] random_r;

    // BRAM signals
    logic [NWAY-1:0][DCACHELINE_WIDTH-1:0] data_bram_rdata;
    logic [NWAY-1:0][ICACHELINE_WIDTH-1:0] data_bram_wdata;
    logic [NWAY-1:0][$clog2(NSET)-1:0] data_bram_addr;
    logic [NWAY-1:0] data_bram_we;
    logic [NWAY-1:0] data_bram_en;

    // Tag bram 
    // {1bit valid, 20bits tag}
    localparam TAG_BRAM_WIDTH = 21;
    logic [NWAY-1:0][TAG_BRAM_WIDTH-1:0] tag_bram_rdata;
    logic [NWAY-1:0][TAG_BRAM_WIDTH-1:0] tag_bram_wdata;
    logic [NWAY-1:0][$clog2(NSET)-1:0] tag_bram_addr;
    logic [NWAY-1:0] tag_bram_we;
    logic [NWAY-1:0] tag_bram_en;

    logic [`RegBus] cpu_addr;
    logic miss_pulse, miss_r, miss;
    logic hit;
    logic [NWAY-1:0] tag_hit;
    assign cpu_addr = {tag_buffer, index_buffer, offset_buffer};

    logic flush;
    assign flush = flush_i & (flush_pc <= pc_buffer);


    always_ff @(posedge clk) begin
        if (rst) begin
            state <= IDLE;
        end else begin
            state <= next_state;
        end
    end


    always_ff @(posedge clk) begin : data_buffer
        if (rst) begin
            valid_buffer <= 0;
            op_buffer <= 0;
            uncache_buffer <= 0;
            pc_buffer <= 0;
            index_buffer <= 0;
            tag_buffer <= 0;
            offset_buffer <= 0;
            wstrb_buffer <= 0;
            wdata_buffer <= 0;
            rd_type_buffer <= 0;
            wr_type_buffer <= 0;
        end else if (flush_i) begin
            valid_buffer <= 0;
            op_buffer <= 0;
            uncache_buffer <= 0;
            pc_buffer <= 0;
            index_buffer <= 0;
            tag_buffer <= 0;
            offset_buffer <= 0;
            wstrb_buffer <= 0;
            wdata_buffer <= 0;
            rd_type_buffer <= 0;
            wr_type_buffer <= 0;
        end else if (valid & !cache_ack) begin  // not accept new request while working
            valid_buffer <= valid;
            op_buffer <= op;
            uncache_buffer <= uncache;
            pc_buffer <= pc;
            index_buffer <= index;
            tag_buffer <= tag;
            offset_buffer <= offset;
            wstrb_buffer <= wstrb;
            wdata_buffer <= wdata;
            rd_type_buffer <= rd_type_i;
            wr_type_buffer <= wr_type_i;
        end else if (next_state == IDLE) begin  //means that cache will finish work,so flush the buffered signal
            valid_buffer   <= 0;
            op_buffer      <= 0;
            uncache_buffer <= 0;
            pc_buffer      <= 0;
            index_buffer   <= 0;
            tag_buffer     <= 0;
            offset_buffer  <= 0;
            wstrb_buffer   <= 0;
            wdata_buffer   <= 0;
            rd_type_buffer <= 0;
            wr_type_buffer <= 0;
        end else begin
            valid_buffer <= valid_buffer;
            op_buffer <= op_buffer;
            uncache_buffer <= uncache_buffer;
            pc_buffer <= pc_buffer;
            index_buffer <= index_buffer;
            tag_buffer <= tag_buffer;
            offset_buffer <= offset_buffer;
            wstrb_buffer <= wstrb_buffer;
            wdata_buffer <= wdata_buffer;
            rd_type_buffer <= rd_type_buffer;
            wr_type_buffer <= wr_type_buffer;
        end
    end

    always_comb begin
        if (rst) cache_ack = 0;
        else if (state != IDLE) cache_ack = 1;
        else cache_ack = 0;
    end


    always_comb begin : transition_comb
        case (state)
            IDLE: begin
                if (valid) next_state = LOOK_UP;
            end
            LOOK_UP: begin
                if (valid_buffer) begin
                    if (op_buffer) next_state = WRITE_REQ;
                    else if (miss) next_state = READ_REQ;
                end else next_state = IDLE;
            end
            READ_REQ: begin
                if (rd_rdy) next_state = READ_WAIT;  // If AXI ready, send request 
                else next_state = READ_REQ;
            end
            READ_WAIT: begin
                if (ret_valid) next_state = IDLE;  // If return valid, back to IDLE
                else next_state = READ_WAIT;
            end
            WRITE_REQ: begin
                // If AXI is ready, then write req is accept this cycle, back to IDLE
                // If flushed, back to IDLE
                if (wr_rdy | flush) next_state = IDLE;
                else next_state = WRITE_REQ;
            end
            default: begin
                next_state = IDLE;
            end
        endcase
    end


    always_comb begin
        // Default all 0
        for (integer i = 0; i < NWAY; i++) begin
            tag_bram_addr[i] = 0;
            data_bram_addr[i] = 0;
            tag_bram_addr[i] = 0;
            data_bram_addr[i] = 0;
            tag_bram_en[i] = 0;
            data_bram_en[i] = 0;
        end
        case (state)
            IDLE: begin
                for (integer i = 0; i < NWAY; i++) begin
                    // Port 1
                    if (valid) begin
                        tag_bram_en[i] = 1;
                        data_bram_en[i] = 1;
                        tag_bram_addr[i] = index;
                        data_bram_addr[i] = index;
                    end
                end
            end
            LOOK_UP: begin
                for (integer i = 0; i < NWAY; i++) begin
                    if (valid) begin
                        tag_bram_en[i] = 1;
                        data_bram_en[i] = 1;
                        tag_bram_addr[i] = index_buffer;
                        data_bram_addr[i] = index_buffer;
                    end
                end
            end
            READ_REQ, READ_WAIT: begin
                for (integer i = 0; i < NWAY; i++) begin
                    tag_bram_en[i] = rd_rdy;
                    data_bram_en[i] = rd_rdy;
                    tag_bram_addr[i] = index_buffer;
                    data_bram_addr[i] = index_buffer;
                end
            end
            WRITE_REQ: begin
                for (integer i = 0; i < NWAY; i++) begin
                    // if miss,then don't write
                    if (miss) begin
                        tag_bram_en[i] = 0;
                        data_bram_en[i] = 0;
                        tag_bram_addr[i] = 0;
                        data_bram_addr[i] = 0;
                    end else begin
                        tag_bram_en[i] = 1;
                        data_bram_en[i] = 1;
                        tag_bram_addr[i] = index_buffer;
                        data_bram_addr[i] = index_buffer;
                    end
                end
            end
        endcase
    end


    always_comb begin : bram_data_gen
        for (integer i = 0; i < NWAY; i++) begin
            tag_bram_we[i] = 0;
            tag_bram_wdata[i] = 0;
            data_bram_we[i] = 0;
            data_bram_wdata[i] = 0;
        end
        case (state)
            READ_WAIT: begin
                for (integer i = 0; i < NWAY; i++) begin
                    if (i[0] == random_r[0]) begin
                        if (rd_rdy) begin
                            tag_bram_we[i] = 1;
                            tag_bram_wdata[i] = {1'b1, tag_buffer};
                            data_bram_we[i] = 1;
                            data_bram_wdata[i] = ret_data;
                        end
                    end
                end
            end
            WRITE_REQ: begin
                for (integer i = 0; i < NWAY; i++) begin
                    if (tag_hit[i]) begin
                        tag_bram_we[i] = 1;
                        tag_bram_wdata[i] = {1'b1, tag_buffer};
                        data_bram_we[i] = 1;
                        //select the write bit
                        case (offset[3:2])
                            2'b00: begin
                                data_bram_wdata[i] = {data_bram_rdata[i][127:32], wdata_buffer};
                            end
                            2'b01: begin
                                data_bram_wdata[i] = {
                                    data_bram_rdata[i][127:64], wdata_buffer, {32{1'b0}}
                                };
                            end
                            2'b10: begin
                                data_bram_wdata[i] = {
                                    data_bram_rdata[i][127:96],
                                    wdata_buffer,
                                    data_bram_rdata[i][63:0]
                                };
                            end
                            2'b11: begin
                                data_bram_wdata[i] = {wdata_buffer, data_bram_rdata[i][95:0]};
                            end
                        endcase
                    end
                end
            end
            default: begin
            end
        endcase
    end

    logic rd_req_r;
    logic [31:0] rd_addr_r;

    // Handshake with AXI
    always_ff @(posedge clk) begin
        case (state)
            READ_REQ: begin
                if (rd_rdy) begin
                    rd_req_r  <= 1;
                    rd_addr_r <= cpu_addr;
                end
            end
        endcase
    end


    assign rd_type = (uncache == 0) ? rd_type_buffer : 3'b100;
    assign wr_type = (uncache == 0) ? wr_type_buffer : 3'b100;  // word
    always_comb begin
        // Default signal
        rd_addr  = 0;
        rd_req   = 0;
        wr_addr  = 0;
        wr_data  = 0;
        wr_req   = 0;
        wr_wstrb = 0;

        case (state)
            READ_REQ: begin
                if (rd_rdy) begin
                    rd_req  = 1;
                    rd_addr = cpu_addr;
                end
            end
            READ_WAIT: begin
                rd_req  = rd_req_r & ~ret_valid;
                rd_addr = rd_addr_r;
            end
            WRITE_REQ: begin
                if (flush) begin
                    wr_req  = 0;
                    wr_addr = 0;
                end else if (wr_rdy) begin
                    wr_req = 1;
                    wr_addr = cpu_addr;  // DO NOT align addr, 128b -> 32b translate need info from addr
                    case (cpu_addr[3:2])
                        2'b00: begin
                            wr_data  = {{96{1'b0}}, wdata_buffer};
                            wr_wstrb = {12'b0, wstrb_buffer};
                        end
                        2'b01: begin
                            wr_data  = {{64{1'b0}}, wdata_buffer, {32{1'b0}}};
                            wr_wstrb = {8'b0, wstrb_buffer, 4'b0};
                        end
                        2'b10: begin
                            wr_data  = {32'b0, wdata_buffer, {64{1'b0}}};
                            wr_wstrb = {4'b0, wstrb_buffer, 8'b0};
                        end
                        2'b11: begin
                            wr_data  = {wdata_buffer, {96{1'b0}}};
                            wr_wstrb = {wstrb_buffer, 12'b0};
                        end
                    endcase
                end
            end
        endcase
    end

    // Handshake with CPU
    always_comb begin
        addr_ok = 0;
        data_ok = 0;
        rdata   = 0;
        case (state)

            READ_WAIT: begin
                if (!miss) begin
                    addr_ok = 1;
                    data_ok = 1;
                    rdata   = hit_data[rd_addr_r[3:2]*32+:32];
                end else if (ret_valid) begin
                    addr_ok = 1;
                    data_ok = 1;
                    rdata   = ret_data[rd_addr_r[3:2]*32+:32];
                end
            end
            WRITE_REQ: begin
                if (wr_rdy) begin
                    addr_ok = 1;
                    data_ok = 1;
                end
            end
        endcase
    end


    // Miss signal
    assign miss_pulse = valid_buffer & ~hit & (state == IDLE);
    assign miss = miss_pulse | miss_r;
    always_ff @(posedge clk) begin
        if (rst) begin
            miss_r <= 0;
        end else begin
            case (state)
                IDLE: begin
                    miss_r <= miss_pulse;
                end
                READ_WAIT: begin
                    if (ret_valid) miss_r <= 0;
                end
                default: begin
                end
            endcase
        end
    end


    // Hit signal
    always_comb begin
        for (integer i = 0; i < NWAY; i++) begin
            tag_hit[i] = tag_bram_rdata[i][19:0] == tag_buffer && tag_bram_rdata[i][20];
        end
    end

    logic [DCACHELINE_WIDTH-1:0] hit_data;
    always_comb begin
        hit = 0;
        hit_data = 0;
        for (integer i = 0; i < NWAY; i++) begin
            if (tag_hit[i]) begin
                hit = 1;
                hit_data = data_bram_rdata[i];
            end
        end
    end

    // LSFR
    lfsr #(
        .WIDTH(16)
    ) u_lfsr (
        .clk  (clk),
        .rst  (rst),
        .en   (1'b1),
        .value(random_r)
    );

    // BRAM instantiation
    generate
        for (genvar i = 0; i < NWAY; i++) begin : bram_ip
`ifdef BRAM_IP
            bram_icache_tag_ram u_tag_bram (
                .clk  (clk),
                .ena  (tag_bram_en[i][0]),
                .enb  (tag_bram_en[i][1]),
                .wea  (tag_bram_we[i][0]),
                .dina (tag_bram_wdata[i][0]),
                .addra(tag_bram_addr[i][0]),
                .addrb(tag_bram_addr[i][1]),
                .doutb(tag_bram_rdata[i][1])
            );
            bram_icache_data_ram u_data_bram (
                .clk  (clk),
                .ena  (tag_bram_en[i][0]),
                .enb  (tag_bram_en[i][1]),
                .wea  (tag_bram_we[i][0]),
                .dina (tag_bram_wdata[i][0]),
                .addra(tag_bram_addr[i][0]),
                .addrb(tag_bram_addr[i][1]),
                .doutb(tag_bram_rdata[i][1])
            );
`else

            dual_port_lutram #(
                .DATA_WIDTH     (TAG_BRAM_WIDTH),
                .DATA_DEPTH_EXP2($clog2(NSET))
            ) u_tag_bram (
                .clk  (clk),
                .ena  (tag_bram_en[i]),
                .enb  (tag_bram_en[i]),
                .wea  (tag_bram_we[i]),
                .dina (tag_bram_wdata[i]),
                .addra(tag_bram_addr[i]),
                .addrb(tag_bram_addr[i]),
                .doutb(tag_bram_rdata[i])
            );
            dual_port_lutram #(
                .DATA_WIDTH     (ICACHELINE_WIDTH),
                .DATA_DEPTH_EXP2($clog2(NSET))
            ) u_data_bram (
                .clk  (clk),
                .ena  (data_bram_en[i]),
                .enb  (data_bram_en[i]),
                .wea  (data_bram_we[i]),
                .dina (data_bram_wdata[i]),
                .addra(data_bram_addr[i]),
                .addrb(data_bram_addr[i]),
                .doutb(data_bram_rdata[i])
            );
`endif
        end
    endgenerate


endmodule
