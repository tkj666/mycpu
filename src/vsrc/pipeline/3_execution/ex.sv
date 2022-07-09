`include "core_types.sv"
`include "core_config.sv"
`include "csr_defines.sv"
`include "muldiv/mul.sv"

module ex
    import core_types::*;
    import core_config::*;
    import csr_defines::*;
(
    input logic clk,
    input logic rst,

    // <- Dispatch
    // Information from dispatch
    input dispatch_ex_struct dispatch_i,

    // <- MEM 
    // Data forward
    input mem_data_forward_t [1:0] mem_data_forward_i,  // TODO: remove magic number

    input logic [18:0] csr_vppn,
    input logic llbit,

    // -> MEM
    output ex_mem_struct ex_o_buffer,

    // <- CSR
    input [63:0] timer_64,
    input [31:0] tid,

    // Multi-cycle ALU stallreq
    output logic stallreq,
    output logic tlb_stallreq,

    // -> Ctrl
    // Redirect is only triggered when mispredict happens
    output logic ex_redirect_o,
    output logic [ADDR_WIDTH-1:0] ex_redirect_target_o,
    output logic [$clog2(FRONTEND_FTQ_SIZE)-1:0] ex_redirect_ftq_id_o,

    output ex_dispatch_struct ex_data_forward,

    // <-> Cache
    output logic icacop_op_en,
    input logic icacop_op_ack_i,
    output logic dcacop_op_en,
    output logic [1:0] cacop_op_mode,

    input logic excp_flush,
    input logic ertn_flush,

    // Stall & flush
    input logic [1:0] stall,  // {mem_wb, ex}
    input logic flush

);

    reg [`RegBus] logicout;
    reg [`RegBus] shiftout;
    reg [`RegBus] moveout;
    reg [63:0] arithout;

    ex_mem_struct ex_o;

    // Assign input /////////////////////////////
    instr_info_t instr_info;
    special_info_t special_info;
    assign instr_info   = dispatch_i.instr_info;
    assign special_info = dispatch_i.instr_info.special_info;

    // ALU 
    logic [ `AluOpBus] aluop_i;
    logic [`AluSelBus] alusel_i;
    assign aluop_i  = dispatch_i.aluop;
    assign alusel_i = dispatch_i.alusel;

    logic [1:0][`RegAddrBus] read_reg_addr;
    assign read_reg_addr = dispatch_i.read_reg_addr;

    // Determine oprands
    logic [`RegBus] reg1_i, reg2_i, imm, oprand1, oprand2;
    always_comb begin
        if(mem_data_forward_i[1].write_reg == `WriteEnable && mem_data_forward_i[1].is_load_data && mem_data_forward_i[1].write_reg_addr == dispatch_i.read_reg_addr[0] && mem_data_forward_i[1].write_reg_addr != 0)
            oprand1 = mem_data_forward_i[1].write_reg_data;
        else if(mem_data_forward_i[0].write_reg == `WriteEnable && mem_data_forward_i[0].is_load_data && mem_data_forward_i[0].write_reg_addr == dispatch_i.read_reg_addr[0] && mem_data_forward_i[0].write_reg_addr != 0)
            oprand1 = mem_data_forward_i[0].write_reg_data;
        else oprand1 = dispatch_i.oprand1;
        if(mem_data_forward_i[1].write_reg == `WriteEnable && mem_data_forward_i[1].is_load_data && mem_data_forward_i[1].write_reg_addr == dispatch_i.read_reg_addr[1] && mem_data_forward_i[1].write_reg_addr != 0)
            oprand2 = mem_data_forward_i[1].write_reg_data;
        else if(mem_data_forward_i[0].write_reg == `WriteEnable && mem_data_forward_i[0].is_load_data && mem_data_forward_i[0].write_reg_addr == dispatch_i.read_reg_addr[1] && mem_data_forward_i[0].write_reg_addr != 0)
            oprand2 = mem_data_forward_i[0].write_reg_data;
        else oprand2 = dispatch_i.oprand2;
    end
    assign reg1_i = oprand1;
    assign reg2_i = dispatch_i.use_imm ? dispatch_i.imm : oprand2;
    assign imm = dispatch_i.imm;

    logic [`RegBus] inst_i, inst_pc_i;
    assign inst_i = dispatch_i.instr_info.instr;
    assign inst_pc_i = dispatch_i.instr_info.pc;

    logic wreg_i;
    logic [`RegAddrBus] wd_i;
    assign wd_i = dispatch_i.reg_write_addr;
    assign wreg_i = dispatch_i.reg_write_valid;

    assign ex_o.aluop = aluop_i;
    logic [`InstAddrBus] debug_mem_addr_o;
    assign debug_mem_addr_o = ex_o.mem_addr;

    // TODO:fix vppn select
    assign ex_o.mem_addr = reg1_i + imm;
    assign ex_o.reg2 = reg2_i;

    assign ex_data_forward = {ex_o.wreg, ex_o.waddr, ex_o.wdata, ex_o.aluop};

    csr_write_signal csr_signal_i, csr_test;
    assign csr_signal_i = dispatch_i.csr_signal;
    assign csr_test = ex_o.csr_signal;

    //写入csr的数据，对csrxchg指令进行掩码处理
    assign ex_o.csr_signal.we = csr_signal_i.we;
    assign ex_o.csr_signal.addr = csr_signal_i.addr;
    assign ex_o.csr_signal.data = (aluop_i ==`EXE_CSRXCHG_OP) ? ((reg1_i & reg2_i) | (~reg2_i & dispatch_i.csr_reg_data)) : oprand1;

    logic [`RegBus] csr_reg_data;
    assign csr_reg_data = aluop_i == `EXE_RDCNTID_OP ? tid :
                          aluop_i == `EXE_RDCNTVL_OP ? timer_64[31:0] :
                          aluop_i == `EXE_RDCNTVH_OP ? timer_64[63:32] :
                          dispatch_i.csr_reg_data;


    //cache ins
    logic cacop_instr, icacop_inst, dcacop_inst;
    logic [4:0] cacop_op;
    assign cacop_op = inst_i[4:0];
    assign cacop_instr = aluop_i == `EXE_CACOP_OP;
    assign icacop_inst = cacop_instr && (cacop_op[2:0] == 3'b0);
    assign icacop_op_en = icacop_inst && !excp && !(flush | excp_flush | ertn_flush);
    assign dcacop_inst = cacop_instr && (cacop_op[2:0] == 3'b1);
    assign dcacop_op_en = dcacop_inst && !excp && !(flush | excp_flush | ertn_flush);
    assign cacop_op_mode = cacop_op[4:3];

    logic excp_ale, excp_ine, excp;
    logic [9:0] excp_num;
    logic access_mem, mem_load_op, mem_store_op, mem_b_op, mem_h_op;
    //对未对齐例外的判断
    assign excp_ale = access_mem && ((mem_b_op & 1'b0)| (mem_h_op & ex_o.mem_addr[0])| 
                    (!(mem_b_op | mem_h_op) & (ex_o.mem_addr[0] | ex_o.mem_addr[1]))) ;
    assign excp_ine = aluop_i == `EXE_INVTLB_OP && imm > 32'd6;
    assign excp_num = {excp_ale, instr_info.excp_num[8:0] | {1'b0, excp_ine, 7'b0}};
    assign excp = instr_info.excp | excp_ale | excp_ine;

    assign access_mem = mem_load_op | mem_store_op;

    assign mem_load_op = special_info.mem_load;


    assign mem_store_op = special_info.mem_store;
    assign mem_b_op = special_info.mem_b_op;
    assign mem_h_op = special_info.mem_h_op;

    always @(*) begin
        if (rst == `RstEnable) begin
            logicout = `ZeroWord;
        end else begin
            case (aluop_i)
                `EXE_OR_OP: begin
                    logicout = reg1_i | reg2_i;
                end
                `EXE_AND_OP: begin
                    logicout = reg1_i & reg2_i;
                end
                `EXE_XOR_OP: begin
                    logicout = reg1_i ^ reg2_i;
                end
                `EXE_NOR_OP: begin
                    logicout = ~(reg1_i | reg2_i);
                end
                `EXE_ORN_OP: begin
                    logicout = reg1_i | ~(reg2_i);
                end
                `EXE_ANDN_OP: begin
                    logicout = reg1_i & ~(reg2_i);
                end
                default: begin
                    logicout = `ZeroWord;
                end
            endcase
        end
    end

    always @(*) begin
        if (rst == `RstEnable) begin
            shiftout = `ZeroWord;
        end else begin
            case (aluop_i)
                `EXE_SLL_OP: begin
                    shiftout = reg1_i << reg2_i[4:0];
                end
                `EXE_SRL_OP: begin
                    shiftout = reg1_i >> reg2_i[4:0];
                end
                `EXE_SRA_OP: begin
                    shiftout = ({32{reg1_i[31]}} << (6'd32-{1'b0,reg2_i[4:0]})) | reg1_i >> reg2_i[4:0];
                end
                default: begin
                    shiftout = `ZeroWord;
                end
            endcase
        end
    end

    //比较模块
    logic reg1_lt_reg2;
    logic [`RegBus] reg2_i_mux;
    logic [`RegBus] result_compare;

    assign reg2_i_mux = (aluop_i == `EXE_SLT_OP) ? ~reg2_i + 32'b1 : reg2_i; // shifted encoding when signed comparison
    assign result_compare = reg1_i + reg2_i_mux;
    assign reg1_lt_reg2  = (aluop_i == `EXE_SLT_OP) ? ((reg1_i[31] && !reg2_i[31]) || (!reg1_i[31] && !reg2_i[31] && result_compare[31])||
			               (reg1_i[31] && reg2_i[31] && result_compare[31])) : (reg1_i < reg2_i);


    // Divider and Multiplier
    // Multi-cycle
    logic muldiv_op;  // High effective
    always_comb begin
        case (aluop_i)
            `EXE_DIV_OP, `EXE_DIVU_OP, `EXE_MODU_OP, `EXE_MOD_OP,`EXE_MUL_OP,`EXE_MULH_OP,`EXE_MULHU_OP: begin
                muldiv_op = 1;
            end
            default: begin
                muldiv_op = 0;
            end
        endcase
    end
    logic [2:0] muldiv_para;  // 0-7 muldiv mode selection
    always_comb begin
        case (aluop_i)
            `EXE_MUL_OP:   muldiv_para = 3'h0;
            `EXE_MULH_OP:  muldiv_para = 3'h1;
            `EXE_MULHU_OP: muldiv_para = 3'h3;
            `EXE_DIV_OP:   muldiv_para = 3'h4;
            `EXE_DIVU_OP:  muldiv_para = 3'h5;
            `EXE_MOD_OP:   muldiv_para = 3'h6;
            `EXE_MODU_OP:  muldiv_para = 3'h7;
            default: begin
                muldiv_para = 0;
            end
        endcase
    end
    logic [31:0] muldiv_result;
    logic muldiv_finished;
    logic muldiv_ack;
    logic muldiv_busy_r;
    logic muldiv_init;
    logic muldiv_busy;  // Low means busy
    always_ff @(posedge clk) begin
        if (rst) muldiv_busy_r <= 0;
        else if (flush | excp_flush | ertn_flush) muldiv_busy_r <= 0;
        else if (muldiv_init) muldiv_busy_r <= 1;
        else if (muldiv_ack) muldiv_busy_r <= 0;
    end
    always_comb begin
        muldiv_init = muldiv_op & ~muldiv_busy_r & ~stall[1];
        muldiv_ack  = muldiv_finished & muldiv_op & ~stall[1];
    end
    mul u_mul (
        .clk(clk),
        .rst(rst),
        .clear_pipeline(flush),
        .mul_para(muldiv_para),
        .mul_initial(muldiv_init),
        .mul_rs0(reg1_i),
        .mul_rs1((reg2_i == 0 && (aluop_i == `EXE_DIV_OP || aluop_i == `EXE_DIVU_OP)) ? 1 : reg2_i),
        .mul_ready(muldiv_busy),
        .mul_finished(muldiv_finished),  // 1 means finished
        .mul_data(muldiv_result),
        .mul_ack(muldiv_ack)
    );


    assign stallreq = (icacop_inst & ~icacop_op_ack_i);  // CACOP
    //(muldiv_op & ~muldiv_finished) | // Multiply & Division
    assign tlb_stallreq = aluop_i == `EXE_TLBRD_OP | aluop_i == `EXE_TLBSRCH_OP;

    always @(*) begin
        if (rst == `RstEnable) begin
            arithout = 0;
        end else begin
            case (aluop_i)
                `EXE_ADD_OP:   arithout = reg1_i + reg2_i;
                `EXE_SUB_OP:   arithout = reg1_i - reg2_i;
                // `EXE_DIV_OP, `EXE_DIVU_OP, `EXE_MODU_OP, `EXE_MOD_OP,`EXE_MUL_OP,`EXE_MULH_OP,`EXE_MULHU_OP: begin
                //     // Select result from multi-cycle divider
                //     arithout = muldiv_result;
                // end
                `EXE_MUL_OP:   arithout = $signed(reg1_i) * $signed(reg2_i);
                `EXE_MULH_OP:  arithout = ($signed(reg1_i) * $signed(reg2_i)) >> 32;
                `EXE_MULHU_OP: arithout = ($unsigned(reg1_i) * $unsigned(reg2_i)) >> 32;
                `EXE_DIV_OP:   arithout = ($signed(reg1_i) / $signed(reg2_i));
                `EXE_DIVU_OP:  arithout = ($unsigned(reg1_i) / $unsigned(reg2_i));
                `EXE_MODU_OP:  arithout = ($unsigned(reg1_i) % $unsigned(reg2_i));
                `EXE_MOD_OP: begin
                    arithout = ($signed(reg1_i) % $signed(reg2_i));
                end

                `EXE_SLT_OP, `EXE_SLTU_OP: arithout = {31'b0, reg1_lt_reg2};
                default: begin
                    arithout = 0;
                end
            endcase
        end
    end

    // Branch Unit
    // means do we branch under current condition
    // however, this signal is not accurate because maybe waiting for load or other stalling condition
    logic branch_flag;
    // Only when taken & not predicted taken can ex do redirect
    assign ex_redirect_o = branch_flag && ~special_info.predicted_taken && ~stall[0];
    assign ex_redirect_ftq_id_o = ex_redirect_o ? instr_info.ftq_id : 0;
    always_comb begin
        begin
            case (aluop_i)
                `EXE_B_OP, `EXE_BL_OP: begin
                    branch_flag = 1'b1;
                    ex_redirect_target_o = inst_pc_i + imm;
                end
                `EXE_JIRL_OP: begin
                    branch_flag = 1'b1;
                    ex_redirect_target_o = reg1_i + imm;
                end
                `EXE_BEQ_OP: begin
                    if (oprand1 == oprand2) branch_flag = 1'b1;
                    ex_redirect_target_o = inst_pc_i + imm;
                end
                `EXE_BNE_OP: begin
                    if (oprand1 != oprand2) branch_flag = 1'b1;
                    ex_redirect_target_o = inst_pc_i + imm;
                end
                `EXE_BLT_OP: begin
                    if ({~reg1_i[31], reg1_i[30:0]} < {~reg2_i[31], reg2_i[30:0]})
                        branch_flag = 1'b1;
                    ex_redirect_target_o = inst_pc_i + imm;
                end
                `EXE_BGE_OP: begin
                    if ({~reg1_i[31], reg1_i[30:0]} >= {~reg2_i[31], reg2_i[30:0]})
                        branch_flag = 1'b1;
                    ex_redirect_target_o = inst_pc_i + imm;
                end
                `EXE_BLTU_OP: begin
                    if (reg1_i < reg2_i) branch_flag = 1'b1;
                    ex_redirect_target_o = inst_pc_i + imm;
                end
                `EXE_BGEU_OP: begin
                    if (reg1_i >= reg2_i) branch_flag = 1'b1;
                    ex_redirect_target_o = inst_pc_i + imm;
                end
                default: begin
                    branch_flag = 1'b0;
                    ex_redirect_target_o = 0;
                end
            endcase
        end
    end


    always @(*) begin
        if (rst == `RstEnable) begin
            moveout = `ZeroWord;
        end else begin
            case (aluop_i)
                `EXE_LUI_OP: begin
                    moveout = reg2_i;
                end
                `EXE_PCADD_OP: begin
                    moveout = reg2_i + ex_o.instr_info.pc;
                end
                default: begin
                    moveout = `ZeroWord;
                end
            endcase
        end
    end
    logic [31:0] wdata;
    assign wdata = ex_o.wdata;

    always_comb begin
        ex_o.instr_info = stallreq ? 0 : dispatch_i.instr_info;
        ex_o.instr_info.excp = excp;
        ex_o.instr_info.excp_num = excp_num;

        // If the branch taken, then this basic block should be ended
        if (branch_flag) ex_o.instr_info.is_last_in_block = 1;

        ex_o.waddr = wd_i;
        ex_o.wreg = wreg_i;
        ex_o.timer_64 = timer_64;
        ex_o.cacop_en = cacop_instr;
        ex_o.icache_op_en = icacop_op_en;
        ex_o.cacop_op = cacop_op;
        ex_o.inv_i = aluop_i == `EXE_INVTLB_OP ? {1'b1, oprand1[9:0], oprand2[31:13], imm[4:0]} : 0;
        case (alusel_i)
            `EXE_RES_LOGIC: begin
                ex_o.wdata = logicout;
            end
            `EXE_RES_SHIFT: begin
                ex_o.wdata = shiftout;
            end
            `EXE_RES_MOVE: begin
                ex_o.wdata = moveout;
            end
            `EXE_RES_ARITH: begin
                ex_o.wdata = arithout;
            end
            `EXE_RES_JUMP: begin
                ex_o.wdata = inst_pc_i + 4;
            end
            `EXE_RES_CSR: begin
                ex_o.wdata = csr_reg_data;
            end
            default: begin
                ex_o.wdata = `ZeroWord;
            end
        endcase
    end


    always_ff @(posedge clk) begin
        if (rst == `RstEnable) begin
            ex_o_buffer <= 0;
        end else if (flush | excp_flush | ertn_flush) begin
            ex_o_buffer <= 0;
        end else if (stall[0]) begin
            // Do nothing
        end else begin
            ex_o_buffer <= ex_o;
        end
    end

endmodule
