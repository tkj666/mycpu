`include "core_config.sv"
`include "defines.sv"
`include "utils/lfsr.sv"
`include "utils/byte_bram.sv"
`include "utils/dual_port_lutram.sv"
`include "Cache/dcache_fifo.sv"
`include "axi/axi_dcache_master.sv"
`include "axi/axi_interface.sv"

module dcache
    import core_config::*;
(
    input logic clk,
    input logic rst,

    //vaddr from ex
    input logic pre_valid,
    input logic [`RegBus] vaddr,

    
    input logic valid,  
    input logic [`RegBus] pc,
    input logic [`RegBus] addr,
    input logic [3:0] wstrb,  
    input logic [31:0] wdata, 

    input un_excp,

    //CACOP
    input logic cacop_i,
    input logic [1:0] cacop_mode_i,
    input logic [ADDR_WIDTH-1:0] cacop_addr_i,
    output cacop_ack_o,

    output logic data_ok,             //该次请求的数据传输Ok，读：数据返回；写：数据写入完成
    output logic [31:0] rdata,  //读Cache的结果

    axi_interface.master m_axi
);

    localparam NWAY = DCACHE_NWAY;
    localparam NSET = DCACHE_NSET;

    enum int {
        IDLE,

        UNHIT_WAIT,
        READ_REQ,
        READ_WAIT,
        WRITE_REQ,
        WRITE_WAIT,

        CACOP_INVALID
    }
        state, next_state, last_state;

    // save the input signal
    logic p3_valid;
    logic [`RegBus] p3_pc;
    logic [7:0] p3_index;
    logic [19:0] p3_tag;
    logic [3:0] p3_offset;
    logic [3:0] p3_wstrb;
    logic [31:0] p3_wdata;
    logic [2:0] req_type_buffer;

    logic cacop_buffer;
    logic [1:0] cacop_mode_buffer;
    logic [ADDR_WIDTH-1:0] cacop_addr_buffer;

    logic cpu_wreq;
    logic [15:0] random_r;

    // AXI
    logic [ADDR_WIDTH-1:0] axi_addr_o;
    logic axi_req_o;
    logic axi_we_o;
    logic axi_rdy_i;
    logic axi_rvalid_i;
    logic axi_bvalid_i;
    logic [AXI_DATA_WIDTH-1:0] axi_data_i;
    logic [AXI_DATA_WIDTH-1:0] axi_wdata_o;
    logic [(AXI_DATA_WIDTH/8)-1:0] axi_wstrb_o;

    // BRAM signals
    logic [NWAY-1:0][DCACHELINE_WIDTH-1:0]
        data_bram_rdata, p2_data_bram_rdata, p3_data_bram_rdata;
    logic [NWAY-1:0][ICACHELINE_WIDTH-1:0] data_bram_wdata, p3_data_bram_wdata;
    logic [NWAY-1:0][$clog2(NSET)-1:0] data_bram_addr, data_bram_raddr, data_bram_waddr;
    logic [NWAY-1:0][15:0] data_bram_we;
    logic [NWAY-1:0] data_bram_en;

    // Tag bram 
    // {1bit dirty,1bit valid, 20bits tag}
    localparam TAG_BRAM_WIDTH = 22;
    logic [NWAY-1:0][TAG_BRAM_WIDTH-1:0] tag_bram_rdata, p2_tag_bram_rdata, p3_tag_bram_rdata;
    logic [NWAY-1:0][TAG_BRAM_WIDTH-1:0] tag_bram_wdata, p3_tag_bram_wdata;
    logic [NWAY-1:0][$clog2(NSET)-1:0] tag_bram_addr, tag_bram_raddr, tag_bram_waddr;
    logic [NWAY-1:0 ] tag_bram_we;
    logic [NWAY-1:0 ] tag_bram_en;

    logic [ `RegBus]  cpu_addr;
    logic miss_pulse, miss;
    logic hit;
    logic [NWAY-1:0] tag_hit, p2_tag_hit, p3_tag_hit;

    //if it is 1'b1,means that we should use p2_ data 
    logic p2_save_valid;

    assign cpu_addr = {p3_tag, p3_index, p3_offset};


    logic [1:0] fifo_state;
    logic
        fifo_rreq, fifo_wreq, fifo_r_hit, p2_fifo_r_hit,p3_fifo_r_hit, fifo_w_hit, fifo_axi_wr_req, fifo_w_accept;
    logic [`DataAddrBus] fifo_raddr, fifo_waddr, fifo_axi_wr_addr;
    logic [DCACHELINE_WIDTH-1:0] fifo_rdata,p2_fifo_rdata,p3_fifo_rdata, fifo_wdata, fifo_axi_wr_data;

    // CACOP
    logic cacop_op_mode0, cacop_op_mode1, cacop_op_mode2, cacop_op_mode2_hit;
    logic [$clog2(NWAY)-1:0] cacop_way;
    logic [$clog2(NSET)-1:0] cacop_index;
    assign cacop_op_mode0 = cacop_i & cacop_mode_i == 2'b00;
    assign cacop_op_mode1 = cacop_i & cacop_mode_i == 2'b01;
    assign cacop_op_mode2 = cacop_i & cacop_mode_i == 2'b10;
    assign cacop_way = cacop_addr_i[$clog2(NWAY)-1:0];
    assign cacop_index = cacop_addr_i[$clog2(
        DCACHELINE_WIDTH
    )+$clog2(
        NSET
    )-1:$clog2(
        DCACHELINE_WIDTH
    )];

    logic [1:0] dirty;
    assign dirty = {tag_bram_rdata[1][21], tag_bram_rdata[0][21]};

    //judge if the cacop mode2 hit
    always_comb begin
        cacop_op_mode2_hit = 0;
        if (cacop_op_mode2) begin
            if(tag_bram_rdata[cacop_way][19:0] == cacop_addr_buffer[31:12] 
                && tag_bram_rdata[cacop_way][20] == 1'b1)
                cacop_op_mode2_hit = 1;
        end else cacop_op_mode2_hit = 0;
    end


    always_ff @(posedge clk) begin
        if (rst) begin
            last_state <= IDLE;
            state <= IDLE;
        end else begin
            last_state <= state;
            state <= next_state;
        end
    end


    always_ff @(posedge clk) begin : data_buffer
        if (rst) begin
            p3_valid <= 0;
            p3_index <= 0;
            p3_pc <= 0;
            p3_tag <= 0;
            p3_offset <= 0;
            p3_wstrb <= 0;
            p3_wdata <= 0;
            cacop_buffer <= 0;
            cacop_mode_buffer <= 0;
            cacop_addr_buffer <= 0;
            // if the next state is idle,that means the
            // instr in p3 will not stall the cache
            // so we can change the p3 regs
        end else begin
            // when a new req come and the cache is idle
            // we accept this req and check hit
            if(valid & next_state == IDLE)begin
                p3_valid <= valid;
                p3_pc <= pc;
                p3_index <= addr[11:4];
                p3_tag <= addr[31:12];
                p3_offset <= addr[3:0];
                p3_wstrb <= wstrb;
                p3_wdata <= wdata;
                cacop_buffer <= cacop_i;
                cacop_mode_buffer <= cacop_mode_i;
                cacop_addr_buffer <= cacop_addr_i; 
            end
            // if there is a valid from the axi,
            // we clear the p3 data first
            // then we choose the next data
            else if(axi_rvalid_i | axi_bvalid_i)begin
                p3_valid <= 0;
                p3_pc <= 0;
                p3_index <= 0;
                p3_tag <= 0;
                p3_offset <= 0;
                p3_wstrb <= 0;
                p3_wdata <= 0;
                cacop_buffer <= 0;
                cacop_mode_buffer <= 0;
                cacop_addr_buffer <= 0;
                // p2 valid means there is a instr after it
                // so we get the p2 data to p3
                if(valid & p2_save_valid)begin
                    p3_valid <= valid;
                    p3_pc <= pc;
                    p3_index <= addr[11:4];
                    p3_tag <= addr[31:12];
                    p3_offset <= addr[3:0];
                    p3_wstrb <= wstrb;
                    p3_wdata <= wdata;
                    cacop_buffer <= cacop_i;
                    cacop_mode_buffer <= cacop_mode_i;
                    cacop_addr_buffer <= cacop_addr_i; 
                end
                // keep the p3 data wait for axi valid
            end else begin
                p3_valid <= p3_valid;
                p3_index <= p3_index;
                p3_tag <= p3_tag;
                p3_offset <= p3_offset;
                p3_wstrb <= p3_wstrb;
                p3_wdata <= p3_wdata;
                cacop_buffer <= cacop_buffer;
                cacop_mode_buffer <= cacop_mode_buffer;
                cacop_addr_buffer <= cacop_addr_buffer;
            end
        end
    end
        

    //  the wstrb is not 0 means it is a write request;
    assign cpu_wreq = p3_wstrb != 4'b0;

    always_comb begin : transition_comb
        case (state)
            IDLE: begin
                if (cacop_i) next_state = CACOP_INVALID;
                // if the dcache is idle,then accept the new request
                else if (p3_valid) begin
                    // if write hit,then turn to write idle
                    // if write miss,then wait for read
                    if (cpu_wreq) begin
                        if (miss) next_state = UNHIT_WAIT;
                        else next_state = IDLE;
                    end  // if hit,then back,if miss then wait for read
                    else begin
                        if (miss) next_state = UNHIT_WAIT;
                        else next_state = IDLE;
                    end
                end else next_state = IDLE;
            end
            UNHIT_WAIT: begin
                // if not excp then send the req
                if (un_excp) begin
                    if(cpu_wreq)next_state = WRITE_REQ;
                    else next_state = READ_REQ;
                end
                // if load excp then flush back
                else
                    next_state = IDLE;
            end
            READ_REQ: begin
                // if read miss,we have to wait the fifo
                // to be clear first,then we send the read
                // request to axi
                if (!fifo_state[0]) next_state = READ_REQ;
                if (axi_rdy_i) next_state = READ_WAIT;  // If AXI ready, send request 
                else next_state = READ_REQ;
            end
            READ_WAIT: begin
                // If return valid, back to IDLE
                if (axi_rvalid_i) next_state = IDLE;
                else next_state = READ_WAIT;
            end
            WRITE_REQ: begin
                // If AXI is ready and write miss then write req is accept this cycle,and wait until rdata ret
                // If flushed, back to IDLE
                // if AXi is not ready,then wait until it ready and sent the read req
                if (axi_rdy_i) next_state = WRITE_WAIT;
                else next_state = WRITE_REQ;
            end
            WRITE_WAIT: begin
                // wait the rdata back
                if (axi_rvalid_i) next_state = IDLE;
                else next_state = WRITE_WAIT;
            end
            CACOP_INVALID: next_state = IDLE;
            default: begin
                next_state = IDLE;
            end
        endcase
    end


    always_comb begin
        // Default all 0
        for (integer i = 0; i < NWAY; i++) begin
            tag_bram_raddr[i] = 0;
            tag_bram_waddr[i] = 0;
            data_bram_raddr[i] = 0;
            data_bram_waddr[i] = 0;
            tag_bram_en[i] = 0;
            data_bram_en[i] = 0;
        end
        case (state)
            IDLE: begin
                for (integer i = 0; i < NWAY; i++) begin
                    // P1 state:use the vaddr query
                    // the tag and data bram
                    if (pre_valid) begin
                        tag_bram_en[i] = 1;
                        data_bram_en[i] = 1;
                        tag_bram_raddr[i] = vaddr[11:4];
                        data_bram_raddr[i] = vaddr[11:4];
                    end
                    // P2 state:use the paddr to
                    // read the fifo to check if hit
                    if (valid) begin
                        fifo_rreq  = 1;
                        fifo_raddr = addr;
                    end
                    // P3 state:if write hit,the ready to write
                    // if not hit ,the do nothing and come into
                    // the refill state
                    if (p3_valid & cpu_wreq & hit) begin
                        tag_bram_en[i] = 1;
                        data_bram_en[i] = 1;
                        tag_bram_waddr[i] = p3_index;
                        data_bram_waddr[i] = p3_index;
                    end
                end
            end
            READ_REQ, READ_WAIT: begin
                for (integer i = 0; i < NWAY; i++) begin
                    tag_bram_en[i] = 1;
                    data_bram_en[i] = 1;
                    tag_bram_waddr[i] = p3_index;
                    data_bram_waddr[i] = p3_index;
                end
            end
            WRITE_REQ, WRITE_WAIT: begin
                for (integer i = 0; i < NWAY; i++) begin
                    //if hit ,write the data to the line
                    tag_bram_en[i] = 1;
                    data_bram_en[i] = 1;
                    tag_bram_waddr[i] = p3_index;
                    data_bram_waddr[i] = p3_index;
                end
            end
            CACOP_INVALID: begin
                for (integer i = 0; i < NWAY; i++) begin
                    tag_bram_en[i]  = 0;
                    tag_bram_en[i]  = 0;
                    data_bram_en[i] = 0;
                    data_bram_en[i] = 0;
                    if (cacop_way == i[0]) begin
                        tag_bram_waddr[i] = cacop_index;
                        tag_bram_en[i] = 1;
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
            IDLE: begin
                // P3 state
                // if write hit,then replace the cacheline
                for (integer i = 0; i < NWAY; i++) begin
                    // if write hit ,then write the hit line, if miss then don't write
                    if (p3_tag_hit[i] && cpu_wreq) begin
                        tag_bram_we[i] = 1;
                        // make the dirty bit 1'b1
                        tag_bram_wdata[i] = {1'b1, 1'b1, p3_tag};
                        //select the write bit
                        case (p3_wstrb)
                            //st.b 
                            4'b0001, 4'b0010, 4'b0100, 4'b1000: begin
                                data_bram_we[i][p3_offset] = 1'b1;
                                data_bram_wdata[i] = {4{p3_wdata}};
                            end
                            //st.h
                            4'b0011, 4'b1100: begin
                                data_bram_we[i][p3_offset+1] = 1'b1;
                                data_bram_we[i][p3_offset] = 1'b1;
                                data_bram_wdata[i] = {4{p3_wdata}};
                            end
                            //st.w
                            4'b1111: begin
                                data_bram_we[i][p3_offset+3] = 1'b1;
                                data_bram_we[i][p3_offset+2] = 1'b1;
                                data_bram_we[i][p3_offset+1] = 1'b1;
                                data_bram_we[i][p3_offset] = 1'b1;
                                data_bram_wdata[i] = {4{p3_wdata}};
                            end
                            default: begin

                            end
                        endcase
                    end
                end
            end
            READ_WAIT: begin
                for (integer i = 0; i < NWAY; i++) begin
                    // select a line to write back 
                    if (i[0] == random_r[0]) begin
                        if (axi_rvalid_i) begin
                            tag_bram_we[i] = 1;
                            //make the dirty bit 1'b0
                            tag_bram_wdata[i] = {1'b0, 1'b1, p3_tag};
                            data_bram_we[i] = 16'b1111_1111_1111_1111;
                            data_bram_wdata[i] = axi_data_i;
                        end
                    end
                end
            end
            WRITE_WAIT: begin
                for (integer i = 0; i < NWAY; i++) begin
                    // select a line to write back 
                    if (i[0] == random_r[0]) begin
                        if (axi_rvalid_i) begin
                            tag_bram_we[i] = 1;
                            //make the dirty bit 1'b1
                            tag_bram_wdata[i] = {1'b1, 1'b1, p3_tag};
                            data_bram_we[i] = 16'b1111_1111_1111_1111;
                            data_bram_wdata[i] = axi_data_i;
                            data_bram_wdata[i] = bram_write_data;
                        end
                    end
                end
            end
            CACOP_INVALID: begin
                for (integer i = 0; i < NWAY; i++) begin
                    if (cacop_way == i[0]) begin
                        tag_bram_we[i] = 1;
                        tag_bram_wdata[i] = 0;
                    end
                end
            end
            default: begin
            end
        endcase
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            p2_save_valid <= 0;
            p2_data_bram_rdata <= 0;
            p2_tag_bram_rdata  <= 0;
            p2_fifo_r_hit <= 0;
            p2_fifo_rdata <= 0;
            p2_tag_hit <= 0;
            // if the pc is not equal,means a new req
            // is coming from ex, at this times
            // if the next state is not idle,that means
            // the instr at p3 will block the cache
            // so we have to save the data that 
            // only can keep 1 cycle
        end else if (pc != 0 & pc != p3_pc & next_state != IDLE) begin
            p2_save_valid <= 1'b1;
            p2_data_bram_rdata <= data_bram_rdata;
            p2_tag_bram_rdata  <= tag_bram_rdata;
            p2_fifo_r_hit <= fifo_r_hit;
            p2_fifo_rdata <= fifo_rdata;
            p2_tag_hit <= tag_hit;
        end else if(next_state == IDLE)begin
            p2_save_valid <= 0;
            p2_data_bram_rdata <= 0;
            p2_tag_bram_rdata  <= 0;
            p2_fifo_r_hit <= 0;
            p2_fifo_rdata <= 0;
            p2_tag_hit <= 0;
        end else begin
            p2_save_valid <= p2_save_valid;
            p2_data_bram_rdata <= p2_data_bram_rdata;
            p2_tag_bram_rdata  <= p2_tag_bram_rdata;
            p2_fifo_r_hit <= p2_fifo_r_hit;
            p2_fifo_rdata <= p2_fifo_rdata;
            p2_tag_hit <= p2_tag_hit;
        end
    end

    logic [`RegBus] wreq_sel_data;
    logic [DCACHELINE_WIDTH-1:0] bram_write_data;
    always_comb begin
        wreq_sel_data   = 0;
        bram_write_data = 0;
        case (p3_offset[3:2])
            2'b00: wreq_sel_data = axi_data_i[31:0];
            2'b01: wreq_sel_data = axi_data_i[63:32];
            2'b10: wreq_sel_data = axi_data_i[95:64];
            2'b11: wreq_sel_data = axi_data_i[127:96];
            default: begin
            end
        endcase
        case (p3_wstrb)
            //st.b 
            4'b0001: wreq_sel_data[7:0] = p3_wdata[7:0];
            4'b0010: wreq_sel_data[15:8] = p3_wdata[15:8];
            4'b0100: wreq_sel_data[23:16] = p3_wdata[23:16];
            4'b1000: wreq_sel_data[31:24] = p3_wdata[31:24];
            //st.h
            4'b0011: wreq_sel_data[15:0] = p3_wdata[15:0];
            4'b1100: wreq_sel_data[31:16] = p3_wdata[31:16];
            //st.w
            4'b1111: wreq_sel_data = p3_wdata;
            default: begin
            end
        endcase
        case (p3_offset[3:2])
            2'b00: bram_write_data = {axi_data_i[127:32], wreq_sel_data};
            2'b01: bram_write_data = {axi_data_i[127:64], wreq_sel_data, axi_data_i[31:0]};
            2'b10: bram_write_data = {axi_data_i[127:96], wreq_sel_data, axi_data_i[63:0]};
            2'b11: bram_write_data = {wreq_sel_data, axi_data_i[95:0]};
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
                if (axi_rdy_i) begin
                    rd_req_r  <= 1;
                    rd_addr_r <= cpu_addr;
                end
            end
        endcase
    end


    // P3 state:prepare the data
    // for fifo write
    logic [`RegBus] fifo_wreq_sel_data;
    always_comb begin : fifo_wreq_sel
        fifo_wreq_sel_data = 0;
        case (state)
            IDLE: begin
                // if write hit the cacheline in the fifo 
                // then rewrite the cacheline in the fifo 
                if (p3_fifo_r_hit & cpu_wreq) begin
                    fifo_wreq_sel_data = 0;
                    case (cpu_addr[3:2])
                        2'b00: fifo_wreq_sel_data = fifo_wdata[31:0];
                        2'b01: fifo_wreq_sel_data = fifo_wdata[63:32];
                        2'b10: fifo_wreq_sel_data = fifo_wdata[95:64];
                        2'b11: fifo_wreq_sel_data = fifo_wdata[127:96];
                    endcase
                    case (p3_wstrb)
                        //st.b 
                        4'b0001: fifo_wreq_sel_data[7:0] = p3_wdata[7:0];
                        4'b0010: fifo_wreq_sel_data[15:8] = p3_wdata[15:8];
                        4'b0100: fifo_wreq_sel_data[23:16] = p3_wdata[23:16];
                        4'b1000: fifo_wreq_sel_data[31:24] = p3_wdata[31:24];
                        //st.h
                        4'b0011: fifo_wreq_sel_data[15:0] = p3_wdata[15:0];
                        4'b1100: fifo_wreq_sel_data[31:16] = p3_wdata[31:16];
                        //st.w
                        4'b1111: fifo_wreq_sel_data = p3_wdata;
                        default: begin
                        end
                    endcase
                end
            end
        endcase
    end

    // after prepare the data at P3
    // we write the data to fifo
    always_ff @(posedge clk) begin
        if (rst) begin
            fifo_wreq  <= 0;
            fifo_waddr <= 0;
            fifo_wdata <= 0;
        end else begin
            case (state)
                IDLE: begin
                    // if write hit the cacheline in the fifo 
                    // then rewrite the cacheline in the fifo 
                    if (p3_fifo_r_hit & cpu_wreq) begin
                        fifo_wreq  <= 1;
                        fifo_waddr <= cpu_addr;
                        fifo_wdata <= p3_fifo_rdata;
                        case (cpu_addr[3:2])
                            2'b00: fifo_wdata[31:0] <= fifo_wreq_sel_data;
                            2'b01: fifo_wdata[63:32] <= fifo_wreq_sel_data;
                            2'b10: fifo_wdata[95:64] <= fifo_wreq_sel_data;
                            2'b11: fifo_wdata[127:96] <= fifo_wreq_sel_data;
                        endcase
                    end
                end
                // if the selected way is dirty,then sent the cacheline to the fifo
                READ_WAIT, WRITE_WAIT: begin
                    for (integer i = 0; i < NWAY; i++) begin
                        // select a line to write back 
                        if (axi_rvalid_i) begin
                            if (i[0] == random_r[0] & p3_tag_bram_rdata[i][21] == 1'b1 & !fifo_state[1]) begin
                                fifo_wreq  <= 1;
                                fifo_waddr <= {p3_tag_bram_rdata[i][19:0], p3_index, 4'b0};
                                fifo_wdata <= p3_data_bram_rdata[i];
                            end
                        end
                    end
                end
                CACOP_INVALID: begin
                    for (integer i = 0; i < NWAY; i++) begin
                        // write the invalidate cacheline back to mem
                        // cacop mode == 1 always write back
                        // cacop mode == 2 write back when hit
                        if (cacop_op_mode1 | (cacop_op_mode2 & cacop_op_mode2_hit)) begin
                            fifo_wreq  <= 1;
                            fifo_waddr <= cacop_addr_buffer;
                            fifo_wdata <= data_bram_rdata[i];
                        end
                    end
                end
                default: begin
                    fifo_wreq  <= 0;
                    fifo_waddr <= 0;
                    fifo_wdata <= 0;
                end
            endcase
        end
    end

    // Handshake with CPU
    always_comb begin
        data_ok = 0;
        rdata   = 0;
        case (state)
            IDLE: begin
                if (hit & p3_valid) begin
                    data_ok = 1;
                    rdata   = hit_data[cpu_addr[3:2]*32+:32];
                end else if (axi_rvalid_i) begin
                    data_ok = 1;
                    rdata   = axi_data_i[cpu_addr[3:2]*32+:32];
                end
            end
            READ_REQ, READ_WAIT: begin
                if (axi_rvalid_i) begin
                    data_ok = 1;
                    rdata   = axi_data_i[rd_addr_r[3:2]*32+:32];
                end
            end
            WRITE_REQ, WRITE_WAIT: begin
                if (axi_rvalid_i) begin
                    data_ok = 1;
                end
            end
        endcase
    end

    // P2 state -> P3 state
    // we select the P3 state data accroding to the last state
    // if the last state is idle,we select the data from bram
    // else we select the data from P2 buffer
    always_ff @(posedge clk) begin
        if (rst) begin
            p3_tag_bram_rdata <= 0;
            p3_data_bram_rdata <= 0;
            p3_fifo_r_hit <= 0;
            p3_fifo_rdata <= 0;
            p3_tag_hit <= 0;
        end else begin
            // not block now,use the read data
            if (state == IDLE) begin
                p3_tag_bram_rdata  <= tag_bram_rdata;
                p3_data_bram_rdata <= data_bram_rdata;
                p3_fifo_r_hit <= fifo_r_hit;
                p3_fifo_rdata <= fifo_rdata;
                p3_tag_hit <= tag_hit;
                // block finish,use the buffer data
            end else if (axi_rvalid_i) begin
                p3_tag_bram_rdata  <= p2_tag_bram_rdata;
                p3_data_bram_rdata <= p2_data_bram_rdata;
                p3_tag_hit <= p2_tag_hit;
                p3_fifo_r_hit <= p2_fifo_r_hit;
                p3_fifo_rdata <= p2_fifo_rdata;
                //blocking now,keep data
            end else begin
                p3_tag_bram_rdata  <= p3_tag_bram_rdata;
                p3_data_bram_rdata <= p3_data_bram_rdata;
                p3_tag_hit <= p3_tag_hit;
                p3_fifo_r_hit <= p3_fifo_r_hit;
                p3_fifo_rdata <= p3_fifo_rdata;
            end
        end
    end


    // Miss signal
    assign miss_pulse = valid & ~(tag_hit[0] | tag_hit[1] | fifo_r_hit) & (state == IDLE) & (last_state == IDLE);
    always_ff @(posedge clk) begin
        if (rst) begin
            miss <= 0;
        end else begin
            case (state)
                IDLE: begin
                    miss <= miss_pulse;
                end
                READ_WAIT, WRITE_WAIT: begin
                    if (axi_rvalid_i) miss <= 0;
                    if (p2_save_valid)
                        miss <= ~(p2_tag_hit[0] | p2_tag_hit[1] | p2_fifo_r_hit) & (next_state == IDLE);
                end
                default: begin
                end
            endcase
        end
    end

    logic [21:0] tag1, tag2;
    assign tag1 = tag_bram_rdata[0];
    assign tag2 = tag_bram_rdata[1];

    // P2 state
    // Hit signal
    always_comb begin
        tag_hit[0] = tag_bram_rdata[0][19:0] == addr[31:12] && tag_bram_rdata[0][20];
        tag_hit[1] = tag_bram_rdata[1][19:0] == addr[31:12] && tag_bram_rdata[1][20];
    end

    // P3 state
    // if hit , then we return data to mem2
    logic [DCACHELINE_WIDTH-1:0] hit_data;
    always_comb begin
        hit = 0;
        hit_data = 0;
        if (p3_fifo_r_hit | p3_tag_hit[0] | p3_tag_hit[1]) begin
            hit = 1;
            for (integer i = 0; i < NWAY; i++) begin
                if (p3_tag_hit[i]) begin
                    hit_data = p3_data_bram_rdata[i];
                   end
            end
            if (p3_fifo_r_hit) begin
                hit_data = fifo_rdata;
            end
        end else begin
            hit = 0;
            hit_data = 0;
        end
    end

    //handshake with axi
    always_comb begin
        fifo_w_accept = 0;  // which used to tell fifo if it can send data to axi
        axi_req_o = 0;
        axi_addr_o = 0;
        axi_wdata_o = 0;
        axi_we_o = 0;
        axi_wstrb_o = 0;
        case (state)
            // if the state is idle,then the dcache is free
            // so send the wdata in fifo to axi when axi is free
            IDLE: begin
                if (axi_rdy_i & !fifo_state[0] & !miss) begin
                    fifo_w_accept = 1;
                    axi_req_o = 1;
                    axi_we_o = fifo_axi_wr_req;
                    axi_addr_o = fifo_axi_wr_addr;
                    axi_wdata_o = fifo_axi_wr_data;
                    axi_wstrb_o = 16'b1111_1111_1111_1111;
                end
            end
            //if the axi is free then send the read request
            READ_REQ, WRITE_REQ: begin
                if (axi_rdy_i) begin
                    axi_req_o  = 1;
                    axi_addr_o = cpu_addr;
                end
            end
            // wait for the data back
            READ_WAIT, WRITE_WAIT: begin
                axi_addr_o = cpu_addr;
            end
            default: begin
                axi_req_o = 0;
                fifo_w_accept = 0;
                axi_req_o = 0;
                axi_addr_o = 0;
                axi_wdata_o = 0;
                axi_we_o = 0;
                axi_wstrb_o = 0;
            end
        endcase

    end


    dcache_fifo u_dcache_fifo (
        .clk(clk),
        .rst(rst),
        //CPU write request
        .cpu_wreq_i(fifo_wreq),
        .cpu_awaddr_i(fifo_waddr),
        .cpu_wdata_i(fifo_wdata),
        .write_hit_o(fifo_w_hit),
        //CPU read request and response
        .cpu_rreq_i(fifo_rreq),
        .cpu_araddr_i(fifo_raddr),
        .read_hit_o(fifo_r_hit),
        .cpu_rdata_o(fifo_rdata),
        //FIFO state
        .state(fifo_state),
        //write to memory 
        .axi_bvalid_i(axi_rdy_i & (state == IDLE & !miss)),
        .axi_wen_o(fifo_axi_wr_req),
        .axi_wdata_o(fifo_axi_wr_data),
        .axi_awaddr_o(fifo_axi_wr_addr)
    );

    // LSFR
    lfsr #(
        .WIDTH(16)
    ) u_lfsr (
        .clk  (clk),
        .rst  (rst),
        .en   (1'b1),
        .value(random_r)
    );


    axi_dcache_master #(
        .ID(2)
    ) u_axi_master (
        .clk        (clk),
        .rst        (rst),
        .m_axi      (m_axi),
        .new_request(axi_req_o),
        .we         (axi_we_o),
        .addr       (axi_addr_o),
        .size       (3'b100),
        .data_in    (axi_wdata_o),
        .wstrb      (axi_wstrb_o),
        .ready_out  (axi_rdy_i),
        .rvalid_out (axi_rvalid_i),
        .wvalid_out (axi_bvalid_i),
        .data_out   (axi_data_i)
    );



    // BRAM instantiation
    generate
        for (genvar i = 0; i < NWAY; i++) begin : bram_ip
`ifdef BRAM_IP
            bram_dcache_tag_ram u_tag_bram (
                .clka (clk),
                .clkb (clk),
                .ena  (tag_bram_en[i]),
                .enb  (tag_bram_en[i]),
                .wea  (tag_bram_we[i]),
                .web  (0),
                .dina (tag_bram_wdata[i]),
                .addra(tag_bram_addr[i]),
                .douta(),
                .dinb (tag_bram_wdata[i]),
                .addrb(tag_bram_addr[i]),
                .doutb(tag_bram_rdata[i])
            );
            dcache_data_bram u_data_bram (
                .clka (clk),
                .clkb (clk),
                .ena  (data_bram_en[i]),
                .enb  (data_bram_en[i]),
                .wea  (data_bram_we[i]),
                .web  (0),
                .dina (data_bram_wdata[i]),
                .addra(data_bram_addr[i]),
                .douta(),
                .dinb (data_bram_wdata[i]),
                .addrb(data_bram_addr[i]),
                .doutb(data_bram_rdata[i])
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
                .addra(tag_bram_waddr[i]),
                .addrb(tag_bram_raddr[i]),
                .doutb(tag_bram_rdata[i])
            );
            byte_bram #(
                .DATA_WIDTH     (ICACHELINE_WIDTH),
                .DATA_DEPTH_EXP2($clog2(NSET))
            ) u_data_bram (
                .clk  (clk),
                .ena  (data_bram_en[i]),
                .enb  (data_bram_en[i]),
                .wea  (data_bram_we[i]),
                .dina (data_bram_wdata[i]),
                .addra(data_bram_waddr[i]),
                .addrb(data_bram_raddr[i]),
                .doutb(data_bram_rdata[i])
            );
`endif
        end
    endgenerate


endmodule


