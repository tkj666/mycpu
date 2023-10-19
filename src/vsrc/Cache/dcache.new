`include "core_config.sv"
`include "defines.sv"
`include "utils/lfsr.sv"
`include "utils/byte_bram.sv"
`include "utils/dual_port_lutram.sv"
`include "Cache/dcache_fifo.sv"
// `include "axi/axi_dcache_master.sv"
`include "axi/axi_read_channel.sv"
`include "axi/axi_write_channel.sv"
`include "axi/axi_interface.sv"

module dcache
    import core_config::*;
(
    input logic clk,
    input logic rst,
    input logic mem_valid,

    // mem req,come from ex
    input logic valid,
    input logic [`RegBus] paddr,
    input logic [2:0] req_type,
    input logic [3:0] wstrb,
    input logic [31:0] wdata,

    //  from mem1
    input logic uncache_en,

    //CACOP
    input logic cacop_i,
    input logic [1:0] cacop_mode_i,

    input logic cpu_flush,

    output logic [NWAY-1:0] tag_hit_o,

    output logic dcache_ready,
    output logic data_ok,
    output logic [31:0] rdata,

    axi_interface.master m_axi
);



endmodule