`include "defines.sv"
`include "csr_defines.sv"
`include "tlb_defines.sv"

module tlb 
(
    input logic clk,
    input logic [9:0] asid,
    //trans mode
    input logic inst_addr_trans_en,
    input logic data_addr_trans_en,
    //inst addr trans
    input inst_tlb_struct inst_i,
    output tlb_inst_struct inst_o,
    //data addr trans
    input data_tlb_struct data_i,
    output tlb_data_struct data_o,
    //tlbwi tlbwr tlb write
    input tlb_write_in_struct write_signal_i,
    //tlbr tlb read
    output tlb_read_out_struct read_signal_o,
    //invtlb 
    input tlb_inv_in_struct inv_signal_i,
    //from csr
    input logic [31:0]          csr_dmw0             ,
    input logic [31:0]          csr_dmw1             ,
    input logic                  csr_da               ,
    input logic                  csr_pg               
);

logic [18:0] s0_vppn     ;
logic        s0_odd_page ;
logic [ 5:0] s0_ps       ;
logic [19:0] s0_ppn      ;

logic [18:0] s1_vppn     ;
logic        s1_odd_page ;
logic [ 5:0] s1_ps       ;
logic [19:0] s1_ppn      ;

logic        we          ;
logic [ 4:0] w_index     ;
tlb_wr_port w_port;


logic [ 4:0] r_index     ;
tlb_wr_port r_port;

logic  [31:0] inst_vaddr_buffer  ;
logic  [31:0] data_vaddr_buffer  ;
logic [31:0] inst_paddr;
logic [31:0] data_paddr;

logic        pg_mode;
logic        da_mode;

always @(posedge clk) begin
    inst_vaddr_buffer <= inst_i.vaddr;
    data_vaddr_buffer <= data_i.vaddr;
end

//trans search port sig
assign s0_vppn     = inst_i.vaddr[31:13];
assign s0_odd_page = inst_i.vaddr[12];

assign s1_vppn     = data_i.vaddr[31:13];
assign s1_odd_page = data_i.vaddr[12];

//trans write port sig
assign we      = write_signal_i.tlbfill_en || write_signal_i.tlbwr_en;
assign w_index = ({5{write_signal_i.tlbfill_en}} & write_signal_i.rand_index) | ({5{write_signal_i.tlbwr_en}} & write_signal_i.tlbidx[`INDEX]);
assign w_port.vppn  = write_signal_i.tlbehi[`VPPN];
assign w_port.g     = write_signal_i.tlbelo0[`TLB_G] && write_signal_i.tlbelo1[`TLB_G];
assign w_port.ps    = write_signal_i.tlbidx[`PS];
assign w_port.e     = (write_signal_i.ecode == 6'h3f) ? 1'b1 : !write_signal_i.tlbidx[`NE];
assign w_port.v0    = write_signal_i.tlbelo0[`TLB_V];
assign w_port.d0    = write_signal_i.tlbelo0[`TLB_D];
assign w_port.plv0  = write_signal_i.tlbelo0[`TLB_PLV];
assign w_port.mat0  = write_signal_i.tlbelo0[`TLB_MAT];
assign w_port.ppn0  = write_signal_i.tlbelo0[`TLB_PPN_EN];
assign w_port.v1    = write_signal_i.tlbelo1[`TLB_V];
assign w_port.d1    = write_signal_i.tlbelo1[`TLB_D];
assign w_port.plv1  = write_signal_i.tlbelo1[`TLB_PLV];
assign w_port.mat1  = write_signal_i.tlbelo1[`TLB_MAT];
assign w_port.ppn1  = write_signal_i.tlbelo1[`TLB_PPN_EN];

//trans read port sig
assign r_index      = write_signal_i.tlbidx[`INDEX];
assign read_signal_o.tlbehi   = {r_port.vppn, 13'b0};
assign read_signal_o.tlbelo0  = {4'b0, r_port.ppn0, 1'b0, r_port.g, r_port.mat0, r_port.plv0, r_port.d0, r_port.v0};
assign read_signal_o.tlbelo1  = {4'b0, r_port.ppn1, 1'b0, r_port.g, r_port.mat1, r_port.plv1, r_port.d1, r_port.v1};
assign read_signal_o.tlbidx   = {!r_port.e, 1'b0, r_port.ps, 24'b0}; //note do not write index
assign read_signal_o.asid     = r_port.asid;

tlb_entry tlb_entry(
    .clk            (clk            ),
    // search port 0
    .s0_fetch       (inst_i.fetch     ),
    .s0_vppn        (s0_vppn        ),
    .s0_odd_page    (s0_odd_page    ),
    .s0_asid        (asid           ),
    .s0_found       (inst_o.tlb_found ),
    .s0_index       (),
    .s0_ps          (s0_ps          ),
    .s0_ppn         (s0_ppn         ),
    .s0_v           (inst_o.tlb_v     ),
    .s0_d           (inst_o.tlb_d     ),
    .s0_mat         (inst_o.tlb_mat   ),
    .s0_plv         (inst_o.tlb_plv   ),
    // search port 1
    .s1_fetch       (data_i.fetch     ),
    .s1_vppn        (s1_vppn        ),
    .s1_odd_page    (s1_odd_page    ),
    .s1_asid        (asid           ),
    .s1_found       (data_o.found ),
    .s1_index       (data_o.tlb_index ),
    .s1_ps          (s1_ps          ),
    .s1_ppn         (s1_ppn         ),
    .s1_v           (data_o.tlb_v     ),
    .s1_d           (data_o.tlb_d     ),
    .s1_mat         (data_o.tlb_mat   ),
    .s1_plv         (data_o.tlb_plv   ),
    // write port 
    .we(we),     
    .w_index(w_index),
    .write_port(w_port),
    //read port 
    .r_index(r_index),
    .read_port(r_port),
    //invalid port
    .inv_i(inv_signal_i)
);

assign pg_mode = !csr_da &&  csr_pg;
assign da_mode =  csr_da && !csr_pg;

assign inst_paddr = (pg_mode && inst_i.dmw0_en) ? {csr_dmw0[`PSEG], inst_vaddr_buffer[28:0]} :
                    (pg_mode && inst_i.dmw1_en) ? {csr_dmw1[`PSEG], inst_vaddr_buffer[28:0]} : inst_vaddr_buffer;

assign inst_o.offset = inst_i.vaddr[3:0];
assign inst_o.index  = inst_i.vaddr[11:4];
assign inst_o.tag    = inst_addr_trans_en ? ((s0_ps == 6'd12) ? s0_ppn : {s0_ppn[19:10], inst_paddr[21:12]}) : inst_paddr[31:12];

assign data_paddr = (pg_mode && data_i.dmw0_en && !data_i.cacop_op_mode_di) ? {csr_dmw0[`PSEG], data_vaddr_buffer[28:0]} : 
                    (pg_mode && data_i.dmw1_en && !data_i.cacop_op_mode_di) ? {csr_dmw1[`PSEG], data_vaddr_buffer[28:0]} : data_vaddr_buffer;

assign data_o.offset = data_i.vaddr[3:0];
assign data_o.index  = data_i.vaddr[11:4];
assign data_o.tag    = data_addr_trans_en ? ((s1_ps == 6'd12) ? s1_ppn : {s1_ppn[19:10], data_paddr[21:12]}) : data_paddr[31:12];

endmodule