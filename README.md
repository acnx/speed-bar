# SpeedBar

极简 macOS 菜单栏网速显示工具：无窗口、无 Dock 图标，只在菜单栏显示

```
↑   1.2M
↓  34.5K
```

- **↑ 后面是上传速度，↓ 后面是下载速度**
- 单位自动进位：`B / K / M / G`（1024 进制，K/M/G 保留 1 位小数；显示值四舍五入到 1000 即进位，保证宽度恒定）
- 每 1 秒采样一次（`getifaddrs` 读取网卡计数器，已处理 32 位计数器回绕），速率按真实采样间隔归一化
- 只统计物理网卡（`en*`：Wi-Fi、有线、USB 网卡）；utun 等隧道接口的流量已封装在物理网卡里，不重复统计
- 点击菜单栏可查看本次运行以来的累计上传/下载流量，并可退出

## 编译

```bash
./build.sh
```

产物：`build/SpeedBar.app`（ad-hoc 签名）

构建在临时目录里完成编译、签名和校验，全部通过后才替换产物；失败不会动现有
`build/SpeedBar.app`，旧产物会保留在 `build/backups/`（可自行清理）。

## 运行

```bash
open build/SpeedBar.app
```

## 常驻使用

把 app 拷到「应用程序」目录后再设置开机自启：

```bash
cp -R build/SpeedBar.app /Applications/
osascript -e 'tell application "System Events" to make login item at end with properties {path:"/Applications/SpeedBar.app", hidden:true}'
```

## 文件结构

| 路径 | 说明 |
| --- | --- |
| `Sources/SpeedBar.swift` | 全部源码（AppKit 菜单栏应用） |
| `Info.plist` | 应用清单，`LSUIElement=true` 实现无 Dock 图标 |
| `build.sh` | 编译 + 打包 + 签名脚本 |
