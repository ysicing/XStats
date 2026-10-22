// SPDX-License-Identifier: AGPL-3.0-or-later

extension Translations {
  static let portsEnglish = #"""
    端口	Ports
    端口号	Port
    监听	Listening
    已建立	Established
    对端	Peer
    冲突	Conflict
    拷贝本地地址	Copy Local Address
    拷贝对端地址	Copy Peer Address
    按进程统计，同一进程的各行速率相同	Measured per process; rows from the same process show the same rate
    搜索端口、进程、服务或地址	Search port, process, service or address
    暂时无法读取端口	Unable to read ports right now
    查看监听端口、已建立的连接及占用进程，可结束占用端口的进程。	View listening ports, established connections and the processes using them; quit a process that holds a port.
    正在读取端口…	Reading ports…
    没有匹配的端口	No matching ports
    监听 {} · 连接 {}	Listening {} · Connections {}
    端口 {} 同时被多个进程监听	Multiple processes are listening on port {}
    连接过多，只显示前 {} 项	Too many connections; showing the first {}
    仅列出当前用户的进程，系统服务占用的端口不会显示	Only your own processes are listed; ports used by system services are not shown
    会断开它占用的端口与连接，未保存的内容可能会丢失。强制退出会立即结束，不给应用保存的机会。	Its ports and connections will be closed and unsaved work may be lost. Force Quit ends it immediately without letting the app save.
    结束“{}”（PID {}）？	End “{}” (PID {})?
    进程已退出或不再占用该端口，请刷新后重试	The process has exited or no longer holds this port. Refresh and try again.
    """#
}
