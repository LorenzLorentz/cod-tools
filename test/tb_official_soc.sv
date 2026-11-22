`timescale 1ns / 1ps

// 官方测例（testcases/basic/2.py、3.py）的本地直跑 testbench：
//   * 把 testcase 脚本里的内存镜像装进 4 片 sram_model；
//   * 在 0x80000000 放一段 trampoline，按监控程序 G 命令的方式设置
//         ra = RET（返回桩）、sp = fp = 0x807F0000、其余寄存器 = 0，
//     再用一串 JAL 跳到测例的 entry（JAL 不写寄存器，不破坏初始寄存器状态）；
//   * 跑到 PC == RET（测例用 `ret` 返回）为止，读结果表并和脚本给出的期望值逐字比较；
//   * 同时用 uart_model 收下程序的串口输出，和 p['out'] 比较。
//
// 只适用于脚本里只含 run/tab 步骤的测例（A01-A20、B04/B06/B09-B17）。
// 需要监控程序命令的测例（B01-B03/B05/B07/B08/B18-B20）不在这里跑。
//
// plusargs: +IMAGES=<addr word 每行一个字的镜像> +PROGS=<程序表> +MAX_CYCLES=<n>
// 程序表每项：entry res n tabs nout，接着 n 个期望字、nout 个期望串口字节。
module tb_official_soc;

  localparam logic [31:0] RET = 32'h8000_0298;  // 监控程序 G 的返回地址（B04 会检查）
  // JAL 跳转链，每级间隔 0xFF000 (< 1 MB)，覆盖 BaseRAM + ExtRAM
  localparam logic [31:0] T0 = 32'h8000_0000;
  localparam logic [31:0] T1 = 32'h800F_F000;
  localparam logic [31:0] T2 = 32'h801F_E000;
  localparam logic [31:0] T3 = 32'h802F_D000;
  localparam logic [31:0] T4 = 32'h803F_C000;
  localparam logic [31:0] T5 = 32'h804F_B000;
  localparam logic [31:0] T6 = 32'h805F_A000;
  localparam logic [31:0] T7 = 32'h806F_9000;
  localparam logic [31:0] T8 = 32'h807F_8000;

  localparam int MAX_EXP = 1024;
  localparam int MAX_OUT = 1024;
  localparam int MAX_REG = 64;

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
      .clk_50M       (clk_50M),
      .clk_11M0592   (1'b0),
      .push_btn      (1'b0),
      .reset_btn     (reset_btn),
      .touch_btn     (4'b0),
      .dip_sw        (32'b0),
      .leds          (),
      .dpy0          (),
      .dpy1          (),
      .uart_rdn      (),
      .uart_wrn      (),
      .uart_dataready(1'b0),
      .uart_tbre     (1'b0),
      .uart_tsre     (1'b0),
      .base_ram_data (base_ram_data),
      .base_ram_addr (base_ram_addr),
      .base_ram_be_n (base_ram_be_n),
      .base_ram_ce_n (base_ram_ce_n),
      .base_ram_oe_n (base_ram_oe_n),
      .base_ram_we_n (base_ram_we_n),
      .ext_ram_data  (ext_ram_data),
      .ext_ram_addr  (ext_ram_addr),
      .ext_ram_be_n  (ext_ram_be_n),
      .ext_ram_ce_n  (ext_ram_ce_n),
      .ext_ram_oe_n  (ext_ram_oe_n),
      .ext_ram_we_n  (ext_ram_we_n),
      .txd           (txd_pin),
      .rxd           (rxd_pin),
      .flash_a       (),
      .flash_d       (),
      .flash_rp_n    (),
      .flash_vpen    (),
      .flash_ce_n    (),
      .flash_oe_n    (),
      .flash_we_n    (),
      .flash_byte_n  (),
      .sl811_a0      (),
      .sl811_wr_n    (),
      .sl811_rd_n    (),
      .sl811_cs_n    (),
      .sl811_rst_n   (),
      .sl811_dack_n  (),
      .sl811_intrq   (1'b0),
      .sl811_drq_n   (1'b1),
      .dm9k_cmd      (),
      .dm9k_sd       (),
      .dm9k_iow_n    (),
      .dm9k_ior_n    (),
      .dm9k_cs_n     (),
      .dm9k_pwrst_n  (),
      .dm9k_int      (1'b0),
      .video_red     (),
      .video_green   (),
      .video_blue    (),
      .video_hsync   (),
      .video_vsync   (),
      .video_clk     (),
      .video_de      ()
  );

  sram_model base1 (.DataIO(base_ram_data[15:0]), .Address(base_ram_addr), .OE_n(base_ram_oe_n), .CE_n(base_ram_ce_n),
                    .WE_n(base_ram_we_n), .LB_n(base_ram_be_n[0]), .UB_n(base_ram_be_n[1]));
  sram_model base2 (.DataIO(base_ram_data[31:16]), .Address(base_ram_addr), .OE_n(base_ram_oe_n), .CE_n(base_ram_ce_n),
                    .WE_n(base_ram_we_n), .LB_n(base_ram_be_n[2]), .UB_n(base_ram_be_n[3]));
  sram_model ext1 (.DataIO(ext_ram_data[15:0]), .Address(ext_ram_addr), .OE_n(ext_ram_oe_n), .CE_n(ext_ram_ce_n),
                   .WE_n(ext_ram_we_n), .LB_n(ext_ram_be_n[0]), .UB_n(ext_ram_be_n[1]));
  sram_model ext2 (.DataIO(ext_ram_data[31:16]), .Address(ext_ram_addr), .OE_n(ext_ram_oe_n), .CE_n(ext_ram_ce_n),
                   .WE_n(ext_ram_we_n), .LB_n(ext_ram_be_n[2]), .UB_n(ext_ram_be_n[3]));

  // 直连串口模型：收程序输出，并把它的 txd 当 CPU 的 rxd（空闲为 1）
  uart_model uart (.rxd(txd_pin), .txd(rxd_pin));
  reg [7:0] uart_rx[$];
  always @(posedge uart.rxd_data_ready) uart_rx.push_back(uart.rxd_data);

  // ---------------------------------------------------------------- 存储器访问
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

  // ---------------------------------------------------------------- 指令编码
  function automatic logic [31:0] enc_lui(input logic [4:0] rd, input logic [19:0] imm);
    return {imm, rd, 7'b0110111};
  endfunction
  function automatic logic [31:0] enc_addi(input logic [4:0] rd, input logic [4:0] rs1, input logic [11:0] imm);
    return {imm, rs1, 3'b000, rd, 7'b0010011};
  endfunction
  function automatic logic [31:0] enc_jal(input logic [4:0] rd, input logic [31:0] off);
    return {off[20], off[10:1], off[11], off[19:12], rd, 7'b1101111};
  endfunction

  // 按监控程序 G 命令的初始状态设置 ra/sp/fp，再用 JAL 链跳到 entry
  task automatic install_tramp(input logic [31:0] entry);
    logic [31:0] lvl[0:8];
    logic [31:0] lo, hi;
    int li;
    lvl[0] = T0; lvl[1] = T1; lvl[2] = T2; lvl[3] = T3; lvl[4] = T4;
    lvl[5] = T5; lvl[6] = T6; lvl[7] = T7; lvl[8] = T8;
    // 按监控程序 G 命令的初始状态：sp/fp = USER_STACK_INIT，ra = .USERRET2，s10 = 程序入口
    dut_mem_write(T0 + 0, enc_lui(5'd2, 20'h807F0));  // sp = 0x807F0000
    dut_mem_write(T0 + 4, enc_lui(5'd8, 20'h807F0));  // fp = 0x807F0000
    dut_mem_write(T0 + 8, enc_lui(5'd1, RET[31:12]));  // ra = RET
    dut_mem_write(T0 + 12, enc_addi(5'd1, 5'd1, 12'(RET[11:0])));
    lo = {{20{entry[11]}}, entry[11:0]};
    hi = entry - lo;
    dut_mem_write(T0 + 16, enc_lui(5'd26, hi[31:12]));  // s10 = entry
    dut_mem_write(T0 + 20, enc_addi(5'd26, 5'd26, lo[11:0]));
    li = 0;
    while (li < 8 && entry >= lvl[li+1]) li++;
    for (int j = 0; j < li; j++) begin
      logic [31:0] at = (j == 0) ? (T0 + 24) : lvl[j];
      dut_mem_write(at, enc_jal(5'd0, lvl[j+1] - at));
    end
    dut_mem_write((li == 0) ? (T0 + 24) : lvl[li], enc_jal(5'd0, entry - ((li == 0) ? (T0 + 24) : lvl[li])));
    dut_mem_write(RET, enc_jal(5'd0, 32'd0));  // 返回桩：jal x0, 0
  endtask

  logic dbg_on = 0;
  initial dbg_on = $test$plusargs("DBG");
  int dbg_sw = 0;
  always @(posedge dut.sys_clk)
    if (dbg_on && prog_id == 0 && dut.cpu_mem_req && dut.cpu_mem_we && dut.cpu_mem_addr >= 32'h8040_0000) begin
      if (dbg_sw < 5000) $display("DBG SW addr=%08h sel=%b data=%08h", dut.cpu_mem_addr, dut.cpu_mem_sel, dut.cpu_mem_wdata);
      dbg_sw++;
      if (dbg_sw == 20) $display("DBG SW ... (more)");
    end

  always @(negedge ext_ram_we_n)
    if (dbg_on && prog_id == 0) $display("DBG EXTWE addr=%05h data=%08h be=%b", ext_ram_addr, ext_ram_data, ext_ram_be_n);

  // ---------------------------------------------------------------- 主流程
  logic [31:0] img[logic [31:0]];  // 地址 >> 2
  string images_path, progs_path;
  int max_cycles = 5_000_000;
  int n_pass = 0, n_fail = 0, prog_id = 0;

  initial begin
    int ifd, pfd, rc, i, n, tabs, nout, nreg, tmo, cycles, run_cycles, nbad;
    logic [31:0] entry, res, ta, got, rv;
    logic [31:0] exp[0:MAX_EXP-1];
    logic [7:0] out_b[0:MAX_OUT-1];
    int rgi[0:MAX_REG-1];
    logic [31:0] rgv[0:MAX_REG-1];

    if (!$value$plusargs("IMAGES=%s", images_path)) $fatal(1, "tb_official_soc: +IMAGES missing");
    if (!$value$plusargs("PROGS=%s", progs_path)) $fatal(1, "tb_official_soc: +PROGS missing");
    void'($value$plusargs("MAX_CYCLES=%d", max_cycles));

    ifd = $fopen(images_path, "r");
    if (ifd == 0) $fatal(1, "tb_official_soc: cannot open %s", images_path);
    while (!$feof(ifd)) begin
      logic [31:0] a, w;
      rc = $fscanf(ifd, "%h %h\n", a, w);
      if (rc == 2) img[a>>2] = w;
      else break;
    end
    $fclose(ifd);

    pfd = $fopen(progs_path, "r");
    if (pfd == 0) $fatal(1, "tb_official_soc: cannot open %s", progs_path);
    while (!$feof(pfd)) begin
      rc = $fscanf(pfd, "%h %h %d %d %d %d %d\n", entry, res, n, tabs, nout, nreg, tmo);
      if (rc != 7) break;
      for (i = 0; i < n; i++) rc = $fscanf(pfd, "%h", exp[i]);
      for (i = 0; i < nout; i++) rc = $fscanf(pfd, "%h", out_b[i]);
      for (i = 0; i < nreg; i++) rc = $fscanf(pfd, "%d %h", rgi[i], rgv[i]);

      // 复位并装入镜像
      reset_btn = 1;
      repeat (4) @(posedge clk_50M);
      uart_rx.delete();
      foreach (img[a]) dut_mem_write(a << 2, img[a]);
      install_tramp(entry);
      if ($test$plusargs("DBG") && prog_id == 0) begin
        $display("DBG T0=%08h T0+16=%08h T1=%08h T1w=%08h entry=%08h entry_w=%08h RET_w=%08h",
                 dut_mem_read(T0), dut_mem_read(T0 + 24), T1, dut_mem_read(T1), entry, dut_mem_read(entry),
                 dut_mem_read(RET));
      end
      reset_btn = 0;
      wait (dut.sys_rst == 1'b0);

      // 跑到返回桩
      cycles = 0;
      if ($test$plusargs("DBG") && prog_id == 0) begin
        int dbg_n = 0;
        logic [31:0] last_pc = 32'hffff_ffff;
        while (dut.u_cpu.pc != RET && cycles < max_cycles) begin
          @(posedge dut.sys_clk);
          cycles++;
          if (dut.u_cpu.pc != last_pc && dbg_n < 200) begin
            $display("DBG pc=%08h inst=%08h", dut.u_cpu.pc, dut.cpu_inst_data);
            last_pc = dut.u_cpu.pc;
            dbg_n++;
          end
        end
      end else begin
        while (dut.u_cpu.pc != RET && cycles < max_cycles) begin
          @(posedge dut.sys_clk);
          cycles++;
        end
      end
      run_cycles = cycles;
      if (dut.u_cpu.pc != RET) begin
        $display("PROG %0d entry=%08h FAIL timeout after %0d cycles (pc=%08h)", prog_id, entry, cycles, dut.u_cpu.pc);
        n_fail++;
      end else begin
        repeat (200) @(posedge dut.sys_clk);
        cycles = 0;
        while (uart_rx.size() < nout && cycles < (30_000 + nout * 1_500)) begin
          @(posedge dut.sys_clk);
          cycles++;
        end
        repeat (5_000) @(posedge dut.sys_clk);  // 再等 500 us 的静默

        nbad = 0;
        if (tmo > 0 && run_cycles > tmo * 10_000) begin  // 10 MHz: 1 ms = 10000 周期
          $display("PROG %0d entry=%08h FAIL performance: %0d cycles > %0d ms", prog_id, entry, run_cycles, tmo);
          nbad++;
        end
        if (uart_rx.size() != nout) begin
          $display("PROG %0d entry=%08h FAIL serial: got %0d bytes, expected %0d", prog_id, entry, uart_rx.size(), nout);
          nbad++;
        end else begin
          for (i = 0; i < nout; i++)
            if (uart_rx[i] != out_b[i]) begin
              if (nbad == 0)
                $display("PROG %0d entry=%08h FAIL serial byte %0d = %02h, expected %02h", prog_id, entry, i,
                         uart_rx[i], out_b[i]);
              nbad++;
            end
        end
        for (int t = 0; t < tabs; t++) begin
          for (i = 0; i < n; i++) begin
            ta = res + 4 * (t * n + i);
            got = dut_mem_read(ta);
            if (dbg_on && prog_id == 0 && t == 0 && i == 4)
              $display("DBG cmp res=%08h ta=%08h got=%08h exp=%08h", res, ta, got, exp[i]);
            if (got != exp[i]) begin
              if (nbad == 0)
                $display("PROG %0d entry=%08h FAIL table %0d result %0d at %08h: got %08h, expected %08h",
                         prog_id, entry, t, i, res + 4 * (t * n + i), got, exp[i]);
              nbad++;
            end
          end
        end
        for (i = 0; i < nreg; i++) begin
          rv = dut.u_cpu.u_reg_file.rf[rgi[i]];
          if (rv != rgv[i]) begin
            if (nbad == 0)
              $display("PROG %0d entry=%08h FAIL x%0d = %08h, expected %08h", prog_id, entry, rgi[i], rv, rgv[i]);
            nbad++;
          end
        end
        if (nbad == 0) begin
          $display("PROG %0d entry=%08h PASS (%0d results x %0d, %0d serial bytes, %0d regs, %0d cycles)", prog_id,
                   entry, n, tabs, nout, nreg, run_cycles);
          n_pass++;
        end else begin
          n_fail++;
        end
      end
      prog_id++;
    end
    $fclose(pfd);
    $display("TOTAL: %0d passed, %0d failed", n_pass, n_fail);
    $finish;
  end

endmodule
