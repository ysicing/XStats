# server/api 开发指南

本目录是 XStats 的更新检查与安装统计服务，使用 Go、Fiber v3、GORM 和 SQLite。依赖以 `go.mod` 为准。

## 结构

- `main.go`：路由、HTTP 入口与服务启动。
- `sparkle_validation.go`：Sparkle 清单与安装包校验逻辑。
- `dashboard.html`：嵌入二进制的统计页面模板。
- `*_test.go`、`testdata/`：配置、Sparkle 与接口测试及样本。

## 命令

- 测试：`cd server/api && go test ./...`，或在仓库根目录运行 `task test-api`。
- 修改 Sparkle 清单或 XML 解析时，同步更新 `sparkle_test.go` 与 `testdata/` 样本。

## 约定

- 新增或修改 Go 文件时保留文件头：`Copyright (C) 2026 ysicing` 与 `SPDX-License-Identifier: AGPL-3.0-or-later`。
- 注释默认使用简体中文，解释原因与必须保持的约束；逻辑变更后同步更新或删除失效注释。
- 旧 JSON 协议需保持兼容；固定 XML API 原样返回已签名清单。
- 数据库访问使用参数化查询，不拼接不可信输入。
