# jmdownloader-docker

把 [JJrexWang/jmdownloader-enhance](https://github.com/JJrexWang/jmdownloader-enhance) 的 headless HTTP server + WebUI 打包成 Docker 镜像，开箱即用。

**镜像**：`ghcr.io/jjrexwang/jmdownloader-docker`（linux/amd64 + linux/arm64，公开可直接拉）

| tag | 含义 |
|---|---|
| `latest` | main 分支最新构建（稳定版见 [Releases](https://github.com/JJrexWang/jmdownloader-docker/releases)） |
| `sha-<7位>` | 本仓库某个 commit 的构建 |
| `upstream-<7位>` | 对应上游 commit 的构建 |

## 快速开始

```bash
# 1. 拿 compose 模板和环境变量示例
curl -O https://raw.githubusercontent.com/JJrexWang/jmdownloader-docker/main/docker-compose.yml
curl -O https://raw.githubusercontent.com/JJrexWang/jmdownloader-docker/main/.env.example
cp .env.example .env   # 按需修改端口、目录、账号

# 2. 启动
docker compose pull && docker compose up -d

# 3. 浏览器打开 http://<主机IP>:1180
```

也可以直接 `docker run`：

```bash
docker run -d --name jmdownloader -p 1180:8080 \
  -v ./config:/config -v ./downloads:/downloads \
  -e AUTH_USER=admin -e AUTH_PASSWORD=换成你的密码 \
  ghcr.io/jjrexwang/jmdownloader-docker:latest
```

## 功能

- **WebUI**：搜索、收藏夹（含翻页 + 指定页跳转）、每周必看、本地库存管理
- **任务中心**（顶部导航）：更新库存的状态/进度条/失败列表、新建任务数、起止时间；下载队列每个任务的实时进度。状态保存在服务端，**刷新页面不丢失**
- **更新库存**：对每本已下载漫画调 JM API 拉最新章节，有新章节自动创建下载任务补齐
- **飞牛/NAS 自动适配**：`PUID`/`PGID` 留空时，entrypoint 从下载目录已有文件的属主自动推断运行用户，指向已有漫画库开箱即用，无需手动查 uid

## 环境变量（.env）

| 变量 | 默认 | 说明 |
|---|---|---|
| `IMAGE` | `ghcr.io/jjrexwang/jmdownloader-docker:latest` | 镜像地址；想锁定版本可改为具体 tag |
| `HOST_PORT` | `1180` | 宿主机端口 → 容器 8080 |
| `CONFIG_PATH` | `./config` | 宿主机配置目录 → `/config`（config.json、cookies、日志） |
| `DOWNLOADS_PATH` | `./downloads` | 宿主机下载目录 → `/downloads` |
| `PUID` / `PGID` | 空（自动推断，回退 10001） | 容器内运行用户；留空推荐，显式设置优先 |
| `JM_USERNAME` / `JM_PASSWORD` | 空 | 填了则启动时自动登录 JM；也可之后在 WebUI 登录 |
| `AUTH_USER` / `AUTH_PASSWORD` | 空 | 都填则开启 WebUI Basic Auth（`/health` 除外）。**暴露到公网务必开启** |
| `TZ` | `Asia/Shanghai` | 时区 |
| `RUST_LOG` | `info` | 日志级别 |

## 架构

容器内：`tini` → `entrypoint.sh` →（降权到 PUID）`server`（127.0.0.1 内部端口 18080）+ `caddy`（对外 8080，可选 Basic Auth，SSE 不缓冲）。任一进程退出容器即退出，交给 `restart` 策略。HEALTHCHECK 用 `curl /health`。

上游代码通过 Dockerfile 的 `UPSTREAM_SHA` 参数以 tarball 形式拉取（见 Dockerfile 顶部注释）。跟进上游更新 = 只改 `UPSTREAM_SHA` 这一行并推送，CI 自动重建镜像。

## 故障排除

### 飞牛OS / NAS：日志大量 `Permission denied (os error 13)`，库存页为空

**新版已自动处理**：`PUID`/`PGID` 留空（默认）时，entrypoint 启动时会从下载目录**已有文件的属主自动推断运行用户**——把下载目录指向飞牛上的已有漫画库，无需手动查 uid，开箱即用；新下载的文件属主就是库文件的主人，在飞牛文件管理里可直接管理。

如果仍有问题，检查：
1. `.env` 里 `PUID`/`PGID` 是否留空（推荐）或与文件属主一致
2. 宿主机执行 `ls -n <下载目录>` 查看数字 uid/gid

### WebUI 登录 JM 失败（Cloudflare 520/522）

WebUI「配置」→「API 域名」切换线路（Domain1–Domain5），或稍后重试。某条线路偶发抽风是 JM 侧问题。

### 更新库存中途大量 403

JM 侧临时限流（按出口 IP）。等十几分钟再跑；或在 `/config/config.json` 里把 `updateDownloadedComicsIntervalSec` 设为 `2`（默认 0），降低请求频率。

## 版本

稳定版见 [Releases](https://github.com/JJrexWang/jmdownloader-docker/releases)。`latest` 始终指向最新构建。
