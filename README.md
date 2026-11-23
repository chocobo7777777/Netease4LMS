# NetEase Cloud Music plugin for Lyrion Music Server

这是一个用 Perl 编写的 Lyrion Music Server（LMS，原名 Logitech Media Server /
Squeezebox Server）插件，用于浏览网易云音乐账号下的歌单、在线播放歌曲，并把
歌单/单曲下载到本地。

插件目录名：`NetEase`，模块命名空间：`Plugins::NetEase::*`。

安装后 LMS 中的位置：`设置 → 插件 → NetEase Cloud Music`；浏览入口：
`我的应用 / My Apps → 网易云音乐`。

---

## 1. 功能特性

- **账号登录**：手机号 + 密码、扫码登录（需 API 后端），或手动粘贴 Cookie
  （两种后端均可）。登录状态保存在 LMS 插件 prefs（`plugin.netease`）中，
  支持一键退出登录。
- **歌单浏览**：`网易云音乐 → 我的歌单 → 歌单 → 曲目`，显示歌单名、封面、
  曲目数；歌单超过 1000 首时自动拆成每页 1000 首的分页入口，每页可整页播放。
- **个性化入口**（登录后）：`每日推荐`、`我喜欢的音乐`（红心歌曲；超过 300 首
  自动拆成多个分页入口，每页可整页播放），均以普通曲目菜单展示，可直接在线播放。
- **无需登录的入口**：`推荐新歌`（30 首）与 `搜索歌曲`（支持歌名/歌手名关键词，
  返回前 30 条结果）。
- **在线播放**：曲目以 `netease://track/<songId>` 进入 LMS 播放链路，播放前解析
  真实音频 URL 后交给 LMS 的 HTTPS 处理器，播放/暂停/seek/重定向复用 LMS 核心实现。
- **不可播放提示**：菜单会提前解析 URL；没有 URL 的曲目显示为不可播放文本项，
  并标注原因（VIP、版权/地区限制、仅可试听、Cookie 失效等）。
- **下载**：浏览菜单"下载 → 歌单 → 曲目"按需选择，可整张歌单下载，也可只下单曲；
  支持 CLI / JSON-RPC 触发。文件命名、目录结构、跳过已存在文件、临时文件、
  失败重试均已实现。
- **条目级下载动作**：歌单条目与曲目条目额外挂载了 LMS 条目动作
  （`jive.actions`），分别对应"下载此歌单"和"下载这首歌"，命令复用下面的
  `netease download playlist|track <id>`；每日推荐、我喜欢的音乐、推荐新歌这类
  **没有歌单 ID 的内置入口**同样挂载"下载此歌单"，命令为
  `netease download feed daily|liked|new`。是否能看到入口取决于客户端/皮肤是否
  渲染自定义条目动作，详见 7.1 与第 10 节。
- **下载队列监控页**：`设置 → 插件 → 下载队列` 实时显示当前任务进度
  （已处理/总数、已存/跳过/失败计数）、排队任务、最近 30 条历史及错误信息；
  支持取消排队/运行中的任务、清空历史，有任务活动时页面每 4 秒自动刷新。
- **网易云曲目"正在播放"页信息**：Material Skin、SqueezePlay 等客户端
  播放网易云曲目时，**歌词**、**艺术家简介**、**专辑介绍** 直接从网易云获取，
  替代 MAI（MusicArtistInfo）插件的维基百科/在线搜索链路，内容更准确且不再超时。
  所有非网易云曲目保持 MAI 原样工作。实现细节见 DEVELOP.md。

---

## 2. 目录结构

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

---

## 3. 后端

插件通过 HTTP 调用 NeteaseCloudMusicApi（推荐 Enhanced 版）完成网易云接口的
加密/签名、Cookie 管理和播放地址解析。这是唯一受支持的后端。

- 支持扫码登录（推荐）；
- 播放地址按 `standard/higher/exhigh/lossless` 请求音质；
- 歌单曲目分页拉取，不受单次 1000 首截断影响。

> Enhanced 版默认开启"全局解灰"（`ENABLE_GENERAL_UNBLOCK=true`），会用第三方
> 音源为 VIP/试听/无地址歌曲补播放地址。想只使用网易云官方音源，启动时设
> `ENABLE_GENERAL_UNBLOCK=false`。

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
   状态为 enabled；如果没有，先点"刷新/重新扫描插件"，再检查 `server.log`
   中是否有 `netease` 相关报错。

#### Docker（lmscommunity/lyrionmusicserver 镜像）

LMS 没有"上传插件"的 Web 界面；Docker 安装时把插件放进容器内
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
        # 关闭"全局解灰"，只使用网易云官方音源，行为与原版一致
        # 想尽量让 VIP/试听/无地址歌曲可播，可改成 "true"（音源来自第三方）
        ENABLE_GENERAL_UNBLOCK: "false"
  ```

  此时 `API base URL` 填 `http://ncmapi:3000`（跨网络访问则填 `http://192.168.2.151:3000`）。
  **前提**：LMS 与 API 必须加入同一个 Docker 网络，容器内能解析该服务名；否则请直接填
  NAS 的局域网 IP。排查命令：`docker exec <lms容器> getent hosts ncmapi`。

- **下载目录**：留空会自动落到"第一个音乐库文件夹/NetEase"（例如 `/music/NetEase`，
  对应宿主机 `/music` 映射处）。设置页会列出当前音乐库目录及其一级子目录，可直接下拉选择，
  输入框也支持 LMS 的路径自动补全；仍可手动填写任意绝对路径。

#### 通过第三方插件库安装（可选）

`dist/` 下已生成可直接托管的文件：

- `NetEase-0.1.38.zip`：插件包，解压后顶层为 `NetEase/`；
- `repo.xml`：LMS 第三方插件库描述，已填入 zip 的 SHA1 和下载 URL。

用法：

1. 把 `dist/` 放到任意 HTTP 静态服务器上（LMS 不支持 `file://`）。例如在 NAS/宿主机：
   `python -m http.server 8000`，或把目录交给 nginx。
2. 确认 `repo.xml` 里的 `url` 是 LMS 容器能访问到的地址（示例为
   `http://192.168.2.100:8080/NetEase-0.1.31.zip`）；若端口/IP 不同，改这一行后
   无需重新算 SHA1。
3. LMS → 设置 → 插件 → 第三方插件库，填仓库描述文件的实际 URL，例如
   `http://192.168.2.100:8080/repo.xml`；
4. 勾选底部的 **"使用不受支持的扩展"**，保存并刷新插件列表；
5. 在列表中找到 **NetEase Cloud Music** 并安装，然后重启 LMS。

更新插件时，重新打包 zip，并同步修改 `repo.xml` 中的 `version`、`sha`、`url`。

### 4.2 启动 NeteaseCloudMusicApi（必需）

推荐 Enhanced 维护版，两种方式任选：

**Docker（推荐）**：

```yaml
services:
  ncmapi:
    image: moefurina/ncm-api:latest
    restart: unless-stopped
    ports:
      - "3000:3000"
    environment:
      ENABLE_GENERAL_UNBLOCK: "false"  # 只使用网易云官方音源
```

**本机 Node.js（Node.js 22+）**：

```powershell
npm install -g @neteasecloudmusicapienhanced/api
api
```

默认监听 `http://127.0.0.1:3000`。验证：

```powershell
Invoke-WebRequest -UseBasicParsing http://127.0.0.1:3000/login/status
```

返回 JSON 即正常。插件设置页把 `API base URL` 设为该地址（末尾不要加 `/`）。

### 4.3 Perl 模块依赖

插件只用 LMS 自带和 Perl 核心模块（JSON::XS、URI::Escape、SimpleAsyncHTTP、
LWP::UserAgent / HTTP::Tiny），无需额外安装。

---

## 5. 登录

打开 `设置 → 插件 → NetEase Cloud Music → Settings`。

### 扫码登录（推荐）

1. 点"生成二维码"，页面显示二维码图片。
2. 用网易云音乐 App 扫码，手机上确认登录。
3. 回到设置页点"我已扫码"：Cookie、UID、昵称写入 prefs。

二维码只用于本次登录，成功后自动清除。密码登录会被网易云风控拒绝，
Cookie 登录操作性差，均不推荐。

如果扫码后手机提示"当前设备环境异常"：

1. 用新版 Enhanced 后端（`moefurina/ncm-api:latest`）；
2. 设置页的 **"发送给网易云的公网 IP"** 填家庭宽带公网 IP 后重新生成。

### 退出登录

设置页点"退出登录"：清除本地 Cookie、UID、昵称，API 后端还会调 `/logout`。
不会删除网易云账号数据。

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

插件会对不超过 300 首的歌单/曲目列表预解析播放地址：

- 有 URL：显示为可播放曲目，点击即播放；
- 只有试听片段：标题后加 `[试听]`；
- 无 URL：显示为文本项，并给出原因（VIP/版权/Cookie 失效等）。

超过 300 首的歌单跳过预检查，所有曲目都可点击；真正播放时再解析，
拿不到 URL 会在日志中记录原因并停止播放。

### 6.2 播放链路

1. 菜单项 URL 为 `netease://track/<songId>`；
2. 插件注册 `netease` 协议，播放前获取真实音频 URL；
3. 真实 URL 统一转成 `https://`，交给 LMS 的 HTTPS 处理器完成流式传输、
   Range/seek、重定向；
4. 播放地址缓存 5 分钟；失效后下一次播放会重新解析。

元数据（标题、歌手、专辑、封面、时长）在浏览时写入 LMS 缓存（24 小时）。
封面 URL 同样统一为 `https://`。

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

1. **浏览菜单**：`网易云音乐 → 下载` → 选择歌单 → 页面第一项是"下载此歌单"，
   其后每首曲目各占一项（`下载：歌手 - 歌名`），点哪首就只下哪首。
2. **歌单浏览页**：进入 `我的歌单 → 某个歌单`，最后一项也是"下载此歌单"。
3. **条目操作菜单（右键 / 长按 / 三点菜单）**：

   | 位置 | 菜单项 | 实际执行 |
   | --- | --- | --- |
   | 歌单列表（我的歌单、每日推荐、我喜欢的音乐、推荐新歌） | 下载此歌单 | `netease download playlist/feed <id>` |
   | 歌单内每首曲目 | 下载这首歌 | `netease download track <songId>` |
   | 歌单列表 | 存为本地歌单 | `netease savetolocal playlist/feed <id>` |

   > **注意**：LMS 默认网页皮肤和 Material Skin 都不渲染插件自定义条目动作
   > （框架限制，详见 DEVELOP.md），所以网页界面里稳定可用的入口是
   > `网易云音乐 → 下载` 子菜单，以及歌单页末尾的"下载此歌单"。
   > SqueezePlay / iPeng 这类基于 jive 的客户端会正常显示右键菜单。

4. **CLI / JSON-RPC**：

   ```powershell
   # CLI（LMS 命令行接口，默认 telnet 9090）
   netease download playlist 123456
   netease download track 347230
   netease download feed daily     # 每日推荐
   netease download feed liked     # 我喜欢的音乐
   netease download feed new       # 推荐新歌
   netease savetolocal playlist 123456   # 网易云歌单 → LMS 本地 playlist
   netease savetolocal feed daily
   netease lyrics 347230                 # 查歌词
   ```

   ```powershell
   # JSON-RPC（LMS Web 端口，默认 9000）
   curl.exe "http://127.0.0.1:9000/jsonrpc.js" `
     --data '{"id":1,"method":"netease","params":["download","playlist","123456"]}'
   ```

### 7.2 下载队列监控页

入口：`设置 → 插件 → 下载队列`，或插件设置页顶部的"下载队列"链接。

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
- 内置 feed 各一个子目录：`<根目录>/DailyRecommendations/`、
  `<根目录>/LikedSongs/`、`<根目录>/NewSongs/`；
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
- **只下载有完整播放权限的曲目**：试听片段会跳过，避免保存 45 秒残片。
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

## 9. 常见问题与排错

- **插件设置页不出现**：确认目录层级是 `<Plugins>/NetEase/install.xml`，不是
  `<Plugins>/NetEase/Plugins/NetEase/...`；确认 LMS 已重启；查 `server.log`
  中是否有 `Plugins::NetEase` 的编译错误。
- **提示未登录/UID 缺失**：API 后端请点"验证 Cookie / 账号"让插件写入 UID；
  直连模式必须手动填写数字 UID。
- **歌单为空**：API 后端可能未登录或 Cookie 已失效；直连模式可能被风控。
- **曲目显示不可播放**：看括号里的原因；VIP/版权/地区限制是网易云侧限制，
  插件无法绕过。若全部显示 `Cookie 失效/未登录`，重新登录。
- **能浏览但播放失败**：查日志 `plugin.netease`，确认是否拿到 URL；
  部分歌曲 URL 可能要求特定 Referer 或已过期，重新播放会重新解析。
- **下载失败/没反应**：先打开 `设置 → 插件 → 下载队列`，看"下载目录检查"：
  路径、真实写入测试结果、目录属主/权限、LMS 进程 uid 都会显示。注意用 root
  在宿主机 `touch` 成功不代表 LMS 能写；容器内 uid 通常不是 root，还可能是只读挂载
  或 NAS 的 root-squash。修复后任务的"信息"列会给出失败原因。
- **条目右键菜单里看不到"下载歌曲/下载歌单"**：动作已写入条目 `jive.actions`，
  但 LMS 默认网页皮肤和 Material Skin 都不渲染插件自定义条目动作（原因见 7.1）。
  网页界面请用 `我的歌单 → 歌单` 末尾的"下载此歌单"，或 `网易云音乐 → 下载` 子菜单；
  支持 jive 条目动作的控制器（SqueezePlay 等）会显示这两个菜单项。
- **封面不显示**：LMS 需要能访问 `https://p*.music.126.net`；代理/防火墙可能拦截。
- **API 后端 3000 端口被占用**：用环境变量 `PORT` 改端口，并同步修改插件
  `API base URL`。
- **手机号登录要求验证码**：设置页会显示验证码图片，输入图中字符后再次点击登录
  即可；仍失败时改用扫码或 Cookie 登录。
