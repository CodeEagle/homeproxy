# HomeProxy CE Selector、URLTest 与 Clash UI 移植设计

日期：2026-09-23
目标分支：`CodeEagle/homeproxy` 的 `dev`（`luci-app-homeproxy-ce`）
参考实现：`bulianglin/homeproxy@8d021bf`（`support clash mode`）

## 目标

把参考实现中的完整 Clash/HomeProxy 界面能力移植到 HomeProxy CE，同时保留 CE 分支在
sing-box 1.11+、DNS、路由、订阅和 Clash API 上的现有实现。

完成后，用户可以：

1. 在 LuCI 节点页面创建和查看 `selector`、`urltest` 组。
2. 使用稳定的内部节点引用组织组成员，不因修改显示名称而失效。
3. 在简单模式和自定义路由中把组作为出站使用。
4. 通过现有 Clash API/外部面板手动切换 Selector。
5. 用 `clash_mode` 配置 DNS 和路由规则，并由 Clash 面板切换模式。
6. 刷新订阅或删除节点后，不产生悬空引用或无效 sing-box 配置。

## 非目标

- 不移植参考分支的 DNS、chinadns-ng、digest、缓存数据库或包依赖变更。
- 不注释或删除 CE 现有的 `routing_node` 模型。
- 不把节点显示名称直接用作 sing-box tag。
- 不修改标准版 `master`；本次只覆盖 `homeproxy-ce`。
- 不在本次仓库改动中直接部署到用户路由器。路由器验证使用独立构建产物和显式测试流程。

## 方案选择

采用 CE 原生移植，不直接 cherry-pick `8d021bf`。

参考提交基于 2024 年旧架构，使用 label 作为内部引用、禁用 Routing Nodes，并绕过 CE
后续约 293 个提交形成的 UCI section ID、`cfg-<id>-out`、订阅清理和路由生成逻辑。直接
套用会让重命名、WireGuard endpoint、URLTest 包装和自定义路由发生不兼容。

本设计保留以下 CE 不变量：

- UCI 内部引用优先使用 section ID。
- sing-box tag 继续使用 `cfg-<section-id>-out`。
- `routing_node` 继续负责自定义路由的启用、上游、接口和域名解析设置。
- 现有 Clash API 配置与 cache file 合并生成，不创建第二套 experimental 配置。

## 数据模型

### 节点组

`config node` 新增两种 `type`：

```text
selector
urltest
```

共享字段：

```text
list outbounds '<node-section-id | direct-out | block-out>'
option interrupt_exist_connections '0|1'
```

Selector 字段：

```text
option default '<outbound reference>'
```

URLTest 字段：

```text
option url 'https://www.gstatic.com/generate_204'
option interval '<seconds>'
option tolerance '<milliseconds>'
option idle_timeout '<seconds>'
```

时间字段在 UCI 中继续使用 CE 现有的“整数秒”约定，生成器统一通过 `strToTime()` 转换，
不直接保存 `3m`、`30m` 等 duration 字符串。

### 兼容旧的 label 引用

用户现有的定制配置可能已经保存 label 形式的 `outbounds/default`。读取和迁移按以下顺序
解析引用：

1. `direct-out`、`block-out` 等内建 tag；
2. 精确 UCI section ID；
3. 唯一匹配的节点 label（旧格式兼容）。

迁移脚本把唯一 label 转换成 section ID。重复 label 或无法解析的引用不猜测目标，保留原值
并产生明确诊断；生成器不得静默路由到错误节点。

## LuCI 设计

### 节点页面

`view/homeproxy-ce/node.js` 增加：

- `selector`、`urltest` 类型选项；
- 组成员多选，选项值为 section ID、显示值为节点 label；
- Selector 默认成员；
- URLTest URL、间隔、容差、空闲超时；
- 切换成员后是否中断现有连接。

地址、端口、认证、TLS、传输等普通代理字段不对组显示，也不参与组的必填校验。

表单校验必须拒绝：

- 空成员列表；
- 自身引用；
- Selector 默认值不在成员列表；
- 直接或间接循环；
- 引用不存在的节点。

添加新组时允许引用已存在的普通节点和已存在的无环组；不允许把当前正在编辑的组加入自身。

### 客户端页面

保留现有 Routing Nodes 页面。普通 routing node 可以选择 selector/urltest 节点；旧的特殊
`node='urltest'` 配置继续受支持，避免破坏既有配置。

DNS rule 和 route rule 新增 `clash_mode`：

```text
direct
rule
global
script
```

Clash API 页面复用 CE 已有的 `experimental` section，不重复创建配置。现有
`external_controller`、`secret`、`external_ui`、下载 URL、下载 detour 和 `default_mode` 保持兼容。

## 生成器设计

### 引用解析

新增单一引用解析函数，把 section ID、兼容 label 和内建 tag 转成 sing-box tag。UI、组成员、
默认成员、routing node 和 Clash UI 下载 detour 使用同一套规则，避免各处各自转换。

### 依赖图

生成前构建节点依赖图。以简单模式主节点、主 UDP 节点、自定义 routing nodes、URLTest 成员和
组成员为根，深度优先收集依赖：

- 普通节点和 endpoint 只生成一次；
- 先生成成员，再生成 selector/urltest；
- 检测到循环时输出包含路径的错误并停止生成；
- 缺失成员时停止生成，不用 `direct-out` 静默替代用户选择；
- 内建 `direct-out`、`block-out` 不进入节点图。

### 输出字段

组 outbound 使用稳定 tag：

```json
{
  "type": "selector|urltest",
  "tag": "cfg-<section-id>-out",
  "outbounds": ["cfg-<member-id>-out"],
  "default": "cfg-<member-id>-out",
  "url": "...",
  "interval": "...s",
  "tolerance": 50,
  "idle_timeout": "...s",
  "interrupt_exist_connections": false
}
```

仅输出与类型相关的字段。组不输出 server、server_port、认证、TLS、transport 或
`routing_mark`。普通节点行为不变。

生成器把 DNS/route rule 的 `clash_mode` 原样写入当前 schema，并继续使用 CE 的 action、
outbound 归一化和 sing-box 版本兼容逻辑。

### Experimental 合并

`config.experimental` 继续同时包含 cache file 和 Clash API。禁用 Clash API 时不输出有效监听
地址；启用时沿用现有字段。不会用参考提交的旧对象覆盖 cache file。

## 订阅和删除行为

`update_subscriptions.uc` 在订阅节点消失后：

1. 从 selector/urltest 的 `outbounds` 中移除对应 section ID；
2. 如果 `default` 被移除，清空 default，让 sing-box 使用第一个有效成员；
3. 若组变成空组，记录错误并让生成/启动失败为可诊断状态，不删除整个组；
4. 继续执行现有 main URLTest 和 routing URLTest 清理逻辑。

LuCI 手动删除节点时使用相同引用检查：节点仍被组引用时阻止删除，并列出引用组。用户必须先
显式修改相关组；删除动作本身不隐式重写其他配置。

### 订阅动态组绑定（设计）

需要跟随订阅完整节点集的 selector/urltest 才声明动态绑定；未声明的组始终保留用户手动成员。
绑定使用节点 section 上的 `option subscription_sync '1'`、`option subscription_family
'ipv4|ipv6|all'` 和一个或多个 `list subscription_source '<grouphash>'`。`grouphash` 是去掉 URL
片段后的订阅地址 MD5，与 `update_subscriptions.uc` 使用的值相同；例如一个 IPv4 自动组写成：

```uci
config node 'auto_ipv4'
	option type 'urltest'
	option subscription_sync '1'
	option subscription_family 'ipv4'
	list subscription_source '<md5(subscription-url-without-fragment)>'
```

`ipv4`/`ipv6` 只匹配 `address` 的字面量地址（分别复用 `validation('ip4addr', ...)` 和
`validation('ip6addr', ...)`）；域名地址仅在 `all` 下参与同步。成功抓取某个绑定源时，只同步该源且符合 family 的直接节点：新增节点加入，已消失节点移除，组内
手动添加的其他源或组引用保持不变。抓取失败、来源已不在当前订阅列表或结果没有有效节点时保留原成员，避免没有新数据时清空
组；移除后若 `default` 不再是成员则删除它，让 sing-box 选择第一个有效成员。若本次同步会使
selector/urltest 为空，则放弃提交并保留更新前配置（`update_via_proxy=1` 时保持运行中的旧配置，
否则重新启动旧配置）；预先存在的空组仍由生成器报告可诊断的错误。需要固定节点子集的媒体/区域组不设置 `subscription_sync`，
因此不会因同一来源的其他节点出现而被扩展。LuCI 保存绑定选项时不立即改写 `outbounds`，配置会在
下一次订阅更新成功后生效。

## 迁移

`migrate_config.uc` 增加幂等迁移：

- label 引用转换为 section ID；
- `default` 同步转换；
- 已是 section ID 或内建 tag 的配置保持不变；
- 不修改普通节点、旧 routing URLTest 或 Clash API 配置；
- 重复执行不产生额外变化。

迁移前后均可生成旧配置；迁移只负责规范化，不是运行时正确性的唯一保障。

## 错误处理与安全

- 循环、悬空引用、空组和无效 default 给出明确错误，不静默改路由。
- LuCI 不显示或记录 Clash API secret。
- 不自动把 Clash API 暴露到 WAN，也不新增防火墙放行规则。
- `external_controller` 的现有行为保持不变；若监听非 loopback，界面继续提示设置 secret。
- 解析兼容 label 时必须唯一匹配，避免同名节点被错误选择。

## 测试和验收

### 自动测试

新增 Node/fixture 测试覆盖：

- selector/urltest 表单字段和依赖；
- section ID 作为值、label 仅用于展示；
- 空组、自引用、间接循环、无效 default；
- label 兼容解析和迁移幂等；
- 订阅删除后的成员/default 清理；
- selector/urltest JSON 字段、tag、生成顺序和 `routing_mark` 缺失；
- `clash_mode` 在 DNS/route rule 中的输出；
- Clash API 与 cache file 同时存在。

静态检查：

```sh
git diff --check
node --check htdocs/luci-static/resources/view/homeproxy-ce/node.js
node --check htdocs/luci-static/resources/view/homeproxy-ce/client.js
node --test tests/*.test.js
```

### 目标环境验证

在 OpenWrt/ImmortalWrt 构建环境生成 IPK，并在测试路由器执行：

```sh
ucode -S /etc/homeproxy-ce/scripts/generate_client.uc
sing-box check -c /var/run/homeproxy-ce/sing-box-c.json
/etc/init.d/homeproxy-ce status
```

LuCI/Clash 面板验收：

1. 创建普通节点、Selector 和 URLTest；保存、刷新后字段不丢失。
2. 修改节点 label，组引用保持有效。
3. Selector 可在 Clash 面板切换，并在启用 cache file 时保留选择。
4. URLTest 能测出延迟并自动选择。
5. 组可作为简单模式和自定义路由出站。
6. Clash mode 可切换且 DNS/route rule 行为对应。
7. 普通节点编辑、旧 routing URLTest、订阅更新和服务启动无回归。

## 交付

- 在 `codex/port-homeproxy-ui` 分支提交实现和测试。
- 推送到 `CodeEagle/homeproxy` 并创建 PR 到 `dev`。
- PR 描述注明来源提交、未采用的旧架构部分、迁移规则和测试证据。
- 不把用户路由器配置、订阅地址、节点凭据或 Clash secret 写入仓库和 PR。

## 参考资料

- [bulianglin/homeproxy](https://github.com/bulianglin/homeproxy)
- [CodeEagle/homeproxy](https://github.com/CodeEagle/homeproxy)
- [sing-box Selector](https://sing-box.sagernet.org/configuration/outbound/selector/)
- [sing-box URLTest](https://sing-box.sagernet.org/configuration/outbound/urltest/)
- [sing-box Clash API](https://sing-box.sagernet.org/configuration/experimental/clash-api/)
- [sing-box Route Rule](https://sing-box.sagernet.org/configuration/route/rule/)
