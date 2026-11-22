`timescale 1ns / 1ps

// 监控程序（基础版）冒烟测试：把课程 kernel bin 装到 0x80000000，用真实监控程序
// 启动，走一遍 boot message / W / D / G / D 命令；G 的用户程序放在 0x80100000。
// 用来确认基础测例里依赖监控程序的路径也能在本地跑通。
//
// plusargs: +IMAGE=<addr word 每行一个字的 kernel 镜像>
module tb_monitor_soc;
  localparam logic [31:0] UART_ADDR = 32'h1000_0000;
  localparam int MAX_WAIT = 2_000_000;

  logic clk_50M = 0;
  always #10 clk_50M = ~clk_50M;

  logic reset_btn = 1;
  wire [31:0] base_ram_data, ext_ram_data;
  wire [19:0] base_ram_addr, ext_ram_addr;
  wire [3:0] base_ram_be_n, ext_ram_be_n;
  wire base_ram_ce_n, base_ram_oe_n, base_ram_we_n;
  wire ext_ram_ce_n, ext_ram_oe_n, ext_ram_we_n;
  wire txd_pin, rxd_pin;

  thinpad_top dut (
      .clk_50M(clk_50M), .clk_11M0592(1'b0), .push_btn(1'b0), .reset_btn(reset_btn),
      .touch_btn(4'b0), .dip_sw(32'b0), .leds(), .dpy0(), .dpy1(),
      .uart_rdn(), .uart_wrn(), .uart_dataready(1'b0), .uart_tbre(1'b0), .uart_tsre(1'b0),
      .base_ram_data(base_ram_data), .base_ram_addr(base_ram_addr), .base_ram_be_n(base_ram_be_n),
      .base_ram_ce_n(base_ram_ce_n), .base_ram_oe_n(base_ram_oe_n), .base_ram_we_n(base_ram_we_n),
      .ext_ram_data(ext_ram_data), .ext_ram_addr(ext_ram_addr), .ext_ram_be_n(ext_ram_be_n),
      .ext_ram_ce_n(ext_ram_ce_n), .ext_ram_oe_n(ext_ram_oe_n), .ext_ram_we_n(ext_ram_we_n),
      .txd(txd_pin), .rxd(rxd_pin),
      .flash_a(), .flash_d(), .flash_rp_n(), .flash_vpen(), .flash_ce_n(), .flash_oe_n(),
      .flash_we_n(), .flash_byte_n(), .sl811_a0(), .sl811_wr_n(), .sl811_rd_n(), .sl811_cs_n(),
      .sl811_rst_n(), .sl811_dack_n(), .sl811_intrq(1'b0), .sl811_drq_n(1'b1),
      .dm9k_cmd(), .dm9k_sd(), .dm9k_iow_n(), .dm9k_ior_n(), .dm9k_cs_n(), .dm9k_pwrst_n(),
      .dm9k_int(1'b0), .video_red(), .video_green(), .video_blue(), .video_hsync(), .video_vsync(),
      .video_clk(), .video_de()
  );

  sram_model base1 (.DataIO(base_ram_data[15:0]), .Address(base_ram_addr), .OE_n(base_ram_oe_n), .CE_n(base_ram_ce_n),
                    .WE_n(base_ram_we_n), .LB_n(base_ram_be_n[0]), .UB_n(base_ram_be_n[1]));
  sram_model base2 (.DataIO(base_ram_data[31:16]), .Address(base_ram_addr), .OE_n(base_ram_oe_n), .CE_n(base_ram_ce_n),
                    .WE_n(base_ram_we_n), .LB_n(base_ram_be_n[2]), .UB_n(base_ram_be_n[3]));
  sram_model ext1 (.DataIO(ext_ram_data[15:0]), .Address(ext_ram_addr), .OE_n(ext_ram_oe_n), .CE_n(ext_ram_ce_n),
                   .WE_n(ext_ram_we_n), .LB_n(ext_ram_be_n[0]), .UB_n(ext_ram_be_n[1]));
  sram_model ext2 (.DataIO(ext_ram_data[31:16]), .Address(ext_ram_addr), .OE_n(ext_ram_oe_n), .CE_n(ext_ram_ce_n),
                   .WE_n(ext_ram_we_n), .LB_n(ext_ram_be_n[2]), .UB_n(ext_ram_be_n[3]));

  uart_model uart (.rxd(txd_pin), .txd());  // 只收 CPU 的 txd；txd 由下面的发送器驱动
  reg [7:0] uart_rx[$];
  always @(posedge uart.rxd_data_ready) uart_rx.push_back(uart.rxd_data);

  // 测试bench -> CPU 的串口发送器（和 CPU 同一个 10 MHz 时钟）
  logic tx_start = 0;
  logic [7:0] tx_data = 0;
  wire tx_busy;
  async_transmitter #(.ClkFrequency(10_000_000), .Baud(115200)) u_tx (
      .clk(dut.sys_clk), .TxD_start(tx_start), .TxD_data(tx_data), .TxD(rxd_pin), .TxD_busy(tx_busy));

  task automatic send_byte(input logic [7:0] b);
    @(negedge dut.sys_clk);
    tx_data = b;
    tx_start = 1;
    repeat (2) @(negedge dut.sys_clk);
    tx_start = 0;
    repeat (2) @(negedge dut.sys_clk);
    wait (tx_busy == 1'b0);
    @(negedge dut.sys_clk);
  endtask

  task automatic send_u32(input logic [31:0] v);
    for (int i = 0; i < 4; i++) send_byte(v[8*i +: 8]);
  endtask

  function automatic void dut_mem_write(logic [31:0] addr, logic [31:0] word);
    logic [19:0] w = addr[21:2];
    if (addr[22] == 1'b0) {base2.mem_array1[w], base2.mem_array0[w], base1.mem_array1[w], base1.mem_array0[w]} = word;
    else {ext2.mem_array1[w], ext2.mem_array0[w], ext1.mem_array1[w], ext1.mem_array0[w]} = word;
  endfunction
  function automatic logic [31:0] dut_mem_read(logic [31:0] addr);
    logic [19:0] w = addr[21:2];
    if (addr[22] == 1'b0) return {base2.mem_array1[w], base2.mem_array0[w], base1.mem_array1[w], base1.mem_array0[w]};
    return {ext2.mem_array1[w], ext2.mem_array0[w], ext1.mem_array1[w], ext1.mem_array0[w]};
  endfunction

  // 等至少 n 个字节，最多等 timeout 个 sys_clk
  task automatic wait_bytes(input int n, input int timeout, output bit ok);
    int c;
    c = 0;
    ok = 0;
    while (uart_rx.size() < n && c < timeout) begin
      @(posedge dut.sys_clk);
      c++;
    end
    ok = (uart_rx.size() >= n);
  endtask

  // 等新的字节停止到达 quiet 个周期（命令的完整应答）
  task automatic settle(input int quiet, input int maxc);
    int c, last;
    c = 0;
    last = uart_rx.size();
    while (c < maxc) begin
      @(posedge dut.sys_clk);
      c++;
      if (uart_rx.size() != last) begin
        last = uart_rx.size();
        c = 0;
      end
      if (c >= quiet) break;
    end
  endtask

  task automatic dump_rx(input string what);
    string t;
    t = "";
    foreach (uart_rx[i]) t = {t, $sformatf("%02h ", uart_rx[i])};
    $display("RX %s (%0d): %s", what, uart_rx.size(), t);
  endtask

  int errors = 0;
  task automatic fail(input string what);
    errors++;
    $display("FAIL: %s", what);
  endtask

  initial begin
    int fd, rc, i, n;
    logic [31:0] a, w;
    bit ok;
    string image, boot_s;
    if (!$value$plusargs("IMAGE=%s", image)) $fatal(1, "tb_monitor_soc: +IMAGE missing");

    reset_btn = 1;
    #200;
    // 装 kernel
    fd = $fopen(image, "r");
    if (fd == 0) $fatal(1, "cannot open %s", image);
    while (!$feof(fd)) begin
      rc = $fscanf(fd, "%h %h\n", a, w);
      if (rc == 2) dut_mem_write(a, w);
      else break;
    end
    $fclose(fd);
    // 小用户程序: t0=0x80400000; t1=0x5A; sw t1,0(t0); ret
    dut_mem_write(32'h8010_0000, 32'h8040_02b7);  // lui t0,0x80400
    dut_mem_write(32'h8010_0004, 32'h05a0_0313);  // addi t1,zero,0x5a
    dut_mem_write(32'h8010_0008, 32'h0062_a023);  // sw t1,0(t0)
    dut_mem_write(32'h8010_000c, 32'h0000_8067);  // ret
    // 用户栈顶（监控程序 G 之前会设置，这里给一块可写空间；kernel 自己会设 0x807f0000）
    reset_btn = 0;
    wait (dut.sys_rst == 1'b0);

    // boot message: 'MONITOR for RISC-V - initialized.'
    wait_bytes(33, 2_000_000, ok);
    settle(10_000, 500_000);
    dump_rx("boot");
    if (!ok) fail($sformatf("no boot message, got %0d bytes", uart_rx.size()));
    else begin
      boot_s = "";
      for (i = 0; i < 33; i++) boot_s = {boot_s, $sformatf("%c", uart_rx[i])};
      $display("boot: %s", boot_s);
      if (boot_s != "MONITOR for RISC-V - initialized.") fail($sformatf("boot message = %s", boot_s));
    end
    uart_rx.delete();

    // W -> XLEN = 4
    send_byte("W");
    wait_bytes(1, 2_000_000, ok);
    settle(10_000, 500_000);
    dump_rx("W");
    if (!ok || uart_rx[0] != 8'd4) fail($sformatf("W replied %02h (%0d bytes)", uart_rx.size() ? uart_rx[0] : 8'hxx,
                                                  uart_rx.size()));
    uart_rx.delete();

    // D 0x80000000 4 -> kernel 的第一个字
    send_byte("D"); send_u32(32'h8000_0000); send_u32(32'd4);
    wait_bytes(4, 2_000_000, ok);
    settle(10_000, 500_000);
    dump_rx("D1");
    if (!ok) fail($sformatf("D got %0d bytes", uart_rx.size()));
    else if ({uart_rx[3], uart_rx[2], uart_rx[1], uart_rx[0]} != 32'h0000_0d17)
      fail($sformatf("D 0x80000000 = %02h%02h%02h%02h", uart_rx[3], uart_rx[2], uart_rx[1], uart_rx[0]));
    uart_rx.delete();

    // G 0x80100000 -> 0x06 ... 0x07
    send_byte("G"); send_u32(32'h8010_0000);
    wait_bytes(2, 5_000_000, ok);
    settle(10_000, 500_000);
    dump_rx("G");
    if (!ok) fail($sformatf("G got %0d bytes", uart_rx.size()));
    else if (uart_rx[0] != 8'h06 || uart_rx[1] != 8'h07)
      fail($sformatf("G markers %02h %02h", uart_rx[0], uart_rx[1]));
    uart_rx.delete();

    // D 0x80400000 4 -> 0x0000005a
    send_byte("D"); send_u32(32'h8040_0000); send_u32(32'd4);
    wait_bytes(4, 2_000_000, ok);
    settle(10_000, 500_000);
    dump_rx("D2");
    if (!ok) fail($sformatf("D2 got %0d bytes", uart_rx.size()));
    else if ({uart_rx[3], uart_rx[2], uart_rx[1], uart_rx[0]} != 32'h0000_005a)
      fail($sformatf("D 0x80400000 = %02h%02h%02h%02h", uart_rx[3], uart_rx[2], uart_rx[1], uart_rx[0]));

    if (errors == 0) $display("tb_monitor_soc: PASS");
    else $display("tb_monitor_soc: FAIL (%0d errors)", errors);
    $finish;
  end

  initial begin
    #200ms;
    $fatal(1, "tb_monitor_soc: timeout");
  end
endmodule
