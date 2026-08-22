ubuntu 24.04 LTS

```
#编译C，需要webkitgtk
make avatar-ui
```

set up webkitgtk

```
# 1. 更新软件包列表（建议）
sudo apt update

sudo apt --fix-broken install

# 2. 安装 WebKitGTK 4.1 开发库
sudo apt install libwebkit2gtk-4.1-dev

sudo apt install libgtk-3-dev libwebkit2gtk-4.1-dev

pkg-config --cflags --libs webkit2gtk-4.1
```

以上涉及到C的可以在docker 中运行编译


接着编译C
```
go build -o avatar-pc .
```

下面是 go 编译需要的

sudo apt install libasound2-dev
