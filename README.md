# jmdownloader-docker

把 [JJrexWang/jmdownloader-enhance](https://github.com/JJrexWang/jmdownloader-enhance) 的 headless HTTP server + WebUI 打包成 Docker 镜像。**不修改上游代码**：上游以 git submodule 形式固定在 `upstream/`（当前 `805fb60`）。

镜像：`ghcr.io/jjrexwang/jmdownloader-docker`（linux/amd64 + linux/arm64，公开可直接拉）

| tag | 含义 |
|---|---|
| `latest` | main 分支最新构建 |
| `sha-<7位>` | 本仓库某个 commit |
| `upstream-<7位>` | 对应的上游 commit |

## 快速开始

```bash
git clone https://github.com/JJrexWang/jmdownloader-docker && cd jmdownloader-docker
cp .env.example .env      # 按需修改端口、目录、账号、Basic Auth
docker compose pull && docker compose up -d
```

浏览器打开 `http://<主机>:1180`。不用 compose：

```bash
docker run -d --name jmdownloader -p 1180:8080 \
  -v ./config:/config -v ./downloads:/downloads \
  -e AUTH_USER=admin -e AUTH_PASSWORD=换成你的密码 \
  ghcr.io/jjrexwang/jmdownloader-docker:latest
```

## 环境变量

| 变量 | 默认 | 说明 |
|---|---|---|
| `AUTH_USER` / `AUTH_PASSWORD` | 空 | 都填则开启 Basic Auth（`/health` 除外）。**暴露到公网务必开启** |
| `JM_USERNAME` / `JM_PASSWORD` | 空 | 启动时自动登录 JM；也可在 WebUI 登录 |
| `PUID` / `PGID` | 空（自动推断，回退 10001） | 容器内运行用户；留空则从下载目录已有文件的属主自动推断，显式设置优先 |
| `TZ` | Asia/Shanghai（compose） | 时区 |
| `RUST_LOG` | info | 日志级别 |

卷：`/config`（config.json、cookies、日志）、`/downloads`（下载目录）。首次启动时如果没有 `config.json`，会自动写入 `downloadDir=/downloads`、`exportDir=/downloads/_export`；已有配置不会被改动。

## 架构

容器内：`tini` → `entrypoint.sh` →（降权到 PUID）`server`（127.0.0.1 内部端口 18080）+ `caddy`（对外 8080，可选 Basic Auth，SSE 不缓冲）。任一进程退出容器即退出，交给 `restart` 策略。HEALTHCHECK 用 `curl /health`。

## 故障排除

### 飞牛OS / NAS：日志大量 `Permission denied (os error 13)`，库存页为空

**新版已自动处理**：`PUID`/`PGID` 留空（默认）时，entrypoint 启动时会从下载目录**已有文件的属主自动推断运行用户**——把下载目录指向飞牛上的已有漫画库，无需手动查 uid，开箱即用；新下载的文件属主就是库文件的主人，在飞牛文件管理里可直接管理。

如果仍报权限错误（例如库内文件属主混杂、或之前用 root 跑过导致部分文件归 root），启动日志开头会有 `ERROR` 并给出指引。手动覆盖（二选一）：

1. `.env` 里显式设置（显式配置优先于自动推断）：
   ```env
   PUID=1000
   PGID=1000
   ```
   ```bash
   ls -n /你的/下载目录 | head -3   # 在飞牛终端/SSH 里执行，看第 3、4 列数字
   docker compose up -d
   ```

2. 在 NAS/宿主机上把目录属主统一改掉（会改变宿主机文件属主）：
   ```bash
   chown -R 10001:10001 /你的/下载目录
   ```

## 更新上游

```bash
git submodule update --remote upstream && git commit -am "bump upstream" && git push
```

推送后 GitHub Actions 会在 amd64/arm64 原生 runner 上分别构建、跑冒烟测试（`scripts/smoke-test.sh`），再合并多架构清单推到 GHCR。每周日也会自动重建一次。

## 本地构建

```bash
git clone --recursive https://github.com/JJrexWang/jmdownloader-docker && cd jmdownloader-docker
docker build -t jmd:dev . && ./scripts/smoke-test.sh jmd:dev
```

