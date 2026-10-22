# 开发交接

- 端口页的通配地址显示为 `*`，但冲突判断必须保留内核 `insi_vflag` 的 IPv4、IPv6 或双栈信息；不同本地地址不能只因端口号相同就标记冲突，标记结果须关联具体 socket。
- `brew services list` 属于只读预览，`services start/stop/restart` 属于写操作；不要让服务启停进入预览超时后终止进程的路径。回归使用隔离的假 `brew`，避免修改开发机服务。
