# Coze

一个用于 macOS 的轻量辅助工具：

- 微信超长文本自动转换为 DOCX；
- Claude Code 与 OpenCode 任务完成提醒（可同时开启）；
- 限时合盖继续运行。

## macOS 安装

从 [`releases/Coze-1.5-macOS.zip`](releases/Coze-1.5-macOS.zip) 解压，将 `Coze.app` 拖入“应用程序”文件夹后打开。

首次使用时，如 macOS 阻止打开，请在 Finder 中按住 Control 点击应用并选择“打开”。在 Coze 中分别启用 Claude Code 和 OpenCode 后，请新开一次对应的终端会话，使 hook/plugin 生效。

## 源码

macOS 源码位于 [`macos/`](macos)：使用 macOS 自带的 Swift 编译器构建。

```sh
swiftc -parse-as-library -framework Cocoa -framework ApplicationServices -framework UserNotifications macos/Coze.swift -o Coze
```

## Windows

Windows 的微信长文本转 DOCX 脚本位于 [`windows/`](windows)。请查看该目录中的 README 了解使用步骤。

## 版本

当前发布版本：1.5。
