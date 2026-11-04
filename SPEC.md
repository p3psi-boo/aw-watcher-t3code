# SPEC: aw-watcher-t3code

状态：v1.1（按已确认选项改用 Zig）
日期：2026-11-04

## 1. 背景与目标

`t3code`（`pingdotgg/t3code`）是支持 Web、Electron 桌面端与移动端跨端协同的多 Agent 编码编排平台。常规 ActivityWatch 窗口采集器（`aw-watcher-window`）在观测 `t3code` 时存在两项结构性盲区：

1. **桌面端标题恒定**：Electron 桌面端在 `apps/desktop/src/window/DesktopWindow.ts` 中拦截了 `page-title-updated` 事件并强制设回固定应用名（`window.setTitle(environment.displayName)`），窗口采集器无法提取当前工程（Project）、会话（Thread）或运行中的 Agent。
2. **多端控制与后台盲区**：用户常通过 Web、手机端或桌面端跨端驱动 Agent，同时多个 Agent 会话在后台自主运行（`autonomous`），窗口焦点无法反映真实的工程归属与后台并发产出。

`aw-watcher-t3code` 是面向 `t3code` 的独立只读守护采集器，架构与事件语义对齐 `p3psi-boo/aw-watcher-herdr`：

- 直接以只读模式读取 `~/.t3/userdata/` 下的运行态文件与 `statev2.sqlite` 数据库，绝不写入数据库或创建冗余鉴权会话。
- 将 `t3code` 的工程（Project）、会话（Thread）、Provider/Model 运行状态与人机交互模式（`supervised` / `autonomous` / `manual`）实时上报至 ActivityWatch 的单 Bucket `aw-watcher-t3code_<hostname>`。
- 输出兼容 ActivityWatch 既有 `[<project>]` 正则分类规则的 `title`，并提供 `--dry-run`、`doctor` 与 `service` 子命令及 Nix 静态二进制打包。

## 2. 范围边界（In / Out of Scope）

### 2.1 In Scope（本轮实现范围）

- 校验本机 `t3code` 服务进程存活状态（基于 `~/.t3/userdata/server-runtime.json` 的 `pid` 与 `kill(pid, 0)`）。
- 以只读模式（`mode=ro` + `PRAGMA query_only = ON`）查询 `~/.t3/userdata/statev2.sqlite` 中的工程、活跃会话、活跃 Agent Run 与待处理阻塞请求。
- 通过 Linux `inotify` / macOS `kqueue` 监听 `~/.t3/userdata/` 目录（捕获 `statev2.sqlite-wal`、`statev2.sqlite`、`server-runtime.json` 及 `logs/server.trace.ndjson` 变更），配合默认 `1s` 心跳 Ticker 实时推送状态。
- 推导当前焦点会话（`focused`）、活跃 Agent 列表（`agents`）、全局主导状态（`dominant_state`：`working` / `blocked` / `idle`）与人机协同模式（`interaction`：`supervised` / `autonomous` / `manual`）。
- 支持 ActivityWatch 离线自愈（重连后递增 `delivery_epoch` 并自动确保 Bucket 存在）。
- 提供 CLI 标志（`--base-dir`、`--aw-url`、`--heartbeat-interval`、`--pulsetime`、`--focus-window`、`--dry-run`、`--verbose`）及 `doctor`、`service`（systemd user service / launchd LaunchAgent）子命令。
- 提供 `flake.nix` 与独立 `default.nix` 打包定义。外部 Nix 配置集成可按需添加。

### 2.2 Out of Scope（非目标）

- 修改 `t3code` 上游或本地源码。
- 向 `~/.t3/userdata/statev2.sqlite` 写入任何数据，或调用 `t3 auth session issue` 签发持久 bot 会话。
- 采集对话正文、Prompt 内容、Token 消耗量或费用账单。
- 跨机器远程连接 `t3code` WebSocket（首版仅采集本机 `~/.t3/userdata` 实例）。

## 3. 系统架构与数据流

```
┌───────────────────────────────────────────────────────────────────┐
│ ~/.t3/userdata/ (t3code 本地数据目录)                              │
│  ├─ server-runtime.json      (pid, port, origin, serverVersion)   │
│  ├─ statev2.sqlite (-wal)    (projects, threads, runs, requests)  │
│  └─ logs/server.trace.ndjson (reportClientActivity 活跃脉冲, 可选) │
└───────────────▲───────────────────────────────────┬───────────────┘
                │ inotify / kqueue + SQLite (mode=ro)       │ kill(pid, 0)
┌───────────────┴───────────────────────────────────▼───────────────┐
│ aw-watcher-t3code                                                 │
│  1. 存活探针：校验 server-runtime.json pid 存活                    │
│  2. 状态快照：读取活跃 Runs、Pending Requests 与最近访问 Thread     │
│  3. 焦点与模式推导：计算 focused / dominant_state / interaction     │
│  4. 心跳发射：1s 周期 + 状态变化在下一次采样上报 (pulsetime=2s)             │
└───────────────────────────────┬───────────────────────────────────┘
                                │ POST /api/0/buckets/.../heartbeat
                                ▼
┌───────────────────────────────────────────────────────────────────┐
│ ActivityWatch Server (127.0.0.1:5600)                             │
│  Bucket: aw-watcher-t3code_<hostname> (type: app.t3code.activity) │
└───────────────────────────────────────────────────────────────────┘
```

## 4. 数据源与 SQLite 只读契约

### 4.1 服务存活文件：`~/.t3/userdata/server-runtime.json`

以下示例均为虚构数据：

```json
{
  "version": 1,
  "pid": 4242,
  "host": "127.0.0.1",
  "port": 8080,
  "origin": "http://127.0.0.1:8080",
  "startedAt": "2024-01-01T00:00:00.000Z",
  "serverVersion": "0.1.6",
  "ownerId": "00000000-0000-4000-8000-000000000001"
}
```

判定规则：
- 文件不存在、JSON 解析失败、`pid <= 0`，或 ` syscall.Kill(pid, 0)` 返回 `ESRCH` 时，视为 `t3code` 未运行。
- `t3code` 未运行时，Watcher 停止发送心跳（即使 `statev2.sqlite` 中残留未清理的 `running` 记录也不上报）。

### 4.2 SQLite 连接约定：`~/.t3/userdata/statev2.sqlite`

- 使用 Zig 0.17.x 编译官方 SQLite 3.54.1 C amalgamation，并静态链接 SQLite。
- 连接明确开启数据库及共享文件只读：
  `file:<base-dir>/statev2.sqlite?mode=ro&readonly_shm=1`；通过 `sqlite3_open_v2` 设置 `SQLITE_OPEN_READONLY | SQLITE_OPEN_URI`，随后设置 `PRAGMA query_only=ON` 与 `sqlite3_busy_timeout(2000)`。`readonly_shm=1` 禁止创建和写映射 WAL 共享文件。
- 禁止创建临时表、触发 checkpoint 或更改 journal mode。
- 命名只读 VFS 将文件打开标志强制设为 `READONLY`，移除 `READWRITE` / `CREATE` / `DELETEONCLOSE`，并拒绝删除。SQLite 默认会尝试读写打开 WAL，单独设置主库 `mode=ro` 不能阻止这次尝试。查询内部临时表只存内存。

### 4.3 核心表结构与字段映射

#### （1）工程表：`projection_projects`

| 字段 | 类型 | 说明 |
| :--- | :--- | :--- |
| `project_id` | `TEXT PRIMARY KEY` | 工程唯一标识 |
| `title` | `TEXT NOT NULL` | 工程名称（如 `sample-infra`、`sample-app`） |
| `workspace_root` | `TEXT NOT NULL` | 工程本地根目录（如 `/home/user/projects/sample-infra`） |
| `deleted_at` | `TEXT` | 非空表示已删除（查询时过滤 `deleted_at IS NULL`） |

#### （2）会话表：`orchestration_v2_projection_threads`

| 字段 | 类型 | 说明 |
| :--- | :--- | :--- |
| `thread_id` | `TEXT PRIMARY KEY` | 会话唯一标识 |
| `project_id` | `TEXT NOT NULL` | 所属工程 ID |
| `title` | `TEXT NOT NULL` | 会话标题 |
| `default_provider` | `TEXT NOT NULL` | 默认 Provider（如 `codex`、`antigravity`、`cursor`） |
| `runtime_mode` | `TEXT NOT NULL` | `full-access` / `approval-required` / `Supervised` |
| `archived_at` | `TEXT` | 非空表示已归档（活跃统计时过滤 `archived_at IS NULL`） |
| `deleted_at` | `TEXT` | 非空表示已删除（查询时过滤 `deleted_at IS NULL`） |
| `payload_json` | `TEXT NOT NULL` | JSON 载荷，提取下列字段： |

`payload_json` 关键字段：
- `branch`（`string | null`）：Git 分支名。
- `worktreePath`（`string | null`）：Git worktree 目录；非空时优先作为 `cwd`，为空时回退到所属工程的 `workspace_root`。
- `lastVisitedAt`（`string | null`）：ISO8601 时间戳，前端 `createThreadVisitTracker` 发送 `thread.visited` 时更新（流式输出期间每 10s 节流刷新一次）。
- `opens.openedAt`（`int64 | null`）：毫秒级 Unix 时间戳，记录最近打开该 Thread 的时刻。
- `modelSelection.model`（`string | null`）：会话选定的模型名（如 `example-model`、`example-model`）。
- `lineage.parentThreadId`（`string | null`）：非空表示该 Thread 是由父 Thread 派生的子 Agent（`is_subagent = true`）。

#### （3）运行表：`orchestration_v2_projection_runs`

| 字段 | 类型 | 说明 |
| :--- | :--- | :--- |
| `run_id` | `TEXT PRIMARY KEY` | Run 唯一标识 |
| `thread_id` | `TEXT NOT NULL` | 所属 Thread ID |
| `ordinal` | `INTEGER NOT NULL` | 同一 Thread 内的递增序号 |
| `provider` | `TEXT NOT NULL` | 实际执行的 Provider 名称 |
| `status` | `TEXT NOT NULL` | `queued` / `preparing` / `starting` / `running` / `waiting` / `completed` / `failed` / `interrupted` / `cancelled` |
| `requested_at` | `TEXT NOT NULL` | 请求发起时间（ISO8601） |
| `completed_at` | `TEXT` | 结束时间（活跃 Run 为 `NULL`） |
| `payload_json` | `TEXT NOT NULL` | 提取 `modelSelection.model`、`startedAt`、`workspacePreparation.branch` |

活跃 Run 查询条件（直接命中库内部分索引 `orchestration_v2_projection_runs_recovery_idx`）：
```sql
WHERE status IN ('queued', 'preparing', 'starting', 'running', 'waiting')
```
若同一 `thread_id` 存在多条未结束记录，按 `ordinal DESC` 取最新一条。

#### （4）运行期阻塞请求表：`orchestration_v2_projection_runtime_requests`

| 字段 | 类型 | 说明 |
| :--- | :--- | :--- |
| `runtime_request_id` | `TEXT PRIMARY KEY` | 请求唯一标识 |
| `thread_id` | `TEXT NOT NULL` | 所属 Thread ID |
| `kind` | `TEXT NOT NULL` | 请求类别（`user_input` 或审批类请求） |
| `status` | `TEXT NOT NULL` | `pending` / `resolved` / `cancelled` |
| `created_at` | `TEXT NOT NULL` | 创建时间 |

活跃阻塞请求查询条件（命中部分索引 `orchestration_v2_projection_requests_recovery_idx`）：
```sql
WHERE status = 'pending'
```

## 5. Happy Path 与状态推导规则

### 5.1 单 Thread 状态与 Phase 映射

对齐 `t3code` 内部 `packages/shared/src/agentAwareness.ts` 的 `resolveThreadAwarenessPhaseV2` 优先级：

1. **存在 `status = 'pending'` 的 Runtime Request**（按 `created_at DESC` 取最新一条）：
   - `kind == "user_input"`：`status = "blocked"`，`phase = "waiting_user_input"`。
   - 其他 `kind`（工具权限确认、命令审批等）：`status = "blocked"`，`phase = "waiting_approval"`。
2. **无 Pending Request，但存在活跃 Run**：
   - `run.status == "waiting"`：`status = "blocked"`，`phase = "waiting"`。
   - `run.status` 为 `queued` / `preparing` / `starting` / `running`：`status = "working"`，`phase = run.status`。
3. **无 Pending Request 且无活跃 Run**：
   - `status = "idle"`，`phase = "idle"`（仅当该 Thread 处于当前 `focused` 焦点时才输出快照；非焦点的历史 `idle` Thread 全部忽略）。

### 5.2 人类前台焦点（`focused`）判定

此字段依据客户端访问与 trace 推测，不能证明操作系统前台焦点，也不能区分不同客户端正在查看的 Thread。

每个采样周期按以下规则判定当前焦点 Thread：

1. 对每个未删除、未归档的 Thread，计算其最近交互时间 `last_active_at`：
   `max(parseISO(thread.lastVisitedAt), fromUnixMilli(thread.opens.openedAt))`
2. 选取 `last_active_at` 最新的一条 Thread 作为候选焦点。
3. **焦点有效窗口期（`--focus-window`，默认 `60s`）**：
   - 若 `now - candidate.last_active_at <= focus_window`，则该候选 Thread 为当前 `focused`。
   - 辅助续期信号：若 `<base-dir>/logs/server.trace.ndjson` 文件的 `mtime` 距当前时间在 `45s` 内，且文件尾部 16KB 内存在 `name == "ws.rpc.server.reportClientActivity"` 且时间戳在 `45s` 内的记录，同时候选 Thread 存在正在运行的流式 Run 或 `now - candidate.last_active_at <= 3 * focus_window`（`180s`），则保持该候选 Thread 为 `focused`。
   - 超出窗口期时，`focused = null`。

### 5.3 全局汇总字段推导（对齐 `aw-watcher-herdr`）

当 `focused == null` 且活跃 `agents` 列表为空时，视为无活跃工作，**不发送心跳**。

只要 `focused != null` 或 `len(agents) > 0`，即构造心跳事件：

1. **`dominant_state`**：
   - 任一活跃 Agent 的 `status == "working"` $\rightarrow$ `"working"`
   - 否则任一活跃 Agent 的 `status == "blocked"` $\rightarrow$ `"blocked"`
   - 否则（仅 `focused != null` 且无活跃 Run） $\rightarrow$ `"idle"`
2. **`interaction`（人机协同模式）**：
   - `focused != null` 且焦点 Thread 自身处于 `"working"` 或 `"blocked"` $\rightarrow$ `"supervised"`
   - 存在活跃 Agent（`"working"` 或 `"blocked"`），但 `focused == null` 或焦点 Thread 为 `"idle"` $\rightarrow$ `"autonomous"`
   - 无活跃 Agent，仅 `focused != null`（人类正在浏览或编辑空闲 Thread） $\rightarrow$ `"manual"`
3. **`project`（归属工程）**：
   - 若 `focused != null` 且 `focused.project != ""`，取 `focused.project`。
   - 否则在 `agents` 中按优先级（`working` 优先于 `blocked`，再按 `project` 字典序稳定排序）取首个非空 `project`。
   - 均为空时回退为 `"unknown"`。
4. **`title`**：
   - 格式固定为：`[<project>] <dominant_state> (<interaction>)`
   - 示例：`[sample-app] working (supervised)`、`[sample-api] working (autonomous)`、`[sample-infra] blocked (supervised)`、`[sample-infra] idle (manual)`。

## 6. ActivityWatch Event Schema

- **Bucket ID**：`aw-watcher-t3code_<hostname>`
- **Client Name**：`aw-watcher-t3code`
- **Event Type**：`app.t3code.activity`
- **默认心跳间隔**：`1s`（`--heartbeat-interval 1s`）
- **默认合并窗口（`pulsetime`）**：`2s`（`--pulsetime 2s`，要求 `pulsetime > heartbeat_interval`）

### 6.1 Event `data` JSON 结构示例（虚构数据）

```json
{
  "title": "[sample-app] working (supervised)",
  "project": "sample-app",
  "dominant_state": "working",
  "interaction": "supervised",
  "active_count": 2,
  "working_count": 2,
  "blocked_count": 0,
  "supervised_count": 1,
  "autonomous_count": 1,
  "focused": {
    "thread_id": "00000000-0000-4000-8000-000000000101",
    "thread_title": "示例应用功能开发",
    "project": "sample-app",
    "cwd": "/home/user/projects/sample-app",
    "branch": "main",
    "agent": "antigravity",
    "model": "example-model",
    "status": "working",
    "phase": "running",
    "runtime_mode": "full-access"
  },
  "agents": [
    {
      "thread_id": "00000000-0000-4000-8000-000000000101",
      "thread_title": "示例应用功能开发",
      "run_id": "run:thread:00000000-0000-4000-8000-000000000101:ordinal:2",
      "agent": "antigravity",
      "model": "example-model",
      "status": "working",
      "phase": "running",
      "project": "sample-app",
      "cwd": "/home/user/projects/sample-app",
      "branch": "main",
      "runtime_mode": "full-access",
      "is_focused": true,
      "execution_mode": "supervised",
      "is_subagent": false
    },
    {
      "thread_id": "00000000-0000-4000-8000-000000000102",
      "thread_title": "示例 API 维护",
      "run_id": "run:thread:00000000-0000-4000-8000-000000000102:ordinal:2",
      "agent": "codex",
      "model": "example-model-2",
      "status": "working",
      "phase": "running",
      "project": "sample-api",
      "cwd": "/home/user/projects/sample-api",
      "branch": "main",
      "runtime_mode": "full-access",
      "is_focused": false,
      "execution_mode": "autonomous",
      "is_subagent": false
    }
  ]
}
```

> **ActivityWatch 时间段切分保护**：参照 `aw-watcher-herdr` 的 `withDeliveryEpoch` 机制，在 `data` 顶层附加 `"delivery_epoch": "<random-session>-<counter>"`，启动时生成随机 session，断线恢复或采集暂停后递增 counter，防止 AW 错误将断连前后的两次相同 payload 心跳合并成跨越离线时段的单条长事件。

## 7. 边界条件与异常处理

1. **`t3code` 未启动或异常退出（僵尸 Run 防护）**：
   - 若 `t3code` 进程被 `SIGKILL` 终止，`statev2.sqlite` 中的 `orchestration_v2_projection_runs` 可能残留 `status = 'running'`。
   - Watcher 每次采集前先校验 `server-runtime.json` 中的 `pid` 是否存活；进程不存在时立即返回空快照，停止上报。
2. **数据库初始化或迁移期间**：
   - `~/.t3/userdata` 目录或 `statev2.sqlite` 尚未创建时，Watcher 保持监听目录并在周期轮询中静默等待，不退出进程。
   - 若读取时遇到短暂 `SQLITE_BUSY` 或 schema 尚未就绪，记录调试日志并跳过当次采样，下一秒重试。
3. **ActivityWatch 服务端离线**：
   - 心跳 POST 失败时不缓存历史队列、不落盘重试；标记 `bucketReady = false` 与 `hadFailure = true`。
   - 后续采样周期探测到 AW 恢复后，重建/确认 Bucket，递增 `deliveryEpoch` 并恢复实时心跳。
4. **高频 WAL 写入防抖**：
   - `t3code` 在流式输出期间会高频写入 `statev2.sqlite-wal`。
   - 文件变更事件仅在推导出的快照签名（`dominant_state`、`interaction`、`project`、`focused.thread_id`、`agents` 列表）发生实质变化，或距离上次发送已满 `heartbeat_interval` 时才触发 HTTP 请求，避免每毫秒刷爆 AW 接口。SQLite 采样按同一间隔防抖，默认每秒最多一次；状态变化最迟在下一次采样上报。
5. **稳定排序**：
   - `agents` 数组按 `thread_id` 升序排列，确保相同运行态生成的 JSON 字节完全一致，使 ActivityWatch 的 `pulsetime` 合并逻辑稳定生效。

## 8. 性能与非功能性要求

- **零写保证**：对 `~/.t3/userdata` 下任何文件零写入、零修改权限。
- **资源开销目标（需实测）**：常驻内存 `< 25 MB`，1s 采样周期下平均 CPU 占用 `< 0.5%`，单次 SQLite 快照查询耗时 `< 5 ms`。
- **静态编译**：SQLite 静态编入单二进制；Linux 用 musl 构建全静态可执行文件，macOS 保留系统库链接。支持 `x86_64-linux`、`aarch64-linux` 与 `aarch64-darwin`。

## 9. CLI 接口与工程文件清单

### 9.1 CLI 命令与参数

```text
aw-watcher-t3code [flags]
aw-watcher-t3code doctor [flags]
aw-watcher-t3code service <install|uninstall|start|stop|restart|status> [flags]
```

| 参数 | 默认值 | 环境变量 | 说明 |
| :--- | :--- | :--- | :--- |
| `--base-dir` | `~/.t3/userdata` | `T3CODE_DATA_DIR` | `t3code` userdata 目录路径 |
| `--aw-url` | `http://127.0.0.1:5600` | `AW_WATCHER_T3CODE_AW_URL` | ActivityWatch Server 地址 |
| `--heartbeat-interval` | `1s` | `AW_WATCHER_T3CODE_HEARTBEAT_INTERVAL` | 心跳发射间隔 |
| `--pulsetime` | `2s` | `AW_WATCHER_T3CODE_PULSETIME` | ActivityWatch 事件合并窗口 |
| `--focus-window` | `60s` | `AW_WATCHER_T3CODE_FOCUS_WINDOW` | 人类前台焦点活跃判定窗口 |
| `--dry-run` | `false` | - | 读取一次当前快照并以格式化 JSON 输出至 stdout 后退出 |
| `--verbose` | `false` | - | 输出每次采样的调试日志 |
| `--version` | `false` | - | 打印版本号并退出 |

### 9.2 涉及文件清单

1. **独立仓库 `aw-watcher-t3code`**：
   - `src/main.zig`：CLI 入口、自检、信号处理、采集循环。
   - `src/config.zig`：参数及环境变量边界校验。
   - `src/t3code.zig`：进程探测、SQLite 只读查询、trace 尾部解析。
   - `src/model.zig`：状态、焦点、工程归属及协同模式推导。
   - `src/activitywatch.zig`：Bucket、心跳、超时及断线切段。
   - `src/notify.zig`：原生目录与文件监听、缺目录恢复。
   - `src/service.zig`：systemd user service / launchd 管理。
   - 各模块内嵌 `test`：覆盖规格要求的状态与边界行为。
   - `build.zig` / `build.zig.zon` / `vendor/sqlite` / `default.nix` / `flake.nix` / `README.md` / `SPEC.md`。
2. **外部 Nix 配置集成（可选）**：
   - 在外部配置中引用仓库提供的 `default.nix` 或 flake 包。
   - 按目标配置仓库约定维护源码版本、包导出及后台服务声明。

## 10. 已确认的技术决策记录（ADR）

| 编号 | 决策点 | 选定方案 | 决策原因 |
| :--- | :--- | :--- | :--- |
| ADR-1 | 数据采集通道 | SQLite 只读直连（`mode=ro` + `PRAGMA query_only=1`）+ `inotify` / `kqueue` | 免去签发/续期 Bearer Token，不在 `auth_sessions` 表产生持久垃圾会话，严格遵守 `~/.t3/userdata` 只读原则。 |
| ADR-2 | 服务存活校验 | 解析 `server-runtime.json` 的 `pid` 并执行 `kill(pid, 0)` | 防止 `t3code` 异常退出后数据库内残留的 `running` 状态被无限期误报为活跃工作。 |
| ADR-3 | 技术栈与 SQLite 驱动 | Zig 0.17.x + 官方 SQLite C amalgamation | 保留 watcher 事件语义，通过 Zig 编译 SQLite C，实现单二进制；Nix 负责锁定构建环境。 |
| ADR-4 | 分类规则兼容 | `title` 采用 `[<project>] <dominant_state> (<interaction>)` | 兼容使用 `[<project>]` 前缀的 ActivityWatch 正则分类器。 |

## 11. 验收标准（Acceptance Criteria）

1. **只读与快照准确性**：在运行 `t3code` 的环境中执行 `aw-watcher-t3code --dry-run`，输出的 JSON 能准确反映当前工程、Thread、Provider、Model、`status`（`working` / `blocked` / `idle`）与 `interaction`（`supervised` / `autonomous` / `manual`），且执行前后 `statev2.sqlite` 无任何写入事务。
2. **进程离线保护**：当 `server-runtime.json` 不存在或对应 `pid` 进程已终止时，即使 `statev2.sqlite` 中存在 `status = 'running'` 的记录，`--dry-run` 也输出空状态且守护进程不发送心跳。
3. **自检工具完备**：`aw-watcher-t3code doctor` 依次输出 `userdata dir`、`t3code server process`、`statev2.sqlite read-only query`、`ActivityWatch server` 四项检查结果及当前活跃会话计数。
4. **单元测试全绿**：`zig build test` 通过，覆盖：
   - `working`（`running`/`starting`/`queued`）与 `blocked`（`user_input` vs `approval`）优先级判定；
   - `supervised`、`autonomous`、`manual` 三种交互模式切换；
   - 子 Agent（`lineage.parentThreadId != null`）识别与 `worktreePath` 回退 `workspace_root`；
   - ActivityWatch 断线恢复后的 `delivery_epoch` 递增。
5. **Nix 打包通过**：`nix build` 成功产出静态可执行文件 `result/bin/aw-watcher-t3code`。
