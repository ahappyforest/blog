---
title: "OpenCore UART16550 Porting from Wishbone to AXI"
date: 2018-03-04T11:33:09+08:00
draft: false
---

# 1 背景

UART16550是串口通信电路的具体IP实现，最早的版本是在1987年由National Semiconductor发布的，后来经过历史的演变, 被广泛使用, 本文所研究的UART16550 IP是由Opencores发布的开源实现, 该代码可以在[Opencores](https://opencores.org/project,uart16550)官网上下载得到.

![](https://camo.githubusercontent.com/a36f63d393976fe07c8046dfab1f57c82c87b3e3/68747470733a2f2f7472656c6c6f2d6174746163686d656e74732e73332e616d617a6f6e6177732e636f6d2f3535646433343163633936373733333135366637343835342f3561356132356532653364656461333033383739363830612f36643739363132613961626337316666353833636432323663343337633964632f7561727431363535305f6f70656e636f7265732e706e67)

本研究的目的是综合之前所学, 研究如何将工业界成熟的UART16550 wishbone IP移植到AXI总线上, 并打包成IP供vivado的block design调用.

本项目训练的目的主要包括:

- 阅读以及修改verilog代码的能力
- testbench编写
- vcs + dve仿真
- vivado
  - 如何创建自定义AXI IP
  - 如何导入可综合verilog项目（非block design)
  - 如何设置管脚约束XDC
  - 学习FPGA综合(synthesis)，实现(implementation)，生成比特流(bit stream)文件，下载(programming)流程
  - SDK使用

在移植UART16550 IP之前, 我们先来熟悉一下UART通信协议。

# 2 UART通信协议

下图引用自: KeyStone Architecture Universal Asynchronous Receiver/Transmitter (UART) User Guide, 讲述的是UART通信协议中系统时钟, BCLK与UART通信协议之间的关系:

![uart protocol](https://camo.githubusercontent.com/abfad7bc8afa2a9aa01e94194bee08d6bc3b2252/68747470733a2f2f7472656c6c6f2d6174746163686d656e74732e73332e616d617a6f6e6177732e636f6d2f3535646433343163633936373733333135366637343835342f3561356132356532653364656461333033383739363830612f34343534333131633432616163393232643439386438646532656635383637662f756172745f70726f746f636f6c2e706e67)

图中，divisor是分频系数, 假设系统时钟定义为SYS_CLK, 图中的变量n是由公式`n = SYS_CLK / divisor`得出, 也就是说n个SYS_CLK周期有一个BCLK. UART协议中一个比特持续的时间称之为波特率(BAUDRATE), 波特率(BAUDRATE)和BCLK之间的关系是: `BAUDRATE = BCLK / 16`, 对于接收来说, UART电平的采样时间发生在每一个比特持续的16个BCLK的第8个BCLK位置.（注: 要想让UART接收带抗干扰能力, 有时不一定在第8个BCLK位置采样, 比如可以多采样几次然后比较出现次数多的那个电平作为最后的逻辑值, 方法并不唯一)

除了上面的解释，另外还有几点需要补充:

-  UART模块内部的时钟和波特率的公式: `divisor = (SYS_CLK) / (16 * 波特率)`, 波特率的单位是HZ, 比如对于100MHz的系统时钟，如果我们想产生115200Hz的波特率, 带入公式：`(10000000 / (16 * 115200)`得到divisor的近似值为54.
-  UART一帧由起始位、数据位、校验位和停止位组成，数据逐位传输. 
  - UART空闲时（没有数据传输），总线为高电平（逻辑1），当需要数据传输时，首先发送一个“起始位”，起始位为一个低电平“逻辑0”。
  - 紧挨着“起始位”的是数据位，它可以是４、5、6、7或8位，收/发双方在数据开始传输前，需要对双方数据位位数作一致的定义, 数据位的发送采用低位（LSB）先发送，比如发送数据位: 01010000表示0xa.(0xa二进制表示为00001010).
  - UART的校验位紧挨着数据位，采用奇/偶位校验方式, 也可以不包括校验位
  - UART的帧以停止位作为停止标志，停止为可以为1位、1.5位和2位。
  - 当发送完停止位之后，UART总线进入空闲, 空闲时总线再次为高电平（逻辑1）

# 3. 状态机

UART收/发行为可以由状态机进行描述, 下面分别介绍.

## 3.1 发送状态机

![](https://camo.githubusercontent.com/822078c433e6415de96d10bc5ba9ddd74171babc/68747470733a2f2f7472656c6c6f2d6174746163686d656e74732e73332e616d617a6f6e6177732e636f6d2f3535646433343163633936373733333135366637343835342f3561356132356532653364656461333033383739363830612f64386366356334396563313339393236393838623537346634616332666566642f66736d5f74782e706e67)

- `idle`状态, 发送空闲状态, 此时发送队列为空
- `pop byte`状态, 当检查到发送队列不为空的时候, 从队列取出一个字节, 在此状态下还要根据配置知道当前要发送的数据位是几位有效，并将该值赋给bit_counter，并计算出取出的这个字节有效位的校验值(parity), 为`send start`状态做准备
- `send start`状态, 此状态下按照低位优先(LSB first), 将数据一个bit一个bit发送出去, 每次将bit_counter减1, 直到bit_counter为0, 并根据是否发送校验值(parity)的设置决定接下来是进入`send parity`还是进入`send stop`状态.
- `send parity`状态, 此状态下根据设置决定发送奇校验还是偶校验，并进入发送`send stop`状态
- `send stop`状态, 此状态根据设置决定是发送1还是1.5或者2位的停止位, 发送完成后进入`idle`空闲状态.

## 3.2 接收状态机

![](https://camo.githubusercontent.com/17db1519234f38c13d4d5bc7cf58d83462b17b67/68747470733a2f2f7472656c6c6f2d6174746163686d656e74732e73332e616d617a6f6e6177732e636f6d2f3535646433343163633936373733333135366637343835342f3561356132356532653364656461333033383739363830612f38613632393563303837613031306666343638383765636433623033356532612f66736d5f72782e706e67)

接收状态机看似相比发送状态机复杂，其实并没有，只不过接收状态机需要根据同步时序逻辑的实现，利用一个bit会持续BCLK为16个周期这个特点, 在不同的周期里面进行接收、计算和检查校验值的步骤.

- `idle`状态, 接收空闲状态, 此时srx_pad_i信号线上的电平是空闲状态(逻辑1), 一旦检测到srx_pad_i信号线拉低(逻辑0)，就从空闲状态进入`rec start`状态
- `rec start`状态, 在`rec start`状态如果再次检测到srx_pad_i信号线还是拉低, 开始进入`rec repare`状态
- `rec prepare`, 进入`rec prepare`状态后，需要根据设置确定对端发送过来的数据位数是几位, 并赋值给rbit_counter寄存器.
- `rec bit`状态, 在该状态下接收一个bit并将rbit_counter减1, 如果rbit_counter减为0, 进入`end bit`状态
- `end bit`状态， 在该状态下根据是否设置了奇偶校验决定进入`rec parity`状态还是`rec stop`状态.
- `rec parity`状态, 在该状态下接收校验位, 进入`calc parity`状态
- `calc parity`状态, 计算校验和并进入`check parity`状态.
- `check parity`状态, 检查校验和是否正确并进入wait状态
- `wait`状态, 由于`rec parity`, `calc parity`以及`check parity`都是在一个接收窗口中完成的, 而每一个bit的持续时间是16个BCLK, 因此这里需要等待这一轮的BCLK走完进入下一轮.完成之后进入`rec stop`状态
- `rec stop`状态, 接收停止位, 并进入`push`状态
- `push`状态, 将之前收到的数据存入接收队列中并进入`idle`状态.

这里强调一下wait状态的意义, 从电路实现的角度来说, 由于是同步时序逻辑电路, 因此只能是根据BCLK时钟不断的循环状态机, 每16个BCLK表示一轮周期, 而从接收校验和, 计算校验和以及检查校验和都必须等待寄存器的值准备好，因此我们这里有一个技巧是16个BCLK里面当BCLK计数器走到7的时候采集校验和, 走到8的时候计算校验和, 走到9的时候检查校验和是否正确, 这就是为啥需要wait状态的原因, 我们需要在走到9之后, 等待下一轮16个BCLK周期进入`rec stop`状态.

# 4 模块图

介绍完通信协议，我们接下来开始正式移植.

由于Opencores的UART16550是带wishbone接口的, 第一步首先剥离wishbone接口, 得到一个纯粹的UART顶层模块.

剥离出的UART顶层接口模块如下:

![](https://camo.githubusercontent.com/7269b1bfd5d91b783a8974b3b07cd76abc477a3f/68747470733a2f2f7472656c6c6f2d6174746163686d656e74732e73332e616d617a6f6e6177732e636f6d2f3535646433343163633936373733333135366637343835342f3561356132356532653364656461333033383739363830612f36326335316261646439613531303934636531353131353936663637383266642f756172745f746f702e706e67)

图中, 左边的信号线都是输入信号(input), 右边的信号都是输出信号(output), 每一个信号线的功能说明如下:

- `clk` 时钟
- `wb_rst_i`复位
- `enable` 由时钟信号分频而来, 它和clk之间的关系为:`n = clk / divisor`, 也就是每n个clk一个enable信号, 也就是上文所说的BCLK.
- `lcr[7:0]` Line Control Register, 用来配置UART通信协议, 具体的位定义如下:

![](https://camo.githubusercontent.com/55c41bbf3ec2553ecf89de5e8eb59b566bd7dc38/68747470733a2f2f7472656c6c6f2d6174746163686d656e74732e73332e616d617a6f6e6177732e636f6d2f3535646433343163633936373733333135366637343835342f3561356132356532653364656461333033383739363830612f65373466623338303664646237643235613636343139643438386638643333662f72656769737465725f6c63722e706e67)

- `lsr mask` 是否要屏蔽rf_overrun信号, 如果lsr_mask == 1, 那么rf_overrun将一直为0
- `wb_dat_i[7:0]` 数据输入, 在`clk`的上升沿同时`tf_push`信号为1的时候, 那么`wb_dat_i[7:0]`数据将会被送入发送队列中.
- `tf_push` 向发送队列中压入数据的使能信号
- `tx_reset` 复位发送队列
- `rf_pop`  向接收队列中取出数据的使能信号
- `rx_reset` 复位接收队列
- `srx_pad_i` 串口接收信号线
- `tstate[2:0]` 指示串口发送状态机的状态值
- `tf_count[4:0]` 发送队列中当前存放的字符个数
- `stx_pad_o` 串口发送信号线
- `counter_t[9:0]` 超时计数器, 当接收队列至少有一个字符的时候, 此时在一定的时间内并没有新的字符发送给接收队列, 或者没有在一定时间内将这个字符从接收队列读出, 超时计数器将不断减1直到到达0指示为超时(这个功能主要是给中断使用)
- `rf_overrun` 接收队列溢出
- `rf_count[4:0]` 接收队列中当前存放的字符个数
- `rf_data_out[10:0]` `rf_data_out[10:3]`为当`rf_pop`使能的时候从接收队列中弹出的字符(8位), `rf_data_out[2]`表示break error, `rf_data_out[1]`表示校验错误, `rf_data_out[0]`表示停止位检测到0, 表示帧错误.
- `rf_error_bit` 指示接收到的数据有错误, 错误可能是break error, 校验错误或者是帧错误. 其中break error表示如果发现接收信号线上超过一定时间一直是逻辑0就会是这个错误.(根据通信协议空闲时应该一直是逻辑1才对).而帧错误是接收状态机发现停止位为0时产生的错误.
- `rstate[3:0]` 指示串口接收状态机的状态值
- `rf_push_pulse` 用来指示串口接收到一个字符push到接收队列时产生的一个pulse信号.

# 5 仿真1: UART顶层模块仿真

首先我们构造第一个testbench, 测试一下我们刚刚剥离的UART顶层模块.

![](https://camo.githubusercontent.com/56e3d53a1dee6133fad7408406743a4a0e80ad91/68747470733a2f2f7472656c6c6f2d6174746163686d656e74732e73332e616d617a6f6e6177732e636f6d2f3535646433343163633936373733333135366637343835342f3561356132356532653364656461333033383739363830612f65333666643762623238393530646566363231346664346662343332643561362f756172745f746f705f74622e706e67)

该testbench首先需要生成clk以及enable信号用来驱动UART收发状态机不断工作，然后在initial中编写uart_tx向UART模块中发送字符,具体的代码如下:

```
`timescale 1ns/1ps

`include "uart_defines.v"

`define T_PERIOD      50
`define T_HALF_PERIOD 25

module tb;
  reg  clk;
  reg  wb_rst_i;
  reg [7:0] lcr;
  reg [7:0] wb_dat_i;
  reg lsr_mask;
  reg  enable;

  reg [15:0] dl;  // divisor latch
  reg [15:0] dlc; // divisor latch counter

  // uart transmitter
  reg  tf_push;
  reg tx_reset;
  wire stx_pad_o;
  wire [2:0] tstate;
  wire [`UART_FIFO_COUNTER_W-1:0] tf_count;

  // uart receiver
  reg rf_pop;
  reg rx_reset;
  wire [9:0] counter_t; // counts the timeout condition clocks
  wire rf_overrun;
  wire [`UART_FIFO_COUNTER_W-1:0] rf_count;
  wire [`UART_FIFO_REC_WIDTH-1:0] rf_data_out;
  wire rf_error_bit; // an error (parity or framing) is inside the fifo
  wire [3:0] rstate;
  wire rf_push_pulse;

  uart_top uart_i(
    .clk(clk),
    .wb_rst_i(wb_rst_i),
    .enable(enable),
    .lcr(lcr),
    .lsr_mask(lsr_mask),
    .wb_dat_i(wb_dat_i),
    .tf_push(tf_push),
    .tx_reset(tx_reset),
    .tstate(tstate),
    .tf_count(tf_count),
    .stx_pad_o(stx_pad_o),
    .rf_pop(rf_pop),
    .rx_reset(rx_reset),
    .srx_pad_i(stx_pad_o),
    .counter_t(counter_t), // counts the timeout condition clocks
    .rf_overrun(rf_overrun),
    .rf_count(rf_count),
    .rf_data_out(rf_data_out),
    .rf_error_bit(rf_error_bit), // an error (parity or framing) is inside the fifo
    .rstate(rstate),
    .rf_push_pulse(rf_push_pulse)
  );

  // generate clk signal: 50ns -> 20MHz
  always #`T_HALF_PERIOD clk = ~clk;

  // generate enable signal
  // system clock speed) / (16 x desired baud rate)
  always @(posedge clk or posedge wb_rst_i) begin
    if (wb_rst_i) begin
      dlc <= 'd0;
    end
    else
      if (~(|dlc))
        dlc <= dl - 'd1;
      else
        dlc <= dlc - 'd1;
  end

  always @(posedge clk or posedge wb_rst_i) begin
    if (wb_rst_i)
      enable <= 1'b0;
    else
      if (~(|dlc))
        enable <= 1'b1;
      else
        enable <= 1'b0;
  end

  initial begin
    clk = 1'b0;
    wb_rst_i = 1'b1;
    lcr = 8'b00000011; // 8N1
    tf_push = 1'b0;
    wb_dat_i = 'd0;
    enable = 1'b0;
    tx_reset = 1'b0;
    lsr_mask = 1'b0;

    rx_reset = 1'b0;
    rf_pop = 1'b1;

    dl = 'd10;
    dlc = 'd0;

    // generate reset
    #`T_HALF_PERIOD
    wb_rst_i = 0;

    @(negedge clk);
    tf_push = 1'b1;
    wb_dat_i = 'hA;

    @(negedge clk);
    tf_push = 1'b1;
    wb_dat_i = 'hB;

    @(negedge clk);
    tf_push = 1'b1;
    wb_dat_i = 'hC;

    @(negedge clk);
    wb_dat_i = 'h0;
    tf_push = 1'b0;

    #(`T_HALF_PERIOD * 1000 * 16) $finish;
  end

endmodule
```

该testbench仿真关键时序截图如下:

![](https://camo.githubusercontent.com/986bad7f5258217f32c3f8cb31c0ffb40058be1b/68747470733a2f2f7472656c6c6f2d6174746163686d656e74732e73332e616d617a6f6e6177732e636f6d2f3535646433343163633936373733333135366637343835342f3561356132356532653364656461333033383739363830612f33663835663836646466303037613562306161323937303465326161306334312f74312e706e67)

首先，复位以后，将tf_push拉高, 再每一个clk的上升沿依次发送0xa, 0xb, 0xc三个字符, 发送完成以后将tf_push拉低.

![](https://camo.githubusercontent.com/e3e64ab1c11a5c32f53fd9537e3a3b8a4c03b19f/68747470733a2f2f7472656c6c6f2d6174746163686d656e74732e73332e616d617a6f6e6177732e636f6d2f3535646433343163633936373733333135366637343835342f3561356132356532653364656461333033383739363830612f66653066373762623639313961656464346233323239643334373631323739662f74325f305f302e706e67)

在stx_pad_o已经看到了发送的0xa (0xb, 0xc的分析省略), 同时在接收端的rshift内部寄存器上我们发现接受状态机不断的以为最终得到正确的发送数据0xa.

# 6 仿真2: soc模块仿真

仿真完UART 顶层模块之后, 我们来做一个有趣的模块: soc.v

该模块利用我们之前剥离的UART顶层模块, 不断查询uart_rx端的rfifo，一旦有数据(tf_count > 0), 读出该数据(rf_pop <= 1'b1, 数据从rf_data_out[10:3]出来)，然后设置tf_push <= 1'b1, 并且将wb_dat_i <= rf_data_out[10:3] + 1'b1.

```
always @(*) begin
   if (rf_count) begin
     wb_dat_i <= rf_data_out[10:3] + 1'd1;
     rf_pop <= 1'b1;
     tf_push <= 1'b1;
   end
   else begin
     wb_dat_i <= 1'd0;
     rf_pop <= 1'b0;
     tf_push <= 1'b0;
   end
end
```

也就是说我们做一个串口处理模块, 我们向该模块的srx_pad_i端发送字符'a', 经过该模块处理后, 会在stx_pad_i端回来一个字符'b'.

新封装出来的soc内部将大部分信号线屏蔽了, 只连出来时钟、复位以及串口的收发信号, 为了表明模块本身正在工作, 又引出了三个led信号, 电路正常工作后, 在100MHz系统时钟下, led0会每隔1s闪烁一次, led1表示串口正在发送数据, led2表示串口正在接收数据.

模块示意图如下:

![](https://camo.githubusercontent.com/bd50a6117ca6776a1c69676a9fe69007fd525f49/68747470733a2f2f7472656c6c6f2d6174746163686d656e74732e73332e616d617a6f6e6177732e636f6d2f3535646433343163633936373733333135366637343835342f3561356132356532653364656461333033383739363830612f31363937646137346137383038613930396334343233373532663537303033622f736f635f626c6f636b5f6469616772616d2e706e67)

具体的soc.v源码如下:

```
`include "uart_defines.v"

module soc (
  input clk, // external clk
  output led0,
  output led1,
  output led2,
  input reset,
  input uart_rx,
  output uart_tx
);
  /* 主要有以下几件事情需要完成:
    1. 时钟是多少, 分频系数设置成多少? 100Mhz / (16 * 115200) = 54
    2. 上电之后如何进入初始状态? pll locked signal provide reset signal and trigger all register reset to default value.
    3. 初始化之后不断查询uart_rx端的rfifo,
       一旦有数据(tf_count > 0), 读出该数据(rf_pop <= 1'b1, 数据从rf_data_out[10:3]出来),
       然后设置tf_push <= 1'b1, 并且将wb_dat_i <= rf_data_out[10:3]
       (可以再对数据进行某些加工)
    4. 提供一些indicator信息（利用LED）显示电路正在工作.
   */

  reg [7:0] lcr;
  reg [7:0] wb_dat_i;
  reg lsr_mask;
  reg  enable;
  wire clk2;

  assign clk2 = ~clk;

  reg [15:0] dl;  // divisor latch
  reg [15:0] dlc; // divisor latch counter
  
  reg led0_r;
  reg led1_r;
  reg led2_r;
  reg uart_tx_r;
  
  assign led0 = led0_r;

  // uart transmitter
  reg  tf_push;
  reg tx_reset;
  wire [2:0] tstate;
  wire [`UART_FIFO_COUNTER_W-1:0] tf_count;

  // uart receiver
  reg rf_pop;
  reg rx_reset;
  wire [9:0] counter_t; // counts the timeout condition clocks
  wire rf_overrun;
  wire [`UART_FIFO_COUNTER_W-1:0] rf_count;
  wire [`UART_FIFO_REC_WIDTH-1:0] rf_data_out;
  wire rf_error_bit; // an error (parity or framing) is inside the fifo
  wire [3:0] rstate;
  wire rf_push_pulse;

  uart_top uart_i(
    .clk(clk),
    .wb_rst_i(reset),
    .enable(enable),
    .lcr(lcr),
    .lsr_mask(lsr_mask),
    .wb_dat_i(wb_dat_i),
    .tf_push(tf_push),
    .tx_reset(tx_reset),
    .tstate(tstate),
    .tf_count(tf_count),
    .stx_pad_o(uart_tx),
    .rf_pop(rf_pop),
    .rx_reset(rx_reset),
    .srx_pad_i(uart_rx),
    .counter_t(counter_t), // counts the timeout condition clocks
    .rf_overrun(rf_overrun),
    .rf_count(rf_count),
    .rf_data_out(rf_data_out),
    .rf_error_bit(rf_error_bit), // an error (parity or framing) is inside the fifo
    .rstate(rstate),
    .rf_push_pulse(rf_push_pulse)
  );

  // generate enable signal
  // system clock speed) / (16 x desired baud rate)
  always @(posedge clk or posedge reset) begin
    if (reset) begin
      dlc <= 'd0;
    end
    else
      if (~(|dlc))
        dlc <= dl - 'd1;
      else
        dlc <= dlc - 'd1;
  end

  always @(posedge clk or posedge reset) begin
    if (reset)
      enable <= 1'b0;
    else
      if (~(|dlc))
        enable <= 1'b1;
      else
        enable <= 1'b0;
  end

  //reg [31:0] delay_counter;
  //always @(posedge clk2 or posedge reset) begin
  //  if (reset) begin
  //      tf_push <= 1'b0;
  //      rf_pop <= 1'b0;
  //      wb_dat_i <= 'd0;
  //      //delay_counter <= 'd0;
  //  end else begin          
  //      if (tf_push)
  //          tf_push <= 1'b0; // restore the signal to 0 after one clock cycle
  //          
  //      if (rf_pop)
  //          rf_pop <= 1'b0; // restore the signal to 0 after one clock cycle
  //      
  //      if (rf_count) begin
  //          //delay_counter <= delay_counter + 1'b1;
  //          //if (delay_counter == 'd1) begin
  //              wb_dat_i <= rf_data_out[10:3] + 1'd1;
  //              rf_pop <= 1'b1;
  //              tf_push <= 1'b1;
  //           //   delay_counter <= 'd0;
  //          //end
  //      end
  //  end
  //end

  always @(*) begin
    if (rf_count) begin
      wb_dat_i <= rf_data_out[10:3] + 1'd1;
      rf_pop <= 1'b1;
      tf_push <= 1'b1;
    end
    else begin
      wb_dat_i <= 1'd0;
      rf_pop <= 1'b0;
      tf_push <= 1'b0;
    end
  end
  
  always @(posedge clk or posedge reset) begin
    if (reset) begin
        lcr <= 8'b00000011; // 8N1
        tx_reset <= 1'b0;
        lsr_mask <= 1'b0;
        rx_reset <= 1'b0;
        dl <= 'd54; // 100MHz / (16 * 115200) = 54
    end else begin
        lcr <= lcr; // 8N1      
        tx_reset <= tx_reset;
        lsr_mask <= lsr_mask;
        rx_reset <= rx_reset;
        dl <= dl;
    end
  end
  
  reg [31:0] counter_r = 32'b0;
  always @(posedge clk or posedge reset) begin
    if (reset) begin
        led0_r <= 1'b0;
        counter_r <= 'd0;
    end else begin
        counter_r <= counter_r + 1'b1;
        if (counter_r == 'd100_000000-1) begin
            counter_r <= 'd0;
            led0_r <= ~led0_r;
        end else 
            led0_r <= led0_r;
    end
  end
  
  reg [31:0] delay_counter2;
  reg [31:0] delay_counter3;
  assign led1 = led1_r;
  assign led2 = led2_r;
  always @(posedge clk or posedge reset) begin
    if (reset) begin
        delay_counter2 <= 'd0;
        delay_counter3 <= 'd0;
        led1_r <= 1'b0;
        led2_r <= 1'b0;
    end else begin
        if (tf_push) begin
            led1_r <= 1'b1;
            delay_counter2 <= 'd0;
        end
        if (rf_pop) begin
            led2_r <= 1'b1;
            delay_counter3 <= 'd0;
        end
        if (led1_r)
            delay_counter2 <= delay_counter2 + 1'b1;
            
        if (led2_r)
            delay_counter3 <= delay_counter3 + 1'b1;
            
        if (delay_counter2 == 'd10_000000) begin
            led1_r <= 1'b0;    
            delay_counter2 <= 'd0;
        end
        if (delay_counter3 == 'd10_000000) begin
            led2_r <= 1'b0;
            delay_counter3 <= 'd0;
        end
     end
  end

endmodule
```

对应的tb_soc.v testbench源文件如下:

```
`timescale 1ns/1ps

`include "uart_defines.v"

`define T_PERIOD      50
`define T_HALF_PERIOD 25

module tb_soc;
  reg clk;
  reg bclk;
  wire led0;
  wire led1;
  wire led2;
  reg reset;
  reg uart_rx;
  wire uart_tx;

  soc soc_i(
    .clk(clk),
    .led0(led0),
    .led1(led1),
    .led2(led2),
    .reset(reset),
    .uart_rx(uart_rx),
    .uart_tx(uart_tx)
  );

  always #`T_HALF_PERIOD clk = ~clk;

  reg [15:0] dl;  // divisor latch
  reg [15:0] dlc; // divisor latch counter

  // generate enable signal
  // system clock speed) / (16 x desired baud rate)
  always @(posedge clk or posedge reset) begin
    if (reset) begin
      dlc <= 'd0;
    end
    else
      if (~(|dlc))
        dlc <= dl - 'd1;
      else
        dlc <= dlc - 'd1;
  end

  always @(posedge clk or posedge reset) begin
    if (reset)
      bclk <= 1'b0;
    else
      if (~(|dlc))
        bclk <= 1'b1;
      else
        bclk <= 1'b0;
  end

  task serial_send;
    input [7:0] byte;
    integer i, j;
    begin
      uart_rx = 0; // start bit
      for (i = 0; i < 16; i = i + 1)
      begin
        @(posedge bclk);
      end

      for (i = 0; i < 8; i = i + 1)
      begin
        uart_rx = byte[0]; 
        byte = byte >> 1;
        for (j = 0; j < 16; j = j + 1)
        begin
          @(posedge bclk);
        end
      end

      uart_rx = 1; // stop bit
      for (i = 0; i < 16; i = i + 1)
      begin
        @(posedge bclk);
      end
    end
  endtask

  initial begin
    clk = 1'b0;  
    uart_rx = 1'b1;
    reset = 1'b1;
    bclk = 1'b0;
    dl = 'd54;
    dlc = 'd0;

    // generate reset
    #`T_HALF_PERIOD
    reset = 0;

    serial_send('hA);

    #(`T_HALF_PERIOD * 1000 * 16) $finish;
  end
endmodule
```

testbench主要内容就是编写一个serial_send任务, 用来向srx_pad_i发送特定的字符0xa.通过仿真, 只要我们在stx_pad_o上看到发来的经过处理过后的0xb, 就说明soc.v工作了.

具体的仿真截图如下:

![](https://camo.githubusercontent.com/20bdedf60124a148eda876b7bafead5d7a2820cd/68747470733a2f2f7472656c6c6f2d6174746163686d656e74732e73332e616d617a6f6e6177732e636f6d2f3535646433343163633936373733333135366637343835342f3561356132356532653364656461333033383739363830612f62616461383765623338366635653633306634393731366431663235396638352f736f635f73696d5f30302e706e67)

# 7 FPGA上板调试 (基于Zedboard)

接下来就是将我们写的soc.v放到FPGA上跑一下, 看看到底是不是会输入一个字符`a`, 输出一个字符`b`.

## 7.1 FPGA配置

不过在上FPGA调试之前, 我们还需要想明白几个问题:

- FPGA上时钟是多少, 怎么把时钟接到soc模块的clk脚?以及对应的divisor分频系数应该设置成多少? 

通过查询zedboard原理图以及Hardware User Guide, 发现它的外部晶振管脚是Y9，我们可以直接写约束文件引入即可.该外部晶振是100MHz, 因此要想产生115200Hz的波特率, 分频系数计算如下:

100Mhz / (16 * 115200) = 54

- 上电之后如何进入初始状态?  

将复位拉给外部的一个开关来完成复位

- 如何显示电路正在工作? 

利用LED来显示当前是否收到数据，以及是否将数据发送出去

## 7.2 FPGA 管脚XDC约束

经过上面的思考,写出对应的FPGA管脚约束如下:

```
set_property PACKAGE_PIN Y9 [get_ports clk]
create_clock -period 50.000 -name clk -waveform {0.000 25.000} [get_ports clk]
set_property PACKAGE_PIN F22 [get_ports reset]

set_property PACKAGE_PIN Y11 [get_ports uart_tx]
set_property PACKAGE_PIN AA11 [get_ports uart_rx]

set_property PACKAGE_PIN T22 [get_ports led0]
set_property PACKAGE_PIN T21 [get_ports {led1}]
set_property PACKAGE_PIN U22 [get_ports {led2}]

set_property IOSTANDARD LVCMOS33 [get_ports -of_objects [get_iobanks 33]]
set_property IOSTANDARD LVCMOS33 [get_ports -of_objects [get_iobanks 35]]
set_property IOSTANDARD LVCMOS33 [get_ports -of_objects [get_iobanks 13]]
```

相应的FPGA管脚配置:

![](https://camo.githubusercontent.com/31cd0c77f083a3bdf19cb04e83fe6a3dcf6e1d6c/68747470733a2f2f7472656c6c6f2d6174746163686d656e74732e73332e616d617a6f6e6177732e636f6d2f3535646433343163633936373733333135366637343835342f3561356132356532653364656461333033383739363830612f30626533386535303264356130303238656436396137376338393932343530622f7a6564626f6172645f756172745f6c6f6f702e6a7067)

烧写成功后, 连上串口, 当输入字符a的时候，输出会是b.

![](https://camo.githubusercontent.com/29a9a86495d71a39496430795247fa5d514f1fcd/68747470733a2f2f7472656c6c6f2d6174746163686d656e74732e73332e616d617a6f6e6177732e636f6d2f3535646433343163633936373733333135366637343835342f3561356132356532653364656461333033383739363830612f30623534636430613939376564666266303830626165623331323165626262332f756172745f6c6f6f706261636b5f73637265656e73686f742e706e67)

# 8 AXI UART16550 IP

![](https://camo.githubusercontent.com/86734f70b63cd6ac257e8dd7d46d04c792dd6742/68747470733a2f2f7472656c6c6f2d6174746163686d656e74732e73332e616d617a6f6e6177732e636f6d2f3535646433343163633936373733333135366637343835342f3561356132356532653364656461333033383739363830612f31633835313965613632373632663335356337663666373132633866303930352f4158495f5541525431363535302e706e67)

基于前面的学习，我们已经对UART足够熟悉了，为了能够让UART挂到AXI 总线上, 现在我们需要了解AXI总线的时序, 为了简化我们将它挂到AXI LIte总线上， 将它的收发映射到寄存器上, 用来给软件调用。

## 8.1 AXI Lite总线读写时序

- AXI是基于VALID/READY的握手机制数据传输协议，发起方使用VALID表明地址/控制信号、数据是有效的，接受方使用READY表明自己能够接受信息。

### 8.1.1 读时序

![](https://camo.githubusercontent.com/a7bbed425dbdb31a7b1bf8c5673beb9d4e4574ca/68747470733a2f2f7472656c6c6f2d6174746163686d656e74732e73332e616d617a6f6e6177732e636f6d2f3535646433343163633936373733333135366637343835342f3561356132356532653364656461333033383739363830612f37303739626338636435303263386339666438626261333966366537393533652f6178695f6c6974655f726561642e706e67)

### 8.1.2 写时序

![](https://camo.githubusercontent.com/e970277727003d98beaeef27bb6cb1c6bcba8733/68747470733a2f2f7472656c6c6f2d6174746163686d656e74732e73332e616d617a6f6e6177732e636f6d2f3535646433343163633936373733333135366637343835342f3561356132356532653364656461333033383739363830612f62333937333163313534633466363439333636643566643237343933303365612f6178695f6c6974655f77726974652e706e67)

Vivado的Package IP功能使得我们可以根据wizard创建AXI Lite, 并且生成相应的模板verilog, 我们可以根据它生成出来的代码做相应的修改，这样节约了调试AXI总线VALID, READY, RESP等信号的时间.

![](https://camo.githubusercontent.com/25635d8a2fcf125cae236c663ec491dc919673a1/68747470733a2f2f7472656c6c6f2d6174746163686d656e74732e73332e616d617a6f6e6177732e636f6d2f3535646433343163633936373733333135366637343835342f3561356132356532653364656461333033383739363830612f61633164636637353432613330333366386237313166336331653238666566332f6e65775f69705f312e706e67)

![](https://camo.githubusercontent.com/db3a202e6facc296849baf857761f01fe8e433a9/68747470733a2f2f7472656c6c6f2d6174746163686d656e74732e73332e616d617a6f6e6177732e636f6d2f3535646433343163633936373733333135366637343835342f3561356132356532653364656461333033383739363830612f61363334393062303632313065363733383564323130363531313938346534392f6e65775f69705f322e706e67)

![](https://camo.githubusercontent.com/1285b77ded4b5e4ea7c7a54fa3deb75a37f111cf/68747470733a2f2f7472656c6c6f2d6174746163686d656e74732e73332e616d617a6f6e6177732e636f6d2f3535646433343163633936373733333135366637343835342f3561356132356532653364656461333033383739363830612f66643562346138393565373730393634386163666236333065316361323863382f6e65775f69705f332e706e67)

![](https://camo.githubusercontent.com/09723f3530ea5f204d0ffb8de2922c4e904e8405/68747470733a2f2f7472656c6c6f2d6174746163686d656e74732e73332e616d617a6f6e6177732e636f6d2f3535646433343163633936373733333135366637343835342f3561356132356532653364656461333033383739363830612f35653639616130333961653330613966396232363762626338613664373363372f6e65775f69705f342e706e67)

https://camo.githubusercontent.com/784ef392442a2050e4be76acda1da7e917858a13/68747470733a2f2f7472656c6c6f2d6174746163686d656e74732e73332e616d617a6f6e6177732e636f6d2f3535646433343163633936373733333135366637343835342f3561356132356532653364656461333033383739363830612f33383632343535366333393333616165363465346534366466343261643866612f6e65775f69705f352e706e67)

![](https://camo.githubusercontent.com/d0eeb86e17e58e6648c450b121e8800530a9b7fc/68747470733a2f2f7472656c6c6f2d6174746163686d656e74732e73332e616d617a6f6e6177732e636f6d2f3535646433343163633936373733333135366637343835342f3561356132356532653364656461333033383739363830612f63313635623735623432386266363330363338373031323834353937356234352f637573746f6d5f6178695f69702e706e67)

vivado会自动生成两个源文件, 一个是`myip_v1_0.v`, 另一个是`myip_v1_0_S00_AXI`, 包含了AXI Lite外设的实现细节, 事实上我们可以直接打包这个IP, 读写对应地址上的寄存器, 只不过此时这个IP还没有实现相应的功能罢了.

因此接下来的工作就是修改`myip_v1_0`和`myip_v1_0_S00_AXI`, 目的是将UART功能变成可以操作的寄存器地址空间, 以方便PS端写程序进行调用.

## 8.2 移植

### 8.2.1 PUSH/POP操作

```
wire push_cmd;
wire pop_cmd;
assign push_cmd = (axi_awready == 1) && (axi_awaddr[ADDR_LSB+OPT_MEM_ADDR_BITS:ADDR_LSB] == 'd1);
assign pop_cmd  = (axi_arready == 1)  && (axi_araddr[ADDR_LSB+OPT_MEM_ADDR_BITS:ADDR_LSB] == 'd2);
```
### 8.2.2 寄存器分配

### 8.2.2.1 slv_reg0[7:0]  用来设置波特率的分频系数

```
assign dl = slv_reg0[7:0];
```

### 8.2.2.2 slv_reg1[7:0]  发送寄存器

```
uart_top uart_i(
...
.wb_dat_i(slv_reg1[7:0])
...
);
```

### 8.2.2.3 slv_reg2[7:0]  接收寄存器

```
always @(*)
begin
    // Address decoding for reading registers
    case ( axi_araddr[ADDR_LSB+OPT_MEM_ADDR_BITS:ADDR_LSB] )
	2'h2   : reg_data_out <= rf_data_out[10:3];
	default : reg_data_out <= 0;
    endcase
end
```

### 8.2.2.4 slv_reg3[31:0]接收fifo的深度 

```
always @(*)
begin
    // Address decoding for reading registers
    case ( axi_araddr[ADDR_LSB+OPT_MEM_ADDR_BITS:ADDR_LSB] )
	2'h3   : reg_data_out <= (rf_count);
	default : reg_data_out <= 0;
    endcase
end
```

## 8.3 block design

将IP打包完成之后, 我们使用vivado的block design调用该IP, 将uart_tx, uart_rx引出, 然后生成bit文件, 下载到FPGA开发板上.

![](https://camo.githubusercontent.com/0b6da0e59152da2376e7ab7efc7640ffd11eacf5/68747470733a2f2f7472656c6c6f2d6174746163686d656e74732e73332e616d617a6f6e6177732e636f6d2f3535646433343163633936373733333135366637343835342f3561356132356532653364656461333033383739363830612f63643538353163386162356233336332653135366539393231303839393434362f756172745f626c6f636b5f64657369676e2e706e67)

## 8.4 SDK编程

```
#include <stdio.h>
#include "platform.h"
#include "xil_printf.h"

/* Register access macros */
#define REG8(add) *((volatile unsigned char *)(add))
#define REG16(add) *((volatile unsigned short *)(add))
#define REG32(add) *((volatile unsigned long *)(add))

#define UART_BASE 0x43c00000
#define IN_CLK 100000000
#define UART_BAUD_RATE 115200


void uart_init()
{
	uint8_t divisor;
	/* Set baud rate */
	divisor = IN_CLK/(16 * UART_BAUD_RATE);
	REG8(UART_BASE + 0) = divisor;
	return;
}

int main()
{
    init_platform();
    uart_init();
    int i;
    int j = 0;
    uint32_t x;
    int len;

    while (1) {
    	len = REG32(UART_BASE + (3 * 4));

		if (len > 0) {
			x = REG32(UART_BASE + (2 * 4));
			printf("[%d] pop > %x[%c]\n", len, x, x & 0xff);
			for (i = 0; i < 0xffffff; i++);
		}
    }
    cleanup_platform();
    return 0;
}
```

这段代码的意图是不断查询接收rx fifo中是否有数据, 如果有数据就把数据取出来并打印出来.因此我们可以构造一个环境利用计算机外接的串口往srx_pad_i中发送数据，然后再监听zedboard本身接在PS端的串口打印出来的数据.

上述代码中`UART_BASE`是UART外设在AXI总线上分配的基地址, 这个是在我们调用并创建UART外设的时候由vivado自动帮我们分配的. 我们也可以手动指定, 具体的设置方法是点击菜单栏的`Window`->`Address Editor`，然后会在右边的tab中看到`Address Editor`一栏如下:

![](https://camo.githubusercontent.com/65c117cc8983ef8191b797d65066472c6f0a5b32/68747470733a2f2f7472656c6c6f2d6174746163686d656e74732e73332e616d617a6f6e6177732e636f6d2f3535646433343163633936373733333135366637343835342f3561356132356532653364656461333033383739363830612f66356366363731623038623533333630333635616336343636613761653030342f616464726573735f656469746f722e706e67)

其中`0x43C0_0000`就是基地址.

另外当我们访问slv_reg[3:0]寄存器的时候我们实际访问的是基地址+偏移量, 由于AXI总线是32位的, 因此地址的偏移量应该是寄存器id * 4, 表示下一个寄存器偏移量是上一个寄存器的32位(4个byte)之后.因此访问接收fifo中的深度的时候用的表达式是: ```len = REG32(UART_BASE + (3 * 4));```.

基地址和偏移量不可以搞错, 要不然就访问不到UART外设了.

载入对应的elf文件之后, 我们可以在串口中观察到现象:

![](https://camo.githubusercontent.com/3687d2c4a962a7ea317b8715aece491ae4b53724/68747470733a2f2f7472656c6c6f2d6174746163686d656e74732e73332e616d617a6f6e6177732e636f6d2f3535646433343163633936373733333135366637343835342f3561356132356532653364656461333033383739363830612f35396338383538613634646530613237666564313739643764633261656436632f6475616c5f756172745f636f6d6d2e706e67)

# 9 参考资料

- [Wikipedia 16550 UART ](https://en.wikipedia.org/wiki/16550_UART)
- [毕业设计片上系统的UART接口控制器IP设计](https://wenku.baidu.com/view/c9f2e784a0116c175f0e4834.html)
- [Xilinx Designing a custom axi slave](https://trello-attachments.s3.amazonaws.com/55dd341cc967733156f74854/5a5a25e2e3deda303879680a/45699251c84bc4a1ca94f69faa26236c/designing_a_custom_axi_slave_rev1.pdf)
- [TI UART16550 Manual](https://trello-attachments.s3.amazonaws.com/55dd341cc967733156f74854/5a5a25e2e3deda303879680a/15fa61e2f27090f14488f6744fc70015/TI_UART16550_Manual.pdf)
- [ZedBoard Hardware User’s Guide](http://zedboard.org/sites/default/files/documentations/ZedBoard_HW_UG_v2_2.pdf)
- [ZedBoard RevD.2 Schematic](http://zedboard.org/sites/default/files/documentations/ZedBoard_RevD.2_Schematic_130516.pdf)
