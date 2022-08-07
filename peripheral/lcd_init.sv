`define COLOR_ADDR 17'd803
`define INIT_END   17'd123302//重要一定要配置好
`define KEEP_TIME  32'd3_0000_0000//keep 5s
`define DATA32
module lcd_init (
        input  logic        pclk,
        input  logic        rst_n,
        input  logic        init_write_ok,
        output logic [15:0] init_data,
        output logic [16:0] init_addra,
        output logic        we,
        output logic        wr,
        output logic        rs,
        output logic        init_work,
        output logic        init_finish
    );
    logic refresh_flag;
    logic [4:0]refresh_addra;
    logic [15:0]refresh_data;
    logic [31:0]refresh_counter;
    logic is_color;
    enum int {
             IDLE,
             INIT,
             CLEAR,//to refresh the lcd
             DRAW_BG,//to draw the background
             DRAW_LOGO,
             INIT_FINISH,
             LOGO_KEEPING//to keep the logo for a while
         } init_state;
    enum int {
             WAIT_INIT,
             DELAY
         } delay_state;
    logic [16:0] addra;
    logic [31:0] delay_counter;

    //初始化序列需要延迟一段时间
    always_ff @(posedge pclk) begin
        if (~rst_n) begin
            delay_state   <= WAIT_INIT;
            delay_counter <= 0;
        end
        else begin
            case (delay_state)
                WAIT_INIT: begin
                    if (init_write_ok && addra == 17'd762 && delay_counter <= 40000)
                        delay_state <= DELAY;
                end
                DELAY: begin
                    if (delay_counter <= 40000)
                        delay_counter <= delay_counter + 1;
                    else
                        delay_state <= WAIT_INIT;
                end
                default: begin
                    delay_state   <= WAIT_INIT;
                    delay_counter <= 0;
                end
            endcase
        end
    end

    //logo需要保持一段时间
    logic [31:0]delay_time;
    always_ff @( posedge pclk ) begin
        if(~rst_n)
            delay_time<=0;
        else if(init_state==LOGO_KEEPING)
            delay_time<=delay_time+1;
        else
            delay_time<=0;
    end

    always_ff @(posedge pclk) begin
        if (~rst_n) begin
            init_state <= IDLE;
            addra <= 0;
            we <= 0;
            wr <= 1;
            rs <= 0;
            init_work <= 1;
            init_finish <= 0;
            refresh_addra<=0;
            refresh_flag<=0;
            refresh_counter<=0;
            is_color<=0;
        end
        else begin
            case (init_state)
                IDLE: begin
                    init_state <= INIT;
                    addra <= 0;
                    we <= 1;
                    wr <= 1;
                    rs <= 0;
                    init_work <= 1;
                    init_finish <= 0;
                end
                //hardware initial
                INIT: begin
                    if (init_write_ok) begin
                        //init finish
                        if (addra == 17'd783) begin
                            init_state <= CLEAR;
                            addra <= addra+1;
                            we <= 0;
                            wr <= 1;
                            rs <= 0;
                            init_work <= 1;
                            init_finish <= 0;
                            refresh_addra<=0;
                            refresh_flag<=1;
                            refresh_counter<=0;
                        end
                        else begin
                            addra <= addra + 1;
                            we <= 0;
                        end
                    end
                    else if (delay_state == DELAY) begin
                        we <= 0;
                    end
                    else begin
                        init_state <= INIT;
                        addra <= addra;
                        we <= 1;
                        wr <= 1;
                        if (addra == 17'd763)
                            rs <= 0;
                        else if (addra[0] == 1)
                            rs <= 1;
                        else
                            rs <= 0;
                        init_work   <= 1;
                        init_finish <= 0;
                    end
                end
                //refresh LCD,draw white
                CLEAR: begin
                    init_state<=DRAW_BG;
                    we <= 0;
                    wr <= 1;
                    rs <= 0;
                    init_work <= 1;
                    init_finish <= 0;
                    refresh_flag<=1;
                    refresh_addra<=0;
                    is_color<=1;
                    refresh_counter<=1;
                end
                //draw white,give the params to lcd
                DRAW_BG: begin
                    if(init_write_ok) begin
                        if(refresh_counter==384000) begin
                            init_state <= DRAW_LOGO;
                            addra <= addra;
                            we <= 0;
                            wr <= 1;
                            rs <= 0;
                            init_work <= 1;
                            init_finish <= 0;
                            refresh_flag<=0;
                            is_color<=0;
                        end
                        else begin
                            we<=0;
                            refresh_counter<=refresh_counter+1;
                        end
                    end
                    else begin
                        rs<=1;
                        we <= 1;
                        wr <= 1;
                    end
                end
                //draw logo
                DRAW_LOGO: begin
                    if (init_write_ok) begin
                        //draw logo
                        if (addra == `INIT_END) begin
                            init_state <= LOGO_KEEPING;
                            addra <= 0;
                            we <= 0;
                            wr <= 1;
                            rs <= 0;
                            init_work <= 1;
                            init_finish <= 0;
                        end
                        else begin
                            addra <= addra + 1;
                            we <= 0;
                        end
                    end
                    else begin
                        init_state <= DRAW_LOGO;
                        addra <= addra;
                        we <= 1;
                        wr <= 1;
                        if (addra >=`COLOR_ADDR)
                            rs <= 1;
                        else if (addra[0] == 1)
                            rs <= 1;
                        else
                            rs <= 0;
                    end
                end
                //logo should keep for a while，then turn to the game table
                LOGO_KEEPING: begin
                    we<=0;
                    init_work<=1;
                    init_finish<=0;
                    if(delay_time<=`KEEP_TIME)
                        init_state<=LOGO_KEEPING;
                    else
                        init_state<=INIT_FINISH;
                end
                //initial finish，the cpu can control the LCD by AXI
                INIT_FINISH: begin
                    init_state <= INIT_FINISH;
                    addra <= 0;
                    we <= 0;
                    wr <= 1;
                    rs <= 0;
                    init_work <= 0;
                    init_finish <= 1;
                end
                default: begin
                    init_state <= IDLE;
                    addra <= 0;
                    we <= 0;
                    wr <= 1;
                    rs <= 0;
                    init_work <= 1;
                    init_finish <= 0;
                end
            endcase
        end
    end
    assign init_addra=addra;
`ifdef  DATA32

    logic [31:0]data_o;
    assign init_data=refresh_flag?(is_color?16'hffff:0):data_o[15:0];
`else
    logic [15:0]data_o;
    assign init_data=refresh_flag?(is_color?16'hffff:0):data_o;
`endif

    //注意bram的时序，选择单口bram，无流水线
    //initial code
    lcd_init_bram u_lcd_init_bram (
                      .clka (pclk),      // input wire clka
                      .ena  (1),         // input wire ena
                      .wea  (0),         // input wire [0 : 0] wea
                      .addra(addra),     // input wire [16 : 0] addra
                      .dina (0),         // input wire [15 : 0] dina
                      .douta(data_o)  // output wire [15 : 0] douta
                  );
    ila_2 lcd_init_debug (
              .clk(pclk), // input wire clk


              .probe0(init_data), // input wire [15:0]  probe0
              .probe1(addra) // input wire [16:0]  probe1
          );

endmodule