---
title: "irun或者vcs dump波形文件的方法"
date: 2020-01-11
categories: [verification]
tags: [irun, candence, waveform, fsdb]
draft: false
---

## irun

当我们在irun下面需要dump波形文件的时候, 一般会在tb文件中写下如下的代码:

```
module tb_top;

  ...

  logic [1023:0] testcase_reg;
  initial begin
    string testcase;
    $value$plugargs("UVM_TESTNAME=%s", testcase);
    testcase_reg = $sformatf("waveform.%s.shm", testcase);
    $shm_open(testcase_reg);
    $shm_probe("AS");
  end

endmodule
```

注意, 这里之所以引入`testcase_reg`是因为如果直接将testcase以string当作传入`$shm_open`函数会报告错误:

`ncelab: *E,STRNOT(tb_top.sv): Passing string variable to this system task/function is currently not supported.`

## vcs

vcs下面我们一般需要dump fsdb, 因为该格式大小会比原生的vcd要小, 而且可以直接被verdi打开, 但由于它是verdi支持的格式, 需要在编译的是加入对应的PLI, 具体操作为:

首先, 同样我们需要在`tb_top`中写下如下的代码:

```
module tb_top;

  ...
  initial begin
    string testcase;
    $value$plugargs("UVM_TESTNAME=%s", testcase);
    $fsdbDumpfile($sformatf("waveform.%s.fsdb", testcase));
    $fsdbDumpvars("+all");
  end

endmodule
```

然后在对应的vcs编译的时候添加参数:

```
-P /your/verdi/dir/share/PLI/VCS/linux64/novas.tab \
   /your/verdi/dir/share/PLI/VCS/linux64/pli.a
```
