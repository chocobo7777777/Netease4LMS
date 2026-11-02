# NetEase Cloud Music plugin for Lyrion Music Server

这是一个用 Perl 编写的 Lyrion Music Server（LMS，原名 Logitech Media Server /
Squeezebox Server）插件，用于浏览网易云音乐账号下的歌单、在线播放歌曲，并把
歌单/单曲下载到本地。

插件目录名：`NetEase`，模块命名空间：`Plugins::NetEase::*`。

---

## 1. 目录结构

```text
Netease4LMS/
└── Plugins/
    └── NetEase/
        ├── install.xml                       # LMS 插件清单（必需）
        ├── Plugin.pm                         # 插件入口、浏览菜单、CLI 命令
        ├── Settings.pm                       # 设置页逻辑（登录/退出/验证）
        ├── Downloads.pm                      # 下载队列监控页（只读 + 取消/清空）
        ├── API.pm                            # 网易云接口封装（两种后端）
        ├── ProtocolHandler.pm                # netease:// 播放协议处理器
        ├── Downloader.pm                     # 下载队列、命名、重试、跳过、状态跟踪
        ├── strings.txt                       # 英文/简体中文界面文本
        └── HTML/
            └── EN/
                └── plugins/
                    └── NetEase/
                        └── settings/
                            ├── basic.html       # 插件设置页模板
                            └── downloads.html   # 下载队列监控页模板
```

安装后 LMS 中的位置：`设置 → 插件 → NetEase Cloud Music`；浏览入口：
`我的应用 / My Apps → 网易云音乐`。

---

## 2. 功能范围

已实现：

- 插件可被 LMS 识别：`install.xml`、`Plugin.pm`、`Settings.pm`、`strings.txt`、
  设置页模板齐全。
- 账号登录：
  - 后端模式：手机号 + 密码登录、扫码登录（通过 NeteaseCloudMusicApi）；
  - 任意模式：手动粘贴 Cookie 登录；
  - 登录状态保存在 LMS 插件 prefs（`plugin.netease`）中；
  - 设置页“退出登录”会清除本地 Cookie、UID、昵称，并尝试调用后端 `/logout`。
- 歌单浏览：`网易云 → 我的歌单 → 歌单 → 曲目`，显示歌单名、封面、曲目数；
  歌单超过 1000 首时自动拆成每页 1000 首的分页入口，每页可整页播放。
- 登录后的个性化入口：`每日推荐`、`我喜欢的音乐`（红心歌曲；超过 300 首时
  自动拆成多个分页入口，每页可整页播放，不再只显示最近 1000 首），
  均以普通曲目菜单展示，可直接在线播放。
- 未登录也可用的公开入口：`推荐新歌`（30 首）与 `搜索歌曲`（关键词只支持歌名/歌手名，
  返回前 30 条结果）。
- 在线播放：曲目以 `netease://track/<songId>` 进入 LMS 播放链路，
  `Plugins::NetEase::ProtocolHandler` 在播放前解析真实音频 URL，再交给 LMS
  的 HTTPS 协议处理器，因此播放/暂停/seek/重定向复用 LMS 核心实现。
- 不可播放提示：菜单会提前解析 URL；没有 URL 的曲目显示为不可播放文本项，
  并标注原因（VIP、版权/地区限制、仅可试听、Cookie 失效等）。
- 下载：浏览菜单“下载 → 歌单 → 曲目”按需选择，可整张歌单下载，也可点单曲只下这一首；
  也支持 CLI。文件命名、目录结构、跳过已存在文件、临时文件、失败重试均已实现。
- 下载队列监控页：`设置 → 插件 → 下载队列`（或设置页顶部“下载队列”链接）实时显示
  当前任务进度（已处理/总数、已存/跳过/失败计数）、排队任务、最近 30 条历史及每条
  任务的错误信息；支持取消排队/运行中的任务、清空历史，有任务活动时页面每 4 秒自动刷新。

未实现（有意留到后续）：

- 专辑/歌手浏览、私人 FM、喜欢/取消喜欢等写操作；
- 短信验证码登录；
- 歌词、封面嵌入、ID3/FLAC 标签写入；
- 自动把下载目录加入音乐库并触发扫描。

---

## 3. 两种网易云接法：选型与风险

### A. NeteaseCloudMusicApi（默认，推荐，建议用 Enhanced 维护版）

插件通过 HTTP 调用本地运行的 NeteaseCloudMusicApi Node.js 服务，由该服务完成网易云
网页接口的加密/签名、Cookie 管理和播放地址解析。

原版 [Binaryify/NeteaseCloudMusicApi](https://github.com/Binaryify/NeteaseCloudMusicApi)
的 GitHub 仓库已停止更新，推荐改用社区维护的接续项目
[NeteaseCloudMusicApiEnhanced/api-enhanced](https://github.com/neteasecloudmusicapienhanced/api-enhanced)。
它是原版的分支重构，**接口路径和返回结构与原版一致**，插件无需改动即可切换：

- 相关接口都存在：`/login/cellphone`、`/login/status`、`/login/qr/key|create|check`、
  `/logout`、`/user/playlist`、`/playlist/detail`、`/playlist/track/all`、
  `/song/detail`、`/song/url/v1`；
- `/login/status` 仍返回 `{ data: { code, account, profile } }`，与本插件的解析逻辑一致；
- 仍支持 `realIP` 参数（扫码登录的风控绕过仍可用）；
- 默认端口仍是 `3000`，Docker 镜像为 `moefurina/ncm-api:latest`。

需要注意的一处差异：Enhanced 版在**未登录**时，`/login/status` 也会返回一个
`type=1000` 的匿名 `account`（带 id、`profile` 为 `null`）。插件从 0.1.9 起只以
`profile.userId` 判定是否登录，因此不会把匿名账号误判成“登录成功”。

选择它作为默认实现的原因：

- 登录、Cookie、`weapi/eapi` 加密、`song/url/v1` 等复杂逻辑由成熟项目处理，
  插件本身只需发普通 HTTP 请求，代码量和维护成本最低。
- 支持手机号+密码、扫码登录，能拿到 `Set-Cookie`，也支持直接用 Cookie 调
  `/login/status` 验证账号。
- `/song/url/v1` 能按 `standard/higher/exhigh/lossless` 请求音质，并返回
  `freeTrialInfo`、`fee`、`code` 等信息，便于在菜单中解释“为什么不能播”。
- `/playlist/track/all` 支持 `limit/offset`，但单次最多返回 1000 首；插件按每页
  1000 首（红心 300 首）分页展示，整单下载时逐页拉全量，因此不受 1000 首截断影响。

风险：

- 需要额外运行一个 Node.js 服务；服务停止时插件只能读缓存/报错。
- 后端仍是第三方项目，可能停止维护；网易云接口变化时可能失效。原版 GitHub 仓库已停更，
  所以建议用 Enhanced 维护版（见上）。
- Enhanced 版默认开箱带“全局解灰”（`ENABLE_GENERAL_UNBLOCK`）：对无播放地址、仅试听或
  VIP 歌曲，会用第三方音源（QQ/酷我/酷狗/咪咕等）补一个 URL。开启后菜单里原本标为
  “不可播放”的曲目可能变得可播，但音源不再是网易云官方，可用性和合规性需自行判断；
  想保持与原版一致的行为，启动时设 `ENABLE_GENERAL_UNBLOCK=false`。
- 手机号+密码登录可能被网易云风控拦截（`code:400`，提示“检测到当前登录存在安全
  风险”）；插件已提供扫码登录作为替代，仍失败时使用 Cookie。
- 扫码登录在旧版 Binaryify（Docker 镜像 `binaryify/netease_cloud_music_api` 内置的
  4.27.0，启动时会提示升级）上很容易被拦截（“当前设备环境异常”，源于网易云对二维码/
  设备指纹的判定）；换用 Enhanced 新版后端后该问题大概率消失，仍失败时可填公网 IP
  或用 Cookie 兜底。
- 如果 API 服务暴露在公网且没有鉴权，任何能访问它的人都可能操作你的网易云账号；
  建议只监听 `127.0.0.1`，或放在带认证的反向代理后面。

### B. 直连网页接口（实验性，可配置）

插件也可以切换为 `direct` 模式，直接用 Cookie 请求 `music.163.com` 的
`/api/...` 旧版接口，不依赖 Node.js。

已验证可用的直连接口：

- `/api/user/playlist?uid=...`：用户歌单；
- `/api/v6/playlist/detail?id=...`：歌单详情，返回 `tracks` 和 `trackIds`；
- `/api/song/detail?ids=[...]`：歌曲详情；
- `/api/song/enhance/player/url?ids=[...]&br=...`：播放地址（未登录返回 `code=-110`）。

为什么它是实验性：

- 登录需要网页 `weapi` 加密，插件没有实现加密逻辑，所以直连模式只支持
  **手动粘贴 Cookie**，并且必须手动填写 UID。
- 旧版 `/api/song/enhance/player/url` 的可用性、码率上限、风控策略不如
  `song/url/v1` 稳定；无损/高码率可能拿不到。
- 没有可靠的“当前登录用户”接口，设置页的“验证”只能以“能否取到该 UID 的歌单”
  作为最佳努力校验，不能严格证明 Cookie 有效。
- 网易云可能随时下线旧接口或封禁服务器 IP。

默认使用 A；在设置页把 `Backend` 改成 `Direct weapi/eapi (experimental)` 即切换到 B。
两种模式不会自动互相回退，避免在未提示的情况下改变凭据使用方式。

---

## 4. 安装

### 4.1 放置插件

1. 找到 LMS 的 `Plugins` 目录。可以在 LMS 日志开头看到插件搜索路径；
   Windows 常见位置是 LMS 安装目录下的 `server\Plugins`（旧版 Squeezebox Server
   可能是 `C:\Program Files (x86)\Squeezebox\server\Plugins`），Lyrion 9 的
   安装目录通常位于 `C:\Program Files\Lyrion\Music Server` 附近。
   `C:\ProgramData\...\Cache\InstalledPlugins\Plugins` 是插件管理器缓存目录，
   手工放进去可能被 LMS 清理，不建议作为长期位置。
2. 把本仓库的 `Plugins\NetEase` 整个目录复制到上述 `Plugins` 目录，最终应得到：

   ```text
   <LMS Plugins>/NetEase/install.xml
   <LMS Plugins>/NetEase/Plugin.pm
   ...
   ```

3. 重启 LMS（Windows 服务/托盘程序均可）。
4. 打开 LMS Web 界面：`设置 → 插件`，应能看到 **NetEase Cloud Music**，
   状态为 enabled；如果没有，先点“刷新/重新扫描插件”，再检查 `server.log`
   中是否有 `netease` 相关报错。

#### Docker（lmscommunity/lyrionmusicserver 镜像）

LMS 没有“上传插件”的 Web 界面；Docker 安装时把插件放进容器内
`/config/cache/Plugins/NetEase/` 即可（该目录在 `/config` 持久化卷里，
重建容器后仍保留）。两种做法任选其一：

1. 复制到宿主机映射目录：找到 compose 中 `-v xxx:/config` 的宿主机路径
   （或 `docker inspect <容器> | grep -A5 Mounts`），把本仓库的
   `Plugins\NetEase` 复制成 `<宿主机config目录>\cache\Plugins\NetEase\`；
2. 直接拷进运行中的容器（写入挂载卷，效果相同）：

   ```powershell
   docker cp .\Plugins\NetEase <lms容器名>:/config/cache/Plugins/
   ```

然后 `docker restart <lms容器名>`，按上面第 4 步检查插件是否出现。

Docker 下还有两个配置要改：

- **API 后端地址**：容器内的 `127.0.0.1` 指容器自己。推荐把 NeteaseCloudMusicApi
  Enhanced 也跑成容器并与 LMS 同一 network，官方镜像为 `moefurina/ncm-api:latest`
  （默认端口 `3000`），设置页把 `API base URL` 改成 `http://<服务名或IP>:3000`；
  或让 API 监听宿主机后使用宿主机 IP。compose 参考：

  ```yaml
  services:
    lms:
      # image: lmscommunity/lyrionmusicserver ...
    ncmapi:
      image: moefurina/ncm-api:latest
      restart: unless-stopped
      ports:
        # 用 NAS IP 访问时必须有这一行；LMS 与 ncmapi 已在同一 network 并直接用服务名时可省略
        - "3000:3000"
      environment:
        # 关闭“全局解灰”，只使用网易云官方音源，行为与原版一致
        # 想尽量让 VIP/试听/无地址歌曲可播，可改成 "true"（音源来自第三方）
        ENABLE_GENERAL_UNBLOCK: "false"
  ```

  此时 `API base URL` 填 `http://ncmapi:3000`（跨网络访问则填 `http://192.168.2.151:3000`）。
  **前提**：LMS 与 API 必须加入同一个 Docker 网络，容器内能解析该服务名；否则请直接填
  NAS 的局域网 IP。排查命令：`docker exec <lms容器> getent hosts ncmapi`。

- **下载目录**：留空会自动落到“第一个音乐库文件夹/NetEase”（例如 `/music/NetEase`，
  对应宿主机 `/music` 映射处）。设置页会列出当前音乐库目录及其一级子目录，可直接下拉选择，
  输入框也支持 LMS 的路径自动补全；仍可手动填写任意绝对路径。

#### 通过第三方插件库安装（可选）

`dist/` 下已生成可直接托管的文件：

- `NetEase-0.1.27.zip`：插件包，解压后顶层为 `NetEase/`；
- `repo.xml`：LMS 第三方插件库描述，已填入 zip 的 SHA1 和下载 URL。

用法：

1. 把 `dist/` 放到任意 HTTP 静态服务器上（LMS 不支持 `file://`）。例如在 NAS/宿主机：
   `python -m http.server 8000`，或把目录交给 nginx。
2. 确认 `repo.xml` 里的 `url` 是 LMS 容器能访问到的地址（示例为
   `http://192.168.2.100:8080/NetEase-0.1.27.zip`）；若端口/IP 不同，改这一行后
   无需重新算 SHA1。
3. LMS → 设置 → 插件 → 第三方插件库，填仓库描述文件的实际 URL，例如
   `http://192.168.2.100:8080/repo.xml`；
4. 勾选底部的 **“使用不受支持的扩展”**，保存并刷新插件列表；
5. 在列表中找到 **NetEase Cloud Music** 并安装，然后重启 LMS。

更新插件时，重新打包 zip，并同步修改 `repo.xml` 中的 `version`、`sha`、`url`。

### 4.2 启动 NeteaseCloudMusicApi（使用默认后端时必需）

推荐用 Enhanced 维护版；原版 `NeteaseCloudMusicApi` 也仍然兼容，任选其一。

方式一（Enhanced，推荐，要求 Node.js 22+）：

```powershell
npm install -g @neteasecloudmusicapienhanced/api
api
```

方式二（原版，Node.js 14+）：

```powershell
npm install -g NeteaseCloudMusicApi@4.32.0
NeteaseCloudMusicApi
```

方式三（源码/本地安装）：

```powershell
npm install @neteasecloudmusicapienhanced/api
node .\node_modules\@neteasecloudmusicapienhanced\api\app.js
```

默认监听 `http://127.0.0.1:3000`，可用环境变量 `PORT` 改端口。验证：

```powershell
Invoke-WebRequest -UseBasicParsing http://127.0.0.1:3000/login/status
```

返回 JSON（未登录时 `data.profile` 为 `null`）即表示服务正常。

然后在插件设置页把 `API base URL` 设为 `http://127.0.0.1:3000`（末尾不要加 `/`）。

> 如果 LMS 与 API 服务不在同一台机器，请把地址改成实际地址，并确保网络可达。
> 不建议把无鉴权的 API 服务直接暴露到公网。

### 4.3 Perl 模块依赖

插件只使用 LMS 自带或 Perl 核心模块：

| 模块 | 用途 | 说明 |
| --- | --- | --- |
| `JSON::XS` | 解析接口 JSON | LMS 自带 |
| `URI::Escape` | URL 参数编码 | Perl 核心 |
| `Slim::Networking::SimpleAsyncHTTP` | 异步请求/下载 | LMS 自带 |
| `LWP::UserAgent` | 设置页登录/验证的同步请求 | LMS 通常自带；缺失时自动退回 `HTTP::Tiny` |
| `HTTP::Tiny` | 同步请求兜底 | Perl 核心（>=5.14） |
| `IO::Socket::SSL` | 访问 https（直连模式/封面） | LMS 自带 |

如果 `server.log` 出现 `Can't locate ... in @INC`，说明该 LMS 构建缺少对应模块，
请安装到 LMS 使用的 Perl 环境，或优先使用 API 后端 + 本机 HTTP 接口。

---

## 5. 登录步骤

打开 `设置 → 插件 → NetEase Cloud Music → Settings`。

### 5.1 手机号 + 密码（仅 API 后端）

1. `Backend` 保持 `NeteaseCloudMusicApi`。
2. 填写手机号和密码，点“手机号 + 密码登录”。
3. 登录成功后 Cookie、UID、昵称会写入插件 prefs；密码只在本次请求中使用，
   **不会保存，也不会写入日志**。
4. 如果返回“检测到当前登录存在安全风险”等风控错误，说明网易云拒绝了服务器 IP 的
   密码登录，请改用 **5.2 扫码登录** 或 5.3 Cookie。

### 5.2 扫码登录（仅 API 后端，推荐）

1. `Backend` 保持 `NeteaseCloudMusicApi`。
2. 点“生成二维码”，页面会显示二维码图片。
3. 用网易云音乐 App 扫码，并在手机上确认登录。
4. 回到设置页点“我已扫码”：
   - 已确认：Cookie、UID、昵称写入 prefs，显示登录成功；
   - 已扫码未确认：再点一次；
   - 过期：重新生成二维码。
5. 二维码只用于本次登录，成功后插件会清除本地保存的二维码和 key。

扫码登录不经过密码校验，通常不受“密码登录存在安全风险”的风控影响；但服务器 IP
被网易云整体封禁时仍可能失败，此时请用 Cookie。

如果扫码后手机提示“当前设备环境异常，本次操作已拦截”，先用新版 Enhanced 后端
（`moefurina/ncm-api:latest`）重试；旧版 Binaryify API（Docker 镜像里的 4.27.0）
更容易触发该拦截。仍然失败时：

1. 设置页的 **“发送给网易云的公网 IP”** 填家庭宽带公网 IP（在路由器管理页或
   `whatismyip` 类网站查看），保存后重新生成二维码再扫；
2. 仍失败就改用 Cookie 登录——Cookie 只用于校验账号和取数据，不再经过登录风控。

公网 IP 是动态分配时，变化后需要更新这一项。

### 5.3 手动粘贴 Cookie（两种后端都可用）

1. 浏览器登录 `https://music.163.com`。
2. 打开开发者工具 → Application/存储 → Cookies → `https://music.163.com`，
   **点中 `MUSIC_U` 那一行，只复制 Value 列**。更稳妥的做法是 Network 面板里
   任选一个 `music.163.com` 请求，复制完整请求头 `Cookie`（带 `name=value`）。
3. 粘贴到设置页 `Cookie` 输入框，写成 `MUSIC_U=...`；只粘贴值也可以，多行粘贴
   时插件会把每个值依次当作 `MUSIC_U` 尝试。
4. API 后端：点“验证 Cookie / 账号”，插件会调用 `/login/status` 自动填入 UID/昵称。
   只有验证成功（拿到账号 UID）后，状态才显示“已登录”；验证失败会显示“未登录”，
   但刚粘贴的 Cookie 仍会保留，方便修正后重试。
5. 直连后端：必须手动填写 `User ID`（网易云个人主页 URL 中的数字 ID），
   再点“验证”。

> Cookie 等同于账号密码，请勿截图、粘贴到公开位置或提交到仓库。
> 插件日志不会打印 Cookie；如果怀疑泄露，请在网易云网页端退出登录使 Cookie 失效。

### 5.4 退出登录

设置页点“退出登录”：清除本地 Cookie、UID、昵称；API 后端还会调用 `/logout`。
这不会删除你在网易云账号里的任何数据。

---

## 6. 浏览与播放

### 6.1 浏览

- Web 界面：`我的应用 → 网易云音乐`；
- 顶层菜单：
  - 已登录：`每日推荐`、`我喜欢的音乐`、`推荐新歌`、`搜索歌曲`、`我的歌单`、`下载`；
  - 未登录：`推荐新歌`、`搜索歌曲`（`每日推荐`/`我喜欢的音乐`/`我的歌单`/`下载` 需要登录，
    未登录时不显示）；
- 层级：`网易云音乐 → 我的歌单 → 歌单 → 曲目`；
- 歌单项显示 `歌单名（N 首）`，封面取 `coverImgUrl`；
- 曲目显示 `歌手 - 歌名`。

`搜索歌曲` 使用 LMS 的搜索输入框，结果取 `/cloudsearch` 前 30 条。

`每日推荐`、`我喜欢的音乐`、`推荐新歌`、`搜索歌曲` 在直连模式下会提示
“该功能仅 API 后端支持”（直连模式只保留歌单浏览；红心歌曲会退化为
从歌单列表里定位 `specialType == 5` 的歌单）。

插件会对不超过 300 首的歌单/曲目列表预解析播放地址：

- 有 URL：显示为可播放曲目，点击即播放；
- 只有试听片段：标题后加 `[试听]`；
- 无 URL：显示为文本项，并给出原因（VIP/版权/Cookie 失效等）。

超过 300 首的歌单跳过预检查，所有曲目都可点击；真正播放时再由
`ProtocolHandler` 解析，拿不到 URL 会在日志中记录原因并停止播放。

### 6.2 播放链路

1. 菜单项 URL 为 `netease://track/<songId>`；
2. `Plugins::NetEase::ProtocolHandler` 注册 `netease` 协议；
3. 播放前调用 `Plugins::NetEase::API->getSongUrl()` 获取真实音频 URL；
4. 真实 URL 统一转成 `https://`，交给 LMS 的
   `Slim::Player::Protocols::HTTPS::scanUrl()`；
5. 扫描成功后把真实 URL 写入 `$song->streamUrl()`，LMS 的 HTTP/HTTPS
   处理器负责实际流式传输、Range/seek、重定向；
6. 播放地址缓存 5 分钟；失效后下一次播放会重新解析。

元数据（标题、歌手、专辑、封面、时长）在浏览时写入 LMS 缓存（24 小时），
`getMetadataFor` 会返回这些信息。封面 URL 同样统一为 `https://`。

### 6.3 音质

设置页 `Streaming quality` 可选：

- `standard`（128k 左右）
- `higher`（192k 左右）
- `exhigh`（320k 左右）
- `lossless`（无损，通常需要 VIP）

实际音质以接口返回为准；VIP/版权/地区限制可能导致降级、只返回试听片段或
完全不返回 URL。

---

## 7. 下载

### 7.1 触发方式

1. **浏览菜单**：`网易云音乐 → 下载` → 选择歌单 → 页面第一项是“下载此歌单”，
   其后每首曲目各占一项（`下载：歌手 - 歌名`），点哪首就只下哪首。
2. **歌单浏览页**：进入 `我的歌单 → 某个歌单`，最后一项也是“下载此歌单”。
3. **CLI / JSON-RPC**：

   ```powershell
   # CLI（LMS 命令行接口，默认 telnet 9090）
   netease download playlist 123456
   netease download track 347230
   ```

   ```powershell
   # JSON-RPC（LMS Web 端口，默认 9000）
   curl.exe "http://127.0.0.1:9000/jsonrpc.js" `
     --data '{"id":1,"method":"netease","params":["download","playlist","123456"]}'
   ```

   下载是异步的，命令只负责入队；进度看下载队列监控页（`设置 → 插件 → 下载队列`）
   或 LMS 日志（日志分类 `plugin.netease`）。仍保留 `netease download all` 作为
   CLI 的批量入口，但浏览菜单里不再提供“一键下载全部”的按钮。

### 7.2 下载队列监控页

入口：`设置 → 插件 → 下载队列`，或插件设置页顶部的“下载队列”链接。

- **下载目录检查**：显示插件实际写入的绝对路径、**真实写入测试**结果（不是只看权限位）、
  目录属主/权限，以及 LMS 进程的运行身份（uid/euid）。"下载完全没反应"先看这里：
  - 路径不存在且无法创建 → 说明配置文件里填的是宿主机路径、容器内没有这个路径；
  - 属主/权限显示 `root:root 0755` 而 LMS 以非 root 运行 → 需要给 LMS 用户写权限；
  - 权限位显示可写但写入测试失败 → 只读挂载、ACL 或 NAS 的 root-squash；
  - 以 root 手工 `touch` 能写 **不能**说明 LMS 能写，二者 uid 可能不同；
- **正在下载**：当前任务的进度（已处理/总数）、已存/跳过/失败计数、当前曲目和
  最近的错误信息（如解析不到播放地址、目录不可写、HTTP 失败）；
- **排队中**：待执行的任务，可单独取消；
- **历史任务**：最近 30 条已结束任务的最终状态（完成/失败/已取消）和错误摘要，
  可一键清空；
- 有任务在运行或排队时页面每 4 秒自动刷新；取消运行中的任务会在当前文件下载
  完成后停止（不会立刻中断正在写入的文件）。

### 7.3 目录与命名

- 下载根目录：设置页 `Download directory`；可下拉选择、自动补全或手动填写绝对路径；
- 留空时：使用 LMS 音乐库第一个目录下的 `NetEase` 子目录；
- 两者都没有时：下载不可用，设置页会提示；
- 每个歌单一个子目录：`<根目录>/<歌单名>/`；
- 单曲命令下载到 `<根目录>/Singles/`；
- 文件名：`歌手 - 歌名 [songId].扩展名`；
- 非法字符 `\ / : * ? " < > |` 替换为 `_`，控制字符删除，最长 120 字符；
- 扩展名从 URL 推断（mp3/flac/m4a/aac/wav/ogg/opus），无法判断时用 `mp3`。

### 7.4 跳过、重试、权限

- 目标文件已存在且非空：直接跳过（日志 `already exists, skipped`）。
- 先写 `<文件名>.part`，成功后再 `rename`，避免中断留下半个正式文件。
- 下载失败最多重试 3 次，间隔约 5 秒、10 秒；重试用的是同一个 URL，
  如果 URL 已过期会最终失败（日志会记录）。
- 下载任务串行执行，避免一次打满带宽。
- **只下载有完整播放权限的曲目**：`freeTrialInfo` 非空的试听片段会跳过，
  避免保存 45 秒残片。
- 下载音质由 `Download quality` 决定，和播放一样受账号 VIP/版权/地区限制；
  无损通常需要 VIP，普通账号可能只能拿到标准/较高音质。
- 下载完成后不会自动加入 LMS 音乐库；需要把目录加入音乐库并触发扫描。

---

## 8. 凭据安全

- Cookie、UID、昵称、下载目录、音质等保存在 LMS 插件 prefs（`plugin.netease`）；
  LMS prefs 文件的权限由 LMS 安装方式决定，请确保运行 LMS 的系统账号可信。
- 密码只作为一次 HTTP 请求参数传给 API 后端，不写入 prefs，不写入日志；
  设置页处理完即从内存参数中删除。
- 日志中不会打印 Cookie，也不会打印带签名的播放 URL；下载日志只记录本地路径。
  错误信息会经过截断/去标签处理。
- API 后端若通过非本机地址访问，建议使用 HTTPS 反向代理并加认证，
  否则等同于把网易云账号操作权限暴露给网络。

---

## 9. 已验证 / 未验证

### 已验证（本机可执行的部分）

| 项目 | 方法 | 结果 |
| --- | --- | --- |
| `install.xml` 结构 | PowerShell `[xml]` 解析，检查 `module`/`minVersion` | 通过 |
| Perl 语法 | 在临时目录建立 LMS 依赖 stub，`perl -c` 编译 6 个 `.pm` | 6 个文件均 `syntax OK` |
| 纯函数逻辑 | 文件名清洗、扩展名推断、码率映射、不可播原因、歌手拼接、封面/音频 https | 14 项检查全部通过 |
| 下载目录候选（0.1.10） | 用临时 prefs stub 指向本机目录，调用 `Downloader->listDirs` | 返回当前目录及其一级子目录，自动去重，上限 40 项 |
| 登录验证码（0.1.11） | mock `/login/cellphone` 返回 `{code:200,img}` 等场景，调用 `loginCellphoneSync` | 成功/验证码挑战/普通错误/非法号码 5 个分支全部正确返回 |
| 下载队列状态机（0.1.12） | 直接驱动 `Downloader` 的入队/完成/取消/崩溃路径，检查 `queueStatus`/`cancelJob`/`clearHistory` | 进度计数、状态流转（done/error/cancelled）、错误上限、快照无闭包等 28 项检查全部通过 |
| 下载目录诊断（0.1.13） | 用可写目录、不存在的目录、父路径是普通文件、未配置目录四种情况调用 `checkDownloadDir` | 真实写入测试、自动创建、属主/权限读取、探针文件清理等 13 项通过 |
| 个性化入口逻辑（0.1.14） | 用可替换的 `_async` mock `/recommend/songs`、`/likelist`、`/song/detail`、`/personalized/newsong`、`/cloudsearch`、`/api/user/playlist` | 曲目归一化、红心 1000 首截断、未登录/直连哨兵、直连红心定位、`specialType` 保留等 26 项通过 |
| 音质自动降级（0.1.15） | 用 mock 的 `_async` 模拟“无损无权限、极高可用”“全等级都锁定”“首档即可用”三种返回 | 降级顺序、按批只补未拿到地址的歌曲、四级全试后保留 `vip` 原因、多批（150 首）等 18 项通过 |
| 红心分页（0.1.20） | 用 mock 的 `getLikedSongIds`/`getLikedSongs`/`getSongUrls` 驱动 `likedFeed`/`likedPageFeed`，并单独验证 API 切片 | 1200 首拆成 4 页、250 首不分页、末页不足一页、越界 offset、省略 limit 时不截断等 24 项通过 |
| 歌单分页（0.1.21） | 用 mock 的 `_async` 驱动 `getPlaylistTracks`/`getAllPlaylistTracks`，用 mock 的 `getUserPlaylists`/`getPlaylistTracks` 驱动 `playlistsFeed`/`playlistFeed`/`playlistPageFeed` | 2500 首拆成 3 页、整单下载逐页拉全量、第二页失败返回部分、1000 首不分页、分页 offset/limit 透传等 38 项通过 |
| NeteaseCloudMusicApi 接口 | 本地安装 `NeteaseCloudMusicApi@4.32.0` 并启动，实测 `/song/detail`、`/song/url/v1`、`/playlist/track/all`、`/playlist/detail`、`/user/playlist`、`/login/status` | 返回结构与插件解析一致 |
| Enhanced 版兼容性 | 本地安装 `@neteasecloudmusicapienhanced/api@4.41.1` 并启动，实测 `/login/status`、`/song/url/v1`、`/user/playlist`；并用插件 `loginStatusSync` 直接调用 | 接口路径/返回结构一致；未登录（匿名 account）正确判定为 `not logged in` |
| 扫码登录（真实环境） | NAS 上运行 `moefurina/ncm-api:latest`（Enhanced）后，用户在插件设置页生成二维码并扫码确认 | 通过；旧版 Docker 镜像的 Binaryify 4.27.0 会提示“当前设备环境异常” |
| 直连接口 | 实测 `/api/song/detail`、`/api/v6/playlist/detail`、`/api/user/playlist` | 可返回数据；`/api/song/enhance/player/url` 未登录返回 `code=-110`，符合预期 |
| 音频 URL 可达性 | 取一条公开歌曲 URL，分别用 http/https HEAD | 均返回 200、`audio/mpeg`，说明 https 化可行 |
| 设置页/模板渲染 | 仅静态编写，未在 LMS 中渲染 | 未验证 |

> 说明：`perl -c` 使用的是临时 stub，不是真实 LMS 运行环境。它能发现明显的
> 语法错误，但不能证明所有 LMS API 在 8.x/9.x 的实际签名完全一致。

### 未验证（需要真实环境/凭据）

| 项目 | 原因 | 如何验证 |
| --- | --- | --- |
| LMS 真实加载插件 | 本机未安装 LMS 实例 | 按第 4 节安装，查看“设置 → 插件”是否出现，检查 `server.log` |
| 设置页实际渲染/保存 | 需要 LMS Web 运行时 | 打开 Settings，保存各项；确认无模板报错、prefs 生效 |
| 手机号+密码真实登录 | 需要真实账号，可能触发验证码 | 在设置页登录，观察是否返回 Cookie/UID |
| Cookie 登录/持久化/退出 | 需要真实 Cookie | 粘贴 Cookie 后重启 LMS，确认仍显示已登录；点退出后确认清除 |
| 真实歌单浏览 | 需要登录后的账号 | 进入 `我的歌单`，核对名称/封面/曲目数 |
| 搜索入口（OPML `type => 'search'`） | 菜单渲染需要真实 LMS | 点“搜索歌曲”，确认出现输入框；输入歌手/歌名后应有结果 |
| 每日推荐/红心/新歌入口 | 需要真实账号与 API 后端 | 在菜单中逐一打开，核对曲目与在线播放 |
| 真实在线播放 | 需要 LMS + 播放器/软件播放器 | 点击曲目，确认 `now playing` 进度、暂停、seek、切歌 |
| 真实下载 | 需要可播放且非试听的曲目 | 触发“下载此歌单”，检查目录、命名、跳过、日志 |
| 直连模式真实播放 | 需要有效 Cookie/UID | 切换 `direct`，验证歌单和播放；失败则回退 API 后端 |
| `HTTP::Tiny` 兜底路径 | 本机 Perl 有 LWP，未触发兜底分支 | 临时改名/屏蔽 LWP 后，在设置页做一次登录/验证 |
| LMS 8.x 兼容性 | 未在 8.x 实例运行 | 在 LMS 8.5 上重复安装/浏览/播放测试 |

### 建议的验证步骤

1. 安装 LMS 9.x（Windows），按第 4.1 节放插件并重启。
2. 启动 API 后端，`/login/status` 自检通过。
3. 设置页选 `NeteaseCloudMusicApi`，用手机号+密码或 Cookie 登录。
4. 浏览 `我的歌单`，检查封面和曲目数；播放一首非 VIP 曲目，测试暂停/seek。
5. 打开设置页，在“下载目录”下拉框里选一个目录，并在输入框里输入路径前缀，确认出现 LMS 的路径自动补全；保存后确认 prefs 生效。
6. 浏览 `网易云音乐 → 下载 → 某个歌单`，先点一首单曲，确认只下载这一首；再点“下载此歌单”，检查文件命名、`.part`、跳过和日志。
7. 用 CLI `netease download track <id>` 再跑一次，确认已存在文件被跳过。
8. 如果需要测试直连模式，准备好 Cookie+UID 后切换，重复 4、5 步。

---

## 10. 已知限制与排错

- **插件设置页不出现**：确认目录层级是 `<Plugins>/NetEase/install.xml`，不是
  `<Plugins>/NetEase/Plugins/NetEase/...`；确认 LMS 已重启；查 `server.log`
  中是否有 `Plugins::NetEase` 的编译错误。
- **提示未登录/UID 缺失**：API 后端请点“验证 Cookie / 账号”让插件写入 UID；
  直连模式必须手动填写数字 UID。
- **歌单为空**：API 后端可能未登录或 Cookie 已失效；直连模式可能被风控。
- **曲目显示不可播放**：看括号里的原因；VIP/版权/地区限制是网易云侧限制，
  插件无法绕过。若全部显示 `Cookie 失效/未登录`，重新登录。
- **能浏览但播放失败**：查日志 `plugin.netease`，确认是否拿到 URL；
  部分歌曲 URL 可能要求特定 Referer 或已过期，重新播放会重新解析。
- **下载失败/没反应**：先打开 `设置 → 插件 → 下载队列`，看“下载目录检查”：
  路径、真实写入测试结果、目录属主/权限、LMS 进程 uid 都会显示。注意用 root
  在宿主机 `touch` 成功不代表 LMS 能写；容器内 uid 通常不是 root，还可能是只读挂载
  或 NAS 的 root-squash。修复后任务的“信息”列会给出失败原因。
- **封面不显示**：LMS 需要能访问 `https://p*.music.126.net`；代理/防火墙可能拦截。
- **API 后端 3000 端口被占用**：用环境变量 `PORT` 改端口，并同步修改插件
  `API base URL`。
- **手机号登录要求验证码**：0.1.11 起设置页会显示验证码图片，输入图中字符后再次
  点击登录即可；仍失败时改用扫码或 Cookie 登录。

---

## 11. 后续建议

1. 在 LMS 9.x 与 8.5 实机上做一次完整回归，重点验证 `Settings.pm` 的
   `SUPER::handler` 保存流程和 `ProtocolHandler` 的 seek 行为。
2. 增加扫码登录（轮询 `/login/qr/check`），减少密码/验证码依赖。
3. 增加专辑、歌手、私人 FM；给“我喜欢的音乐”加“喜欢/取消喜欢”写操作。
4. 下载完成后可选调用 LMS 的库扫描接口，或写入 `.m3u` 播放列表。
5. 为下载器增加“URL 过期后重新解析”的重试路径，而不是复用旧 URL。
6. 如果直连模式长期不可用，考虑只保留 API 后端，减少维护面。
