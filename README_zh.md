# appitize

[English](README.md) | [中文](README_zh.md)

把任意网站变成一个独立的、走代理的 macOS App。

`appitize.sh` 是一个交互式脚本，为某个网址生成真正的 `.app` 应用包。双击该
应用，就会用 Google Chrome（应用模式）通过你指定的代理打开该网站，并使用一个
专属的 Chrome 配置文件——因此它像一个原生桌面应用，且拥有独立的登录状态与
Cookie，与日常 Chrome 完全隔离。

应用名称和图标会自动从目标网站读取。由于 Cloudflare 会拒绝普通的 `curl`
请求，读取动作由一个**真实的 Chrome 实例**完成（在屏幕外启动，通过 DevTools
协议驱动）：它能执行 JS 挑战，因此能拿到 `curl` 会得到 403 的内容。普通 HTTP
抓取仅作为兜底。

## 特性

- 交互式：依次询问代理、网址和（可选）应用名。
- 自动获取**应用名**：优先 `og:site_name`，其次页面 `<title>`。
- 自动获取并转换**图标**（可穿透 Cloudflare）为标准的 `.icns`。
- **代理支持**：`--proxy-server` 加自动探测的代理绕过列表。
- **自动局域网探测**：读取物理网卡的 IPv4 地址与掩码，把本机网段
  （如 `192.168.0.0/24`）加入绕过列表。
- **独立配置文件**：每个 App 有各自的 Chrome 用户数据目录。
- **不再弹钥匙串**：生成的 App 与屏幕外抓取都使用 mock 钥匙串，Chrome 不会再
  询问 "Chrome Safe Storage"。
- 安装到 `/Applications`（不可写时回退到 `~/Applications`）。
- 只用 macOS 自带工具（外加 Google Chrome）。

## 环境要求

- macOS 12+
- [Google Chrome](https://www.google.com/chrome/)
- Xcode Command Line Tools（`swiftc`）：`xcode-select --install`
- `python3`（系统自带即可，仅使用标准库）
- 本地已在运行的代理（如 `http://localhost:1080`）；脚本不会替你启动代理。

## 使用

```bash
chmod +x appitize.sh
./appitize.sh
```

示例会话：

```
==> New proxy web app

Proxy address [http://localhost:1080]:
    detected LAN: 192.168.0.0/24
Proxy bypass list [localhost;127.0.0.1;::1;192.168.0.0/24]:

URL: www.chatgpt.com

==> Opening https://www.chatgpt.com in Chrome to read its name and icon ...
    icon: https://chatgpt.com/unauth-mweb/apple-touch-icon.png

App name [ChatGPT]:

==> Creating ChatGPT.app
...
==> Launching...
```

可直接输入裸域名（`www.chatgpt.com` → `https://www.chatgpt.com`）。

## 各项提示

| 提示 | 默认值 | 说明 |
| --- | --- | --- |
| Proxy address | `http://localhost:1080` | 留空则生成不走代理的 App。 |
| Proxy bypass list | `localhost;127.0.0.1;::1;<局域网 CIDR>` | 以 `;` 分隔，局域网段自动探测。 |
| URL | — | 必填，缺少协议时会自动补全。 |
| App name | 自动 | `og:site_name` → 精简后的 `<title>` → 域名主标签。回车即采用。 |

## 工作原理

1. 先询问代理设置，再询问网址。
2. 启动屏幕外的真实 Chrome（走代理），通过 CDP 读取页面标题、
   `og:site_name` 和最佳图标；图标字节在页面内下载，以复用浏览器会话/Cookie。
   若 Chrome / `python3` 不可用，则回退到普通 `curl` 抓取。
3. 询问应用名，默认值为自动探测结果。
4. 构建 `.app`：
   - 用 `swiftc` 编译一个小的 Swift `launcher`（负责再启动 Chrome）；
   - 用 `sips` + `iconutil` 把图标转成 `.icns`；
   - 写入 `Info.plist`。

## 生成的应用结构

```
/Applications/<应用名>.app/
  Contents/
    Info.plist          # CFBundleExecutable=launcher, CFBundleIconFile=AppIcon
    MacOS/launcher      # 编译后的 Swift 启动器
    Resources/AppIcon.icns
```

启动器以如下参数运行 Chrome：

```
--user-data-dir=~/Library/Application Support/Chrome-<slug>
--use-mock-keychain
--password-store=basic
--proxy-server=<代理>
--proxy-bypass-list=<绕过列表>
--app=<网址>
```

## 环境变量

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `BROWSER_WAIT` | `30` | 等待屏幕外 Chrome 渲染页面的秒数。 |

## 说明与排错

- **代理必须已在运行**，脚本不负责启动代理。
- **Cloudflare**：真正的 App 用 Chrome 打开，能正常加载；只有元数据抓取需要那
  个"真实 Chrome"技巧。若仍失败，则生成无图标的 App，名称回退为域名主标签。
- **首次启动 / Gatekeeper**：生成的启动器未签名。若被 macOS 拦截，右键 App →
  打开，或在"系统设置"中允许。
- **钥匙串弹窗**：已通过 `--use-mock-keychain` 处理；万一仍出现 "Where is the
  Chrome keychain"，点 **取消**（切勿点"还原为默认"）。

## License

[MIT](LICENSE) © 2026 Jie Cui
