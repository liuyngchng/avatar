ubuntu 24.04 LTS

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

可以在docker 中运行编译
