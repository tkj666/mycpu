`include "vsrc/defines.v"
`include "ram.v"
`include "AXI/axi_defines.v"
module SimTop(
    input clock,
    input reset,
    input[63:0] io_logCtrl_log_begin,
    input[63:0] io_logCtrl_log_end,
    input[63:0] io_logCtrl_log_level,
    input io_perfInfo_clean,
    input io_perfInfo_dump,
    output io_uart_out_valid,
    output[7:0]io_uart_out_ch,
    output io_uart_in_valid,
    input[7:0]io_uart_in_ch
  );

  wire chip_enable;
  wire[`RegBus] ram_raddr;
  wire[`RegBus] ram_rdata;
  wire[`RegBus] ramhelper_rdata;
  wire[`RegBus] ram_waddr;
  wire[`RegBus] ram_wdata;
  wire ram_wen;

  wire dram_ce;
  wire dram_we;
  wire[`DataAddrBus] dram_addr;
  wire[3:0] dram_sel;
  wire[`DataBus] dram_data_i;
  wire[`DataBus] dram_data_o;

  wire [`RegBus] debug_commit_pc;
  wire debug_commit_valid;
  wire[`InstBus] debug_commit_instr;
  wire debug_commit_wreg;
  wire [`RegAddrBus] debug_commit_reg_waddr;
  wire [`RegBus] debug_commit_reg_wdata;
  wire[1023:0] debug_reg;
  wire Instram_branch_flag;
  wire ram_flush;
  wire [6:0]ram_stall;

    //AXI interface
    //IRAM
    //ar
     wire [`ID]i_arid;  //arbitration
     wire [`ADDR]i_araddr;
     wire [`Len]i_arlen;
     wire [`Size]i_arsize;
     wire [`Burst]i_arburst;
     wire [`Lock]i_arlock;
     wire [`Cache]i_arcache;
     wire [`Prot]i_arprot;
     wire i_arvalid;
     wire i_arready;

    //r
     wire [`ID]i_rid;
     wire [`Data]i_rdata;
     wire [`Resp]i_rresp;
     wire i_rlast;//the last read data
     wire i_rvalid;
     wire i_rready;

    //aw
     wire [`ID]i_awid;
     wire [`ADDR]i_awaddr;
     wire [`Len]i_awlen;
     wire [`Size]i_awsize;
     wire [`Burst]i_awburst;
     wire [`Lock]i_awlock;
     wire [`Cache]i_awcache;
     wire [`Prot]i_awprot;
     wire i_awvalid;
     wire i_awready;

    //w
     wire [`ID]i_wid;
     wire [`Data]i_wdata;
     wire [3:0]i_wstrb;//字节选�?�位和sel差不�?
     wire  i_wlast;
     wire i_wvalid;
     wire i_wready;

    //b
     wire [`ID]i_bid;
     wire [`Resp]i_bresp;
     wire i_bvalid;
     wire i_bready;

     assign ram_raddr=i_araddr;
  cpu_top u_cpu_top(
            .clk(clock),
            .rst(reset),
            // .dram_data_i(dram_data_o),
            // .ram_rdata_i(ram_rdata),

            // .ram_raddr_o(ram_raddr),
            // .ram_wdata_o(ram_wdata),
            // .ram_waddr_o(ram_waddr),
            // .ram_wen_o (ram_wen),
            // .ram_en_o (chip_enable),

            // .dram_addr_o(dram_addr),
            // .dram_data_o(dram_data_i),
            // .dram_we_o(dram_we),
            // .dram_sel_o(dram_sel),
            // .dram_ce_o(dram_ce),

            .debug_commit_pc(debug_commit_pc        ),
            .debug_commit_valid(debug_commit_valid     ),
            .debug_commit_instr(debug_commit_instr     ),
            .debug_commit_wreg(debug_commit_wreg      ),
            .debug_commit_reg_waddr(debug_commit_reg_waddr ),
            .debug_commit_reg_wdata(debug_commit_reg_wdata ),
            .debug_reg(debug_reg   ),
            .Instram_branch_flag(Instram_branch_flag),
            .ram_flush(ram_flush),
            .ram_stall(ram_stall),

    //IRAM
    //ar
    .i_arid(i_arid),  //arbitration
    .i_araddr(i_araddr),
    .i_arlen(i_arlen),
    .i_arsize(i_arsize),
    .i_arburst(i_arburst),
    .i_arlock(i_arlock),
    .i_arcache(i_arcache),
    .i_arprot(i_arprot),
    .i_arvalid(i_arvalid),
    .i_arready(i_arready),

    //r
    .i_rid(i_rid),
    .i_rdata(i_rdata),
    .i_rresp(i_rresp),
    .i_rlast(i_rlast),//the last read data
    .i_rvalid(i_rvalid),
    .i_rready(i_rready),

    //aw
    .i_awid(i_awid),
    .i_awaddr(i_awaddr),
    .i_awlen(i_awlen),
    .i_awsize(i_awsize),
    .i_awburst(i_awburst),
    .i_awlock(i_awlock),
    .i_awcache(i_awcache),
    .i_awprot(i_awprot),
    .i_awvalid(i_awvalid),
    .i_awready(i_awready),

    //w
    .i_wid(i_wid),
    .i_wdata(i_wdata),
    .i_wstrb(i_wstrb),//字节选�?�位和sel差不�?
    .i_wlast(i_wlast),
    .i_wvalid(i_wvalid),
    .i_wready(i_wready),

    // //b
    .i_bid(i_bid),
      .i_bresp(i_bresp),
     .i_bvalid(i_bvalid),
     .i_bready(i_bready)

    // //DRAM
    // //ar
    // output wire [`ID]d_arid,  //arbitration
    // output wire [`ADDR]d_araddr,
    // output wire [`Len]d_arlen,
    // output wire [`Size]d_arsize,
    // output wire [`Burst]d_arburst,
    // output wire [`Lock]d_arlock,
    // output wire [`Cache]d_arcache,
    // output wire [`Prot]d_arprot,
    // output wire d_arvalid,
    // input wire d_arready,

    // //r
    // input wire [`ID]d_rid,
    // input wire [`Data]d_rdata,
    // input wire [`Resp]d_rresp,
    // input wire d_rlast,//the last read data
    // input wire d_rvalid,
    // output wire d_rready,

    // //aw
    // output wire [`ID]d_awid,
    // output wire [`ADDR]d_awaddr,
    // output wire [`Len]d_awlen,
    // output wire [`Size]d_awsize,
    // output wire [`Burst]d_awburst,
    // output wire [`Lock]d_awlock,
    // output wire [`Cache]d_awcache,
    // output wire [`Prot]d_awprot,
    // output wire d_awvalid,
    // input wire d_awready,

    // //w
    // output wire [`ID]d_wid,
    // output wire [`Data]d_wdata,
    // output wire [3:0]d_wstrb,//字节选�?�位和sel差不�?
    // output wire  d_wlast,
    // output wire d_wvalid,
    // input wire d_wready,

    // //b
    // input wire [`ID]d_bid,
    // input wire [`Resp]d_bresp,
    // input wire d_bvalid,
    // output wire d_bready
          );

`ifdef DUMP_WAVEFORM

  initial
    begin
      $dumpfile("wave.vcd");
      $dumpvars(0,u_cpu_top);
    end

`endif

// `ifndef DIFFTEST

//   ram u_ram(
//         .clock (clock ),
//         .reset (reset ),
//         .ce    (chip_enable),
//         .raddr (ram_raddr ),
//         .rdata (ram_rdata ),
//         .waddr (ram_waddr ),
//         .wdata (ram_wdata ),
//         .wen   (ram_wen   ),
//         .branch_flag_i(Instram_branch_flag),
//         .flush(ram_flush),
//         .stall(ram_stall)
//       );
// `endif


  // data_ram u_data_ram(
  //            .clk(clock),
  //            .ce(dram_ce),
  //            .we(dram_we),
  //            .addr(dram_addr),
  //            .sel(dram_sel),
  //            .data_i(dram_data_i),
  //            .data_o(dram_data_o)
  //          );

  wire aresetn;
  assign aresetn=~reset;
  inst_bram u_inst_bram(
    .s_aclk         (clock         ),
    .s_aresetn      (aresetn      ),

    //ar
    .s_axi_arid     (i_arid     ),
    .s_axi_araddr   (i_araddr-32'h1c000000  ),
    .s_axi_arlen    (i_arlen    ),
    .s_axi_arsize   (i_arsize   ),
    .s_axi_arburst  (i_arburst  ),
    .s_axi_arvalid  (i_arvalid  ),
    .s_axi_arready  (i_arready  ),
    //r
    .s_axi_rid      (i_rid      ),
    .s_axi_rdata    (i_rdata    ),
    .s_axi_rresp    (i_rresp    ),
    .s_axi_rlast    (i_rlast    ),
    .s_axi_rvalid   (i_rvalid   ),
    .s_axi_rready   (i_rready   ),
    //aw
    .s_axi_awid     (i_awid     ),
    .s_axi_awaddr   (i_awaddr   ),
    .s_axi_awlen    (i_awlen    ),
    .s_axi_awsize   (i_awsize   ),
    .s_axi_awburst  (i_awburst  ),
    .s_axi_awvalid  (i_awvalid  ),
    .s_axi_awready  (i_awready  ),
    //w
    .s_axi_wdata    (i_wdata    ),
    .s_axi_wstrb    (i_wstrb    ),
    .s_axi_wlast    (i_wlast    ),
    .s_axi_wvalid   (i_wvalid   ),
    .s_axi_wready   (i_wready   ),
    //b
    .s_axi_bid      (i_bid      ),
    .s_axi_bresp    (i_bresp    ),
    .s_axi_bvalid   (i_bvalid   ),
    .s_axi_bready   (i_bready   )
  );

`ifdef DIFFTEST

  reg coreid = 0;
  reg [7:0] index = 0;
  wire reset_n;
  assign reset_n = ~reset;



  wire[31:0] ram_rIdx = (ram_raddr - 32'h1c000000) >> 2;

  reg [63:0] cycleCnt;
  reg [63:0] instrCnt;
  reg [`RegBus] debug_commit_pc_1;
  reg debug_commit_valid_1;
  reg [`InstBus] debug_commit_instr_1;
  reg debug_commit_wreg_1;
  reg [`RegAddrBus] debug_commit_reg_waddr_1;
  reg [`RegBus] debug_commit_reg_wdata_1;
   
  reg [`RegBus] reg_ram_rdata;
  assign ram_rdata=reg_ram_rdata;


  always @(posedge clock or negedge reset_n)
    begin
      if (!reset_n)
        begin
          cycleCnt <= 0;
          instrCnt <= 0;
          debug_commit_instr_1 <= 0;
          debug_commit_valid_1 <= 0;
          debug_commit_pc_1 <= 0;
          debug_commit_wreg_1 <= 0;
          debug_commit_reg_waddr_1 <= 0;
          debug_commit_reg_wdata_1 <= 0;
        end
      else
        begin
          cycleCnt <= cycleCnt + 1;
          instrCnt <= instrCnt + debug_commit_valid;
          debug_commit_instr_1 <= debug_commit_instr;
          debug_commit_valid_1 <= debug_commit_valid & chip_enable;
          debug_commit_pc_1 <= debug_commit_pc;
          debug_commit_wreg_1 <= debug_commit_wreg;
          debug_commit_reg_waddr_1 <= debug_commit_reg_waddr;
          debug_commit_reg_wdata_1 <= debug_commit_reg_wdata;
          reg_ram_rdata <= ramhelper_rdata;
        end
    end

  DifftestTrapEvent difftest_trap_event(
                      .clock(clock),
                      .coreid(coreid),
                      .valid(),
                      .code(),
                      .pc(debug_commit_pc),
                      .cycleCnt(cycleCnt),
                      .instrCnt(instrCnt)
                    );

  RAMHelper ram_helper(
              .clk(clock),
              .en(chip_enable),
              .rIdx(ram_rIdx),
              .rdata(ramhelper_rdata),
              .wIdx(),
              .wdata(),
              .wmask(),
              .wen()
            );

  DifftestInstrCommit difftest_instr_commit(
                        .clock(clock),
                        .coreid(coreid),
                        .index(index),
                        .valid(debug_commit_valid_1), // Non-zero means valid, checked per-cycle, if valid, instr count as as commit
                        .pc(debug_commit_pc_1),
                        .instr(debug_commit_instr_1),
                        .skip(),
                        .is_TLBFILL(),
                        .TLBFILL_index(),
                        .is_CNTinst(),
                        .timer_64_value(),
                        .wen(debug_commit_wreg_1),
                        .wdest(debug_commit_reg_waddr_1),
                        .wdata(debug_commit_reg_wdata_1)
                      );

  DifftestArchIntRegState difftest_arch_int_reg_state(
                            .clock(clock),
                            .coreid(coreid),
                            .gpr_0(debug_reg[31:0]),
                            .gpr_1(debug_reg[63:32]),
                            .gpr_2(debug_reg[95:64]),
                            .gpr_3(debug_reg[127:96]),
                            .gpr_4(debug_reg[159:128]),
                            .gpr_5(debug_reg[191:160]),
                            .gpr_6(debug_reg[223:192]),
                            .gpr_7(debug_reg[255:224]),
                            .gpr_8(debug_reg[287:256]),
                            .gpr_9(debug_reg[319:288]),
                            .gpr_10(debug_reg[351:320]),
                            .gpr_11(debug_reg[383:352]),
                            .gpr_12(debug_reg[415:384]),
                            .gpr_13(debug_reg[447:416]),
                            .gpr_14(debug_reg[479:448]),
                            .gpr_15(debug_reg[511:480]),
                            .gpr_16(debug_reg[543:512]),
                            .gpr_17(debug_reg[575:544]),
                            .gpr_18(debug_reg[607:576]),
                            .gpr_19(debug_reg[639:608]),
                            .gpr_20(debug_reg[671:640]),
                            .gpr_21(debug_reg[703:672]),
                            .gpr_22(debug_reg[735:704]),
                            .gpr_23(debug_reg[767:736]),
                            .gpr_24(debug_reg[799:768]),
                            .gpr_25(debug_reg[831:800]),
                            .gpr_26(debug_reg[863:832]),
                            .gpr_27(debug_reg[895:864]),
                            .gpr_28(debug_reg[927:896]),
                            .gpr_29(debug_reg[959:928]),
                            .gpr_30(debug_reg[991:960]),
                            .gpr_31(debug_reg[1023:992])
                          );
`endif
endmodule
