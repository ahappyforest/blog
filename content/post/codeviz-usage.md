---
title: "Codeviz 工具编译与使用"
date: 2018-03-04T11:24:57+08:00
categories: [toolchain]
tags: [gcc, codeviz, graphviz, doxygen, code graph]
draft: false
---

codeviz 用来生成代码调用关系

# 安装

```
$ git clone https://github.com/petersenna/codeviz
$ cd compilers
$ ncftpget ftp://ftp.gnu.org/pub/gnu/gcc/gcc-4.6.2/gcc-4.6.2.tar.gz
$ ./install_gcc-4.6.2.sh /usr/local/gcc-graph
```

codeviz目录下的bin/目录就是使用的脚本, 所以也不需要安装, 唯一需要做的事情是需要下载gcc-4.6.2并打上patch, codeviz将使用我们生成的gcc来生成调用关系.为了能让该gcc被调用, 可以这样:

```
export PATH=/usr/local/gcc-graph/bin:$PATH
```

## gcc-4.6.2编译问题解决1(已经废弃, 请按照gcc-4.6.2编译问题解决2走)

### 1. @itemx must follow @item

texinfo版本太新了, 临时降级解决.

```
wget http://ftp.gnu.org/gnu/texinfo/texinfo-4.13a.tar.gz
tar -zxvf texinfo-4.13a.tar.gz
cd texinfo-4.13
./configure
make
sudo make install
```

### 2. fatal error: sys/cdefs.h: No such file or directory

```
$ sudo apt install libc6-dev-i386
```

### 3. error: field ‘info’ has incomplete type

将`gcc-4.6.2/gcc/config/i386/linux-unwind.h`文件下的所有`struct siginfo`替换成`siginfo_t`

```
...
  //struct siginfo *pinfo;
  siginfo_t *pinfo;
  void *puc;
  //struct siginfo info;
  siginfo_t info;
...
```

## gcc-4.6.2编译问题解决2

先修改`install_gcc-4.6.2.sh`将某一行换成这两行:

```
CFLAGS="-fPIC" ../gcc-4.6.2/configure --prefix=$INSTALL_PATH --disable-bootstrap --enable-shared --enable-languages=c,c++ --disable-multilib || exit
make
```

提示: 编译的时候先运行`install_gcc-4.6.2.sh`然后如果编译不过, 就到gcc-graph/objdir目录下再运行make, 这样就不会重新解压编译了.

### 1. cannot find crti.o: No such file or directory

```
LIBRARY_PATH=/usr/lib/x86_64-linux-gnu:$LIBRARY_PATH
export LIBRARY_PATH
```

### 2. error: ‘gnu_inline’ attribute present on ‘libc_name_p’

修改`../gcc-4.6.2/gcc/cp/cfns.h`, 删除libc_name_p函数前面的__inline

```
#ifdef __GNUC__
#endif
// 删除__inline相关的声明
const char *
libc_name_p (register const char *str, register unsigned int len)
{
```

貌似这样就顺利编译通过了.

# 使用

对于如下的t.c源码

```
#include <stdio.h>
 
void t3(void)
{
 
}
 
void t2(void)
{
 t3();
}
 
void t1(void)
{
  t2();
  t3();
}
 
int main(void)
{
  t1();
  t2();
}
```

调用如下genfull脚本生成full.graph文件

```
echo "digraph fullgraph {" > full.graph
echo "node [ fontname=Helvetica, fontsize=12 ];" >> full.graph
 
find . -name '*.c.cdepn' -exec cat {} \; | \
  awk -F"[ {}]+" '{
    if ($1 == "F") {
      print "\""$2 "\" [label=\"" $2 "\\n" $3 ":\"];"
    } else if ($1 == "C") {
      print "\"" $2 "\" -> \"" $4 "\" [label=\"" $3 "\"];"
    }
  }' \
| sort | uniq -u >> full.graph
 
echo "}" >> full.graph
```

然后运行gengraph, 生成main.ps, 这个文件可以用gnome-open打开.

```
$ gcc t.c
opened dep file t.c.cdepn
$ ./genfull
$ /<path>/gengraph  -g full.graph  -f main
Error: <stdin>: syntax error in line 4 near ';' # 这个错误不要管, 不影响
```

最后生成的图如下:

![codeviz_demo](https://user-images.githubusercontent.com/1551572/36943107-f880f146-1fbd-11e8-8c60-3f9456a6a1ef.png)


# 总结

- 由于只能给定一个顶层函数返回查看对应的调用关系图
  - 用下来发现, 对于大量使用函数指针的项目不太实用
  - 对于lua+c的项目也不太实用
- gcc-4.6.2不太好编译, 最好提供一个docker环境来使用.
