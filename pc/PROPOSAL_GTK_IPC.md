# 方案：C UI + Go 业务，进程分离（Pipe IPC）

## 背景与问题

当前 Linux 渲染器（`renderer_linux.go`）通过 CGo 在同进程内调用 GTK3 + WebKit2GTK 创建窗口，存在**无解的信号冲突**：

### 信号冲突的根因

```
JSC 默认使用 SIGUSR1 做 GC 信号
   ↓
Go runtime 也占用了 SIGUSR1（sigtab_linux_generic.go:10）
   ↓
JSC 初始化时检测到 SIGUSR1 已被占用 → SIGABRT
```

尝试通过 `JSC_SIGNAL_FOR_GC` 环境变量切换 JSC 的信号：

| 可选值 | 信号号 | Go runtime 是否占用 |
|--------|--------|---------------------|
| `SIGUSR1` | 10 | **是**（`_SigNotify`） |
| `SIGUSR2` | 12 | **是**（`_SigNotify`） |
| `SIGPIPE` | 13 | **是**（`_SigNotify`） |
| `SIGALRM` | 14 | **是**（`_SigNotify`） |
| `SIGPROF` | 27 | **是**（`_SigNotify + _SigUnblock`） |

**JSC 只接受这 5 个信号名，Go 全部占用了。** 这个 env var 方案从根本上就是死胡同。

Go 的 runtime 通过 `sigtable` 为信号 1–64 全部安装了 handler，连 `SIGRTMIN`（35）等实时信号也不例外——所以**没有任何一个信号是 JSC 和 Go 可以和平共享的**。这决定了 CGo 同进程方案在这个场景下不可行。

### 已有尝试

- `JSC_SIGNAL_FOR_GC=SIGUSR2` → SIGABRT（SIGUSR2 也被 Go 占用）
- `JSC_SIGNAL_FOR_GC=12` → JSC 报 `ERROR: invalid option`（JSC 只接受信号名不接受数字）

## 新方案：进程分离

**核心思路：让 GTK/WebKit 运行在独立的 C 进程中，Go 进程通过 pipe (stdin/stdout) 与它通信。**

```
┌─────────────── Go 进程 (avatar-pc) ───────────┐
│                                                │
│  ┌─ 状态机 (brain)                             │
│  ├─ ASR / TTS / KWS / LLM                      │
│  ├─ 音频 I/O (malgo)                           │
│  ├─ HTTP server :34023 (serve web assets)      │
│  └─ renderer_linux.go                          │
│       ├─ os/exec → 启动 C 子进程               │
│       ├─ stdin → 写 JSON 命令给 C              │
│       └─ stdout → 读 JSON 事件从 C             │
│                                                │
│  C 子进程 (avatar-ui) 的 stdin/stdout          │
└──────────────┬─────────────────────────────────┘
               │ pipe (stdin/stdout)  — 每行一个 JSON
               │
┌──────────────▼ C 进程 (avatar-ui) ─────────────┐
│                                                │
│  依赖: GTK3 + WebKit2GTK 4.1                   │
│  ~150 行 C 代码，无 Go CGo 依赖                │
│                                                │
│  ┌─ 启动后 HTTP 加载 http://127.0.0.1:PORT/   │
│  ├─ stdin reader → 解析 JSON 命令              │
│  │    {"cmd":"eval","js":"..."}                 │
│  │    {"cmd":"quit"}                            │
│  ├─ JS→native bridge → stdout 输出 JSON       │
│  │    {"type":"tap","data":{}}                  │
│  └─ 窗口关闭 → 退出，通知 Go                    │
│                                                │
└────────────────────────────────────────────────┘
```

## 协议设计

### Go → C（Command，Go 通过 C 子进程的 stdin 发送）

每行一个 JSON 对象，以换行符 `\n` 分隔：

```json
{"cmd": "eval", "js": "if(window.handleMessage)handleMessage(...)"}
{"cmd": "quit"}
```

| 命令 | 说明 |
|------|------|
| `eval` | 在 WebView 中执行 JS 代码（`webkit_web_view_evaluate_javascript`） |
| `quit` | 关闭 GTK 窗口，C 进程退出 |

### C → Go（Event，C 子进程通过 stdout 发送）

每行一个 JSON 对象，以换行符 `\n` 分隔：

```json
{"type": "tap", "data": {}}
```

C 端通过 WebKit 的 UserContentManager script-message 机制接收 JS 调用 `window.webkit.messageHandlers.bridge.postMessage(...)`，然后原样输出到 stdout。

## 具体实现

### 1. C 程序 `cmd/avatar-ui/main.c`（~150 行）

```c
// 做的事：
// 1. 从命令行参数读 URL（http://127.0.0.1:PORT/index.html）
// 2. 创建 GTK 透明窗口 + WebKit WebView
// 3. 注册 JS→native bridge（script-message-received → stdout）
// 4. 事件循环中监听 stdin（GIOChannel），解析 JSON 命令
// 5. 收到 "quit" 或窗口关闭 → 退出
```

依赖：
- `gtk+-3.0`
- `webkit2gtk-4.1`
- `json-glib-1.0`（或手写简单 JSON 解析，因为协议极简）

编译：
```bash
gcc -O2 -o avatar-ui cmd/avatar-ui/main.c \
  $(pkg-config --cflags --libs gtk+-3.0 webkit2gtk-4.1 json-glib-1.0)
```

### 2. Go 端重写 `renderer_linux.go`（~120 行）

```go
// 做的事：
// 1. 启动 HTTP server 提供 web 资源（不变）
// 2. os/exec 启动 avatar-ui 子进程，传入 URL
// 3. 创建 stdin/stdout pipe
// 4. SendMessage() → 写 JSON 到 stdin
// 5. 后台 goroutine 读 stdout → 解析事件 → 发到 events channel
// 6. Run() → 等待子进程退出
// 7. Close() → 写 "quit" 到 stdin，或 kill 子进程
```

接口不变：`Renderer` 接口的 4 个方法签名完全一致。

### 3. 编译流程

```makefile
# Makefile
build: avatar-ui avatar-pc

avatar-ui: cmd/avatar-ui/main.c
	$(CC) -O2 -o $@ $< $(shell pkg-config --cflags --libs gtk+-3.0 webkit2gtk-4.1 json-glib-1.0)

avatar-pc:
	go build -o avatar-pc .

run: build
	./avatar-pc
```

或者更简单——`go build` 之前先 `make avatar-ui`，Go 二进制在运行时查找同目录的 `avatar-ui`。

## 与现有方案对比

| 维度 | 当前方案（CGo 同进程） | 新方案（C + Go 进程分离） |
|------|----------------------|--------------------------|
| 信号冲突 | **无解**（Go 占用全部 JSC 可选信号） | 不存在（两进程独立 signal mask） |
| 稳定性 | CGo crash 拖垮整个 Go 进程 | C 进程 crash 不影响 Go，Go 可重启 UI |
| 调试 | 栈混在一起，难以定位 | 各自独立，gdb/lldb 清晰 |
| 编译 | `go build` 一步 | 先 `gcc` 编译 C，再 `go build` |
| 部署 | 单一二进制 | 两个二进制（avatar-pc + avatar-ui） |
| 启动时间 | 无额外开销 | fork + exec 子进程，~几毫秒 |
| IPC 延迟 | 无（函数调用） | 管道 JSON 序列化，~微秒级 |
| 接口 | `Renderer` interface | `Renderer` interface（完全不变） |
| 代码量 | CGo 混合 ~230 行 | C ~150 行 + Go ~120 行 |
| 平台覆盖 | Linux only | Linux only（Windows 不变） |

## 风险评估

| 风险 | 等级 | 对策 |
|------|------|------|
| 子进程意外退出 | 低 | Go 检测 `exec.Cmd` 的 exit，自动重启或优雅降级 |
| 管道阻塞 | 低 | 使用带缓冲的读写，stdin/stdout 各一个 goroutine |
| JSON 解析失败 | 低 | 忽略非法行，打 log，继续读下一行 |
| 子进程僵尸 | 低 | Go `Wait()` 回收，或 `cmd.Process.Release()` |
| 编译依赖多一个 json-glib | 低 | 可以手写极简 JSON 解析器（只解析 `{"cmd":"eval"...}` 这种固定格式），消除依赖 |
| 部署时忘记带 avatar-ui | 低 | Go 启动时检查 `avatar-ui` 是否存在，给出清晰错误提示 |

## 实施步骤

1. **创建 `cmd/avatar-ui/main.c`** — C 窗口程序，约 150 行
2. **重写 `renderer_linux.go`** — 用 `os/exec` + pipe 替代 CGo，约 120 行
3. **添加 `Makefile`** — 编译 C + Go
4. **测试** — 启动 avatar-pc，验证窗口显示、消息通信、事件回传
5. **清理** — 从 `renderer_linux.go` 删除所有 CGo 代码和 `go_*_cb` 导出函数

## 结论

这个方案用最小的代价（多一个编译产物、几毫秒 IPC 延迟）彻底解决了 Go runtime 与 WebKitGTK 的信号冲突问题。同时自带进程隔离的好处——C UI 崩了不影响 Go 业务，Go 业务崩了 C UI 也能优雅退出。

**推荐立即实施。**