`include "core_types.sv"
`include "core_config.sv"
`include "csr_defines.sv"
`include "muldiv/mul.sv"
`include "muldiv/mul_unit.sv"
`include "muldiv/div_unit.sv"
`include "muldiv/clz.sv"


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
    output logic branch_flag_o,
    output logic [`RegBus] branch_target_address,
    output logic [$clog2(FRONTEND_FTQ_SIZE)-1:0] branch_ftq_id_o,

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
    reg [DATA_WIDTH-1:0] arithout;

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
    logic [1:0] muldiv_op;  // High effective
    logic [2:0] mul_op;
    logic [2:0] div_op;
    always_comb begin
        case (aluop_i)
            `EXE_DIV_OP, `EXE_DIVU_OP, `EXE_MODU_OP, `EXE_MOD_OP: begin
                muldiv_op = 2'b01;
            end
            `EXE_MUL_OP, `EXE_MULH_OP, `EXE_MULHU_OP: begin
                muldiv_op = 2'b10;
            end
            default: begin
                muldiv_op = 0;
            end
        endcase
    end
    always_comb begin
        mul_op = 0;
        case (aluop_i)
            `EXE_MUL_OP:   mul_op = 3'h1;
            `EXE_MULH_OP:  mul_op = 3'h2;
            `EXE_MULHU_OP: mul_op = 3'h3;
            `EXE_DIV_OP:   div_op = 3'h4;
            `EXE_DIVU_OP:  div_op = 3'h5;
            `EXE_MOD_OP:   div_op = 3'h6;
            `EXE_MODU_OP:  div_op = 3'h7;
            default: begin
                mul_op = 0;
                div_op = 0;
            end
        endcase
    end

    logic mul_start;
    logic mul_already_start;
    logic mul_finish;
    logic mul_busy;
    logic mul_ack;
    logic [`RegBus] mul_result;

    always_ff @(posedge clk) begin
        if (rst) begin
            mul_start <= 0;
            mul_already_start <= 0;
        end else if (mul_op != 0 && mul_already_start == 0 && mul_start == 0) begin
            mul_start <= 1;
            mul_already_start <= 1;
        end else if (mul_finish) begin
            mul_already_start <= 0;
        end else begin
            mul_start <= 0;
            mul_already_start <= mul_already_start;
        end
    end

    always_comb begin
        mul_ack = mul_finish & muldiv_op == 2'b10 & ~stall[1];
    end

    mul_unit u_mul_unit (
        .clk(clk),
        .rst(rst),

        .start(mul_start),
        .rs1(reg1_i),
        .rs2(reg2_i),
        .op(mul_op[1:0]),

        .mul_ack(mul_ack),
        .valid_i(1),

        .ready(mul_busy),
        .done(mul_finish),
        .mul_result(mul_result)
    );

    logic div_start;
    logic div_already_start;
    logic div_finish;
    logic [`RegBus] quotient;
    logic [`RegBus] remainder;


    always_ff @(posedge clk) begin
        if (rst) begin
            div_start <= 0;
            div_already_start <= 0;
        end else if (div_op != 0 && div_already_start == 0 && div_start == 0) begin
            div_start <= 1;
            div_already_start <= 1;
        end else if (div_finish) begin
            div_already_start <= 0;
        end else begin
            div_start <= 0;
            div_already_start <= div_already_start;
        end
    end


    div_unit u_div_unit (
        .clk(clk),
        .rst(rst),

        .op(div_op[1:0]),
        .dividend(reg1_i),
        .divisor((reg2_i == 0 && (aluop_i == `EXE_DIV_OP || aluop_i == `EXE_DIVU_OP)) ? 1 : reg2_i),
        .divisor_is_zero(0),
        .start(div_start),

        .remainder_out(remainder),
        .quotient_out(quotient),
        .done(div_finish)
    );


    assign stallreq = (muldiv_op == 2'b01 & ~div_finish) | (muldiv_op == 2'b10 & ~mul_finish) |// Multiply & Division
                (icacop_inst & ~icacop_op_ack_i); // CACOP
    assign tlb_stallreq = aluop_i == `EXE_TLBRD_OP | aluop_i == `EXE_TLBSRCH_OP;

    always @(*) begin
        if (rst == `RstEnable) begin
            arithout = 0;
        end else begin
            case (aluop_i)
                `EXE_ADD_OP: arithout = reg1_i + reg2_i;
                `EXE_SUB_OP: arithout = reg1_i - reg2_i;
                `EXE_DIV_OP, `EXE_DIVU_OP: begin
                    arithout = quotient;
                end
                `EXE_MODU_OP, `EXE_MOD_OP: begin
                    arithout = remainder;
                end
                `EXE_MUL_OP, `EXE_MULH_OP, `EXE_MULHU_OP: begin
                    // Select result from multi-cycle divider
                    arithout = mul_result;
                end

                `EXE_SLT_OP, `EXE_SLTU_OP: arithout = {31'b0, reg1_lt_reg2};
                default: begin
                    arithout = 0;
                end
            endcase
        end
    end


    // means do we branch under current condition
    // however, this signal is not accurate because maybe waiting for load or other stalling condition
    logic branch_flag;
    assign branch_flag_o   = branch_flag;
    assign branch_ftq_id_o = branch_flag ? dispatch_i.instr_info.ftq_id : 0;
    always @(*) begin
        if (rst == `RstEnable) begin
            branch_flag = 1'b0;
            branch_target_address = `ZeroWord;
        end else begin
            // Default is not branching
            branch_flag = 1'b0;
            branch_target_address = `ZeroWord;
            case (aluop_i)
                `EXE_B_OP, `EXE_BL_OP: begin
                    branch_flag = 1'b1;
                    branch_target_address = inst_pc_i + imm;
                end
                `EXE_JIRL_OP: begin
                    branch_flag = 1'b1;
                    branch_target_address = reg1_i + imm;
                end
                `EXE_BEQ_OP: begin
                    if (oprand1 == oprand2) branch_flag = 1'b1;
                    branch_target_address = inst_pc_i + imm;
                end
                `EXE_BNE_OP: begin
                    if (oprand1 != oprand2) branch_flag = 1'b1;
                    branch_target_address = inst_pc_i + imm;
                end
                `EXE_BLT_OP: begin
                    if ({~reg1_i[31], reg1_i[30:0]} < {~reg2_i[31], reg2_i[30:0]})
                        branch_flag = 1'b1;
                    branch_target_address = inst_pc_i + imm;
                end
                `EXE_BGE_OP: begin
                    if ({~reg1_i[31], reg1_i[30:0]} >= {~reg2_i[31], reg2_i[30:0]})
                        branch_flag = 1'b1;
                    branch_target_address = inst_pc_i + imm;
                end
                `EXE_BLTU_OP: begin
                    if (reg1_i < reg2_i) branch_flag = 1'b1;
                    branch_target_address = inst_pc_i + imm;
                end
                `EXE_BGEU_OP: begin
                    if (reg1_i >= reg2_i) branch_flag = 1'b1;
                    branch_target_address = inst_pc_i + imm;
                end
                default: begin

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
