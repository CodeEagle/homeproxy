# HomeProxy CE Selector、URLTest 与 Clash UI 移植实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 `luci-app-homeproxy-ce` 中原生实现可编辑、可嵌套、可迁移的 Selector/URLTest 节点组，并让其完整接入路由、Clash API、订阅更新与配置生成。

**Architecture:** UCI 始终以 node section ID 保存组成员和默认成员，sing-box 始终使用 `cfg-<section-id>-out`。共享 ucode helper 负责兼容旧 label 引用和依赖图规划；LuCI helper 负责浏览器端同构校验。生成器先规划依赖顺序，再生成普通节点、endpoint 和组，现有 `routing_node` URLTest 与 Clash API/cache file 架构保持不变。

**Tech Stack:** OpenWrt LuCI JavaScript、ucode、UCI、sing-box 1.11+、Node.js `node:test`。

**Spec:** `docs/superpowers/specs/2026-09-23-homeproxy-ce-selector-clash-ui-design.md`

## Global Constraints

- 目标分支是 `CodeEagle/homeproxy` 的 `dev`，只修改 `luci-app-homeproxy-ce` 路径。
- 内部节点引用优先保存 UCI section ID；sing-box tag 必须保持 `cfg-<section-id>-out`。
- `direct-out`、`block-out` 是唯一允许直接保存的内建 outbound tag。
- 旧 label 引用仅在唯一匹配时兼容；重复 label、悬空引用、空组和循环必须明确失败。
- 保留现有 `routing_node` 及其特殊 `node='urltest'` 配置，不用新节点组替换它。
- Selector/URLTest 组不得输出 `server`、`server_port`、认证、TLS、transport 或 `routing_mark`。
- 时间字段在 UCI 中保存整数秒，并通过 `strToTime()` 生成 sing-box duration。
- Clash API 复用现有 `experimental` section，并继续与 cache file 合并。
- 不把路由器配置、订阅地址、节点凭据或 Clash secret 写入仓库、测试 fixture 或 PR。
- 每个行为变更都遵循 RED→GREEN→REFACTOR；测试必须先观察到预期失败。

## Review Focus

- 同名 label：旧 label 引用有多个候选时必须报 ambiguous，不能选第一个；Task 1 的 resolver 测试覆盖。
- 组嵌套循环：`A → B → C → A` 必须返回完整循环路径；Task 1 的 dependency planner 测试覆盖。
- 节点改名：section ID 不变时生成 tag 和组引用不变；Task 2 的生成器测试覆盖。
- 订阅节点消失：成员列表和 default 必须同步清理，空组必须保留并变为可诊断错误；Task 5 的订阅清理测试覆盖。
- 旧 routing URLTest 与新 node URLTest 同时存在：两者都必须生成且 tag 不冲突；Task 4 的集成测试覆盖。

---

### Task 1: 共享引用解析、组规范化与依赖图

**Files:**
- Modify: `root/etc/homeproxy-ce/scripts/homeproxy.uc`
- Create: `tests/helpers/extract-ucode-functions.js`
- Create: `tests/outbound-group-graph.test.js`

**Interfaces:**
- Consumes: UCI node 对象数组；每个对象至少包含 `'.name'`、`label`、`type`，组可包含 `outbounds` 和 `default`。
- Produces: `buildNodeReferenceIndex(nodes)`、`resolveNodeReference(node_index, reference)`、`normalizeNodeGroup(group, node_index)`、`planNodeDependencies(node_index, roots)` 四个导出函数。
- `resolveNodeReference()` 返回 `{ status: 'ok', id, tag }`、`{ status: 'missing', reference }` 或 `{ status: 'ambiguous', reference, matches }`。
- `planNodeDependencies()` 返回 `{ status: 'ok', order }` 或 `{ status: 'error', kind, reference, path }`，`order` 中成员先于组且不包含内建 tag。

- [ ] **Step 1: 建立可执行 ucode 纯函数的测试 helper**

在 `tests/helpers/extract-ucode-functions.js` 中读取真实 `.uc` 文件，按花括号边界提取命名函数；去掉 `export ` 后在同一个 `vm` context 中求值，使被测函数可以相互调用：

```js
function extractUcodeFunctions(source, names, context = {}) {
	const bodies = names.map((name) => extractFunctionSource(source, name).replace(/^export\s+/, ''));
	return vm.runInNewContext(
		`(() => { ${bodies.join('\n')} return { ${names.join(', ')} }; })()`,
		context
	);
}
```

测试 helper 自身用一个含嵌套对象和条件分支的临时 source 验证，确保不是只匹配到函数签名。

- [ ] **Step 2: 写引用解析和依赖图的失败测试**

`tests/outbound-group-graph.test.js` 使用字面量 fixture，至少包含：

```js
const nodes = [
	{ '.name': 'n1', label: 'Hong Kong', type: 'vless' },
	{ '.name': 'n2', label: 'Los Angeles', type: 'trojan' },
	{ '.name': 'g1', label: 'Auto', type: 'urltest', outbounds: ['n1', 'n2'] },
	{ '.name': 'g2', label: 'Manual', type: 'selector', outbounds: ['g1', 'n2'], default: 'n2' }
];
```

断言：section ID、唯一 label、内建 tag 的解析结果；重复 label 为 ambiguous；未知引用为 missing；`g2` 的顺序为 `['n1', 'n2', 'g1', 'g2']`；悬空成员为 missing；`g1 → g2 → g1` 返回 path `['g1', 'g2', 'g1']`；空组返回 `kind: 'empty-group'`；default 不在成员中返回 `kind: 'invalid-default'`。

- [ ] **Step 3: 运行测试并确认 RED**

Run: `node --test tests/outbound-group-graph.test.js`

Expected: FAIL，原因是四个 helper 尚未在 `homeproxy.uc` 中定义，而不是 fixture 或提取器错误。

- [ ] **Step 4: 在 `homeproxy.uc` 中实现最小共享逻辑**

按以下控制流实现并导出四个函数；`normalizeNodeGroup()` 遇到第一个错误立即返回该错误，
`planNodeDependencies()` 使用 `visiting`/`visited` 两个集合区分循环与已完成节点：

```ucode
const builtin_outbound_tags = { 'direct-out': true, 'block-out': true };

export function buildNodeReferenceIndex(nodes) {
	let index = { by_id: {}, by_label: {} };
	for (let node in nodes) {
		index.by_id[node['.name']] = node;
		if (node.label) {
			if (!index.by_label[node.label])
				index.by_label[node.label] = [];
			push(index.by_label[node.label], node['.name']);
		}
	}
	return index;
}

export function resolveNodeReference(node_index, reference) {
	if (builtin_outbound_tags[reference])
		return { status: 'ok', id: reference, tag: reference };
	if (node_index.by_id[reference])
		return { status: 'ok', id: reference, tag: `cfg-${reference}-out` };
	const matches = node_index.by_label[reference] || [];
	if (length(matches) === 1)
		return { status: 'ok', id: matches[0], tag: `cfg-${matches[0]}-out` };
	return length(matches) > 1
		? { status: 'ambiguous', reference, matches }
		: { status: 'missing', reference };
}

export function normalizeNodeGroup(group, node_index) {
	let outbounds = [];
	for (let reference in group.outbounds || []) {
		const resolved = resolveNodeReference(node_index, reference);
		if (resolved.status !== 'ok')
			return resolved;
		if (resolved.id === group['.name'])
			return { status: 'error', kind: 'self-reference', reference };
		if (!(resolved.id in outbounds))
			push(outbounds, resolved.id);
	}
	if (!length(outbounds))
		return { status: 'error', kind: 'empty-group', reference: group['.name'] };

	let default_id = null;
	if (group.default) {
		const resolved_default = resolveNodeReference(node_index, group.default);
		if (resolved_default.status !== 'ok')
			return resolved_default;
		default_id = resolved_default.id;
		if (!(default_id in outbounds))
			return { status: 'error', kind: 'invalid-default', reference: group.default };
	}
	return { status: 'ok', outbounds, default: default_id };
}
```

`planNodeDependencies()` 对每个 root 先 `resolveNodeReference()`；DFS 进入组时把 ID 放入
`visiting` 和 path，递归 `normalizeNodeGroup().outbounds`，退出时移入 `visited` 并追加到 order。
再次遇到 `visiting` ID 时，从 path 中该 ID 的位置切片并在末尾再次追加该 ID。成员去重但保持
首次出现顺序；错误对象包含原始 reference；不得用 `direct-out` 替换错误引用。

- [ ] **Step 5: 运行 RED 测试至 GREEN 并做 mutation check**

Run: `node --test tests/outbound-group-graph.test.js`

Expected: 全部 PASS。随后临时把 DFS 的 visiting 检查改成 visited，确认循环测试失败，再撤销临时改动并重跑至 PASS。

- [ ] **Step 6: 提交 Task 1**

```bash
git add root/etc/homeproxy-ce/scripts/homeproxy.uc tests/helpers/extract-ucode-functions.js tests/outbound-group-graph.test.js
git commit -m "feat: add outbound group dependency planning"
```

---

### Task 2: 生成稳定且严格的 Selector/URLTest outbound

**Files:**
- Modify: `root/etc/homeproxy-ce/scripts/generate_client.uc`
- Modify: `tests/outbound-group-graph.test.js`
- Create: `tests/generate-client-groups.test.js`

**Interfaces:**
- Consumes: Task 1 的四个 helper。
- Produces: `generate_outbound(node, reference_index)`；普通节点保持现有 JSON，组节点只输出组字段。
- Produces: `collectPlannedNodes(nodes, roots)`，返回按依赖顺序排列的 node 对象，供简单模式与自定义模式共用。
- Produces: `outboundTag(reference)` 把内建 tag 原样返回、section ID 转成 `cfg-<id>-out`；`formatNodeReferenceError(result)` 把 Task 1 错误对象转换成含 section/reference/path 的启动错误。

- [ ] **Step 1: 写组 JSON 的失败测试**

从真实 `generate_client.uc` 提取 `generate_outbound()`，注入 `strToInt`、`strToBool`、`strToTime`、`removeBlankAttrs` 和 Task 1 helper。断言 Selector 的字面量输出：

```js
{
	type: 'selector',
	tag: 'cfg-g2-out',
	outbounds: ['cfg-g1-out', 'cfg-n2-out'],
	default: 'cfg-n2-out',
	interrupt_exist_connections: true
}
```

断言 URLTest 输出包含 `url`、`interval: '180s'`、`tolerance: 50`、`idle_timeout: '1800s'`；两种组都没有 `routing_mark`、`server`、`server_port`、`tls`、`transport`。

- [ ] **Step 2: 写规划根节点与稳定 tag 的失败测试**

断言：

```js
collectPlannedNodes(nodes, ['g2']).map((node) => node['.name'])
// => ['n1', 'n2', 'g1', 'g2']
```

将 `n1.label` 从 `Hong Kong` 改为 `香港` 后，再次生成仍引用 `cfg-n1-out`；悬空引用和循环必须抛出包含 reference/path 的错误，不能落到 `direct-out`。

- [ ] **Step 3: 运行测试并确认 RED**

Run: `node --test tests/generate-client-groups.test.js`

Expected: FAIL，现有 `generate_outbound()` 会给组输出普通代理字段，且没有依赖规划入口。

- [ ] **Step 4: 实现组分支和严格引用转换**

在 `generate_outbound()` 顶部增加组专用返回：

```ucode
if (node.type in ['selector', 'urltest']) {
	const normalized = normalizeNodeGroup(node, reference_index);
	if (normalized.status !== 'ok')
		die(formatNodeReferenceError(normalized));

	return removeBlankAttrs({
		type: node.type,
		tag: 'cfg-' + node['.name'] + '-out',
		outbounds: map(normalized.outbounds, (id) => outboundTag(id)),
		default: node.type === 'selector' ? outboundTag(normalized.default) : null,
		url: node.type === 'urltest' ? node.url : null,
		interval: node.type === 'urltest' ? strToTime(node.interval) : null,
		tolerance: node.type === 'urltest' ? strToInt(node.tolerance) : null,
		idle_timeout: node.type === 'urltest' ? strToTime(node.idle_timeout) : null,
		interrupt_exist_connections: strToBool(node.interrupt_exist_connections)
	});
}
```

`outboundTag()` 对内建 tag 原样返回，对 section ID 返回 `cfg-<id>-out`。普通节点分支保持现状。

- [ ] **Step 5: 用依赖计划替换按表面节点收集**

把简单模式主节点、主 UDP 节点、自定义 routing node、旧 routing URLTest 成员和所有显式 upstream 作为 roots。调用 `planNodeDependencies()` 后按 order 生成普通 outbound/endpoint 和组；同一 section 只生成一次。保留 `main-out`、`main-udp-out` 和旧 routing URLTest 的既有 tag。

`get_outbound(cfg)` 先识别内建 tag和 routing_node section；若 `cfg` 本身是 node section ID，则返回 `cfg-<id>-out`。missing/ambiguous 必须 `die()`，不得通过 `normalize_outbound(..., 'direct-out')` 静默降级用户显式选择。

- [ ] **Step 6: 运行 Task 1/2 测试和语法检查**

```bash
node --test tests/outbound-group-graph.test.js tests/generate-client-groups.test.js
git diff --check
```

Expected: 全部 PASS，`git diff --check` 无输出。

- [ ] **Step 7: 提交 Task 2**

```bash
git add root/etc/homeproxy-ce/scripts/generate_client.uc tests/outbound-group-graph.test.js tests/generate-client-groups.test.js
git commit -m "feat: generate selector and urltest node groups"
```

---

### Task 3: LuCI 节点组编辑、校验与安全删除

**Files:**
- Modify: `htdocs/luci-static/resources/homeproxyce.js`
- Modify: `htdocs/luci-static/resources/view/homeproxy-ce/node.js`
- Create: `tests/helpers/load-luci-module.js`
- Create: `tests/node-group-ui.test.js`

**Interfaces:**
- Consumes: LuCI `uci.sections(config, 'node', callback)` 返回的 node 对象。
- Produces: `hp.nodeGroupChoices(nodes, current_id)`、`hp.validateNodeGroup(nodes, group)`、`hp.findNodeGroupReferences(nodes, target_id)`。
- `nodeGroupChoices()` 返回 `{ value: section_id, label }`，排除当前节点；内建项由调用方显式添加。
- `validateNodeGroup()` 返回 `true` 或可直接显示的错误文本。

- [ ] **Step 1: 创建 LuCI module 执行 helper 并写失败测试**

`tests/helpers/load-luci-module.js` 在 `vm` 中执行真实 `homeproxyce.js`，为 `baseclass.extend`、`form.DynamicList.extend`、`_()`、`uci`、`ui` 提供最小实现，返回模块导出对象。

`tests/node-group-ui.test.js` 断言：choice 的 value 是 `n1` 而显示 label 是 `香港`；当前组不出现在自身候选中；空成员、自引用、间接循环、missing、invalid default 返回错误；`findNodeGroupReferences(nodes, 'n1')` 返回引用它的组 ID/label。

- [ ] **Step 2: 运行测试并确认 RED**

Run: `node --test tests/node-group-ui.test.js`

Expected: FAIL，三个 helper 尚不存在。

- [ ] **Step 3: 实现浏览器端纯 helper**

在 `homeproxyce.js` 的导出对象中实现：

```js
nodeGroupChoices(nodes, currentId) {
	return nodes
		.filter((node) => node['.name'] !== currentId)
		.map((node) => ({ value: node['.name'], label: node.label || node['.name'] }));
},
findNodeGroupReferences(nodes, targetId) {
	return nodes.filter((node) =>
		['selector', 'urltest'].includes(node.type) && (node.outbounds || []).includes(targetId));
},
validateNodeGroup(nodes, group) {
	const graph = nodes.map((node) => node['.name'] === group['.name'] ? group : node);
	return validateNodeGroupGraph(graph, group['.name']);
},
```

同时定义模块内私有 `validateNodeGroupGraph(nodes, rootId)`，使用与 Task 1 相同的
ID/唯一 label 解析和三色 DFS；把 `empty-group`、`self-reference`、`missing`、`ambiguous`、
`invalid-default`、`cycle` 分别转换成包含 section/label 的用户可读错误。保持 helper 无 DOM
副作用，便于 LuCI 调用和 Node 测试。

- [ ] **Step 4: 在 `renderNodeSettings()` 中接入组字段**

在 type 中增加 `selector` 和 `urltest`。地址、端口及普通代理专属字段对两种组隐藏；添加：

```js
form.MultiValue  outbounds
form.ListValue   default
form.Value       url
form.Value       interval
form.Value       tolerance
form.Value       idle_timeout
form.Flag        interrupt_exist_connections
```

`outbounds`/`default` 的 option value 使用 section ID；`url` 验证可解析 URL；interval/idle_timeout 使用 `uinteger`；tolerance 使用 `uinteger`；保存前以当前表单值构造 group 并调用 `hp.validateNodeGroup()`。

- [ ] **Step 5: 拦截手工删除和批量删除中的组引用**

覆盖 node GridSection 的删除处理：删除前调用 `hp.findNodeGroupReferences()`；存在引用时通过 `ui.addNotification()` 列出组 label 并拒绝删除。订阅页“Remove all nodes”先计算被引用的订阅节点并拒绝批量删除，不能隐式改写用户组。

- [ ] **Step 6: 运行测试与 JS 语法检查**

```bash
node --test tests/node-group-ui.test.js
node --check htdocs/luci-static/resources/homeproxyce.js
node --check htdocs/luci-static/resources/view/homeproxy-ce/node.js
```

Expected: 全部 PASS。

- [ ] **Step 7: 提交 Task 3**

```bash
git add htdocs/luci-static/resources/homeproxyce.js htdocs/luci-static/resources/view/homeproxy-ce/node.js tests/helpers/load-luci-module.js tests/node-group-ui.test.js
git commit -m "feat: add selector and urltest node editor"
```

---

### Task 4: 路由选择、Clash mode 与旧 URLTest 共存

**Files:**
- Modify: `htdocs/luci-static/resources/homeproxyce.js`
- Modify: `htdocs/luci-static/resources/view/homeproxy-ce/client.js`
- Modify: `root/etc/homeproxy-ce/scripts/generate_client.uc`
- Modify: `tests/generate-client-groups.test.js`
- Create: `tests/client-routing-groups.test.js`

**Interfaces:**
- Consumes: Task 2 的 node section ID → outbound tag 解析。
- Produces: `hp.outboundNodeChoices(nodes, routing_nodes, current_id)`；客户端所有 outbound 选择使用同一候选集合。
- DNS rule 和 route rule 的 `clash_mode` 值域固定为 `direct|rule|global|script`。

- [ ] **Step 1: 写选择列表和生成器的失败测试**

在 `tests/client-routing-groups.test.js` 用真实 `homeproxyce.js` helper 断言候选中包含：`direct-out`、启用的 routing node、新 `selector`/`urltest` node；不包含普通 node、禁用 routing node 或当前 routing node 自身。

在 `tests/generate-client-groups.test.js` 增加：DNS rule 和 route rule 的 `clash_mode: 'global'` 原样输出；同一 fixture 中旧 `routing_node node='urltest'` 生成 `cfg-r1-out`，新 `node type='urltest'` 生成 `cfg-g1-out`，成员节点只生成一次。

- [ ] **Step 2: 运行测试并确认 RED**

```bash
node --test tests/client-routing-groups.test.js tests/generate-client-groups.test.js
```

Expected: FAIL，候选 helper 和 clash_mode 输出尚不存在。

- [ ] **Step 3: 统一 client.js 的 outbound 候选**

把 `proxy_nodes` 的组显示改为仅使用 label，不拼接缺失的 address/port。用 `hp.outboundNodeChoices()` 填充：custom 默认 outbound、routing node upstream、route rule outbound、DNS server outbound、remote ruleset detour 和 Clash UI download detour。

普通 routing node 的 `node` 仍可选择所有 node，包括组；保留特殊 `urltest` 项和其现有 `urltest_nodes/url/interval/tolerance/idle_timeout` 表单。

- [ ] **Step 4: 添加 DNS/route Clash mode 并生成 JSON**

两个 rule 编辑器分别增加：

```js
so = ss.taboption('field_other', form.ListValue, 'clash_mode', _('Clash mode'));
so.value('', _('-- Please choose --'));
so.value('direct', _('Direct'));
so.value('rule', _('Rule'));
so.value('global', _('Global'));
so.value('script', _('Script'));
```

在 DNS rule 和 route rule JSON 对象中加入 `clash_mode: cfg.clash_mode`。不得新建 Clash API section；现有 `experimental.cache_file` 与 `experimental.clash_api` 保持同一对象。

- [ ] **Step 5: 运行相关测试与语法检查**

```bash
node --test tests/client-routing-groups.test.js tests/generate-client-groups.test.js
node --check htdocs/luci-static/resources/view/homeproxy-ce/client.js
git diff --check
```

Expected: 全部 PASS。

- [ ] **Step 6: 提交 Task 4**

```bash
git add htdocs/luci-static/resources/homeproxyce.js htdocs/luci-static/resources/view/homeproxy-ce/client.js root/etc/homeproxy-ce/scripts/generate_client.uc tests/client-routing-groups.test.js tests/generate-client-groups.test.js
git commit -m "feat: route through outbound groups and Clash modes"
```

---

### Task 5: 旧 label 迁移与订阅引用清理

**Files:**
- Modify: `root/etc/homeproxy-ce/scripts/migrate_config.uc`
- Modify: `root/etc/homeproxy-ce/scripts/update_subscriptions.uc`
- Create: `tests/migrate-node-groups.test.js`
- Create: `tests/subscription-group-cleanup.test.js`

**Interfaces:**
- Consumes: Task 1 的 `buildNodeReferenceIndex()` 与 `resolveNodeReference()`。
- Produces: `migrateNodeGroupReferences(uci, config)`，幂等地把唯一 label 转为 section ID。
- Produces: `cleanRemovedNodeReferences(uci, config, removed_ids)`，更新组成员/default 并返回 `{ changed_groups, empty_groups }`。

- [ ] **Step 1: 写迁移失败测试**

用内存 UCI fake 执行真实 `migrateNodeGroupReferences()`：

```js
selector.outbounds = ['Hong Kong', 'n2', 'direct-out'];
selector.default = 'Los Angeles';
```

断言迁移后为 `['n1', 'n2', 'direct-out']`、default 为 `n2`；第二次执行没有 set 调用；duplicate label 和 missing 原值保留并返回 diagnostics，不猜测目标。

- [ ] **Step 2: 写订阅删除失败测试**

用内存 UCI fake 传入 `removed_ids: ['n1']`，断言 `['n1', 'n2']` 变成 `['n2']`，default `n1` 被删除；仅有 `['n1']` 的组保留 section、写入空 outbounds 并出现在 `empty_groups`；普通节点和旧 main/routing URLTest 的既有清理仍执行。

- [ ] **Step 3: 运行测试并确认 RED**

```bash
node --test tests/migrate-node-groups.test.js tests/subscription-group-cleanup.test.js
```

Expected: FAIL，两个脚本尚无可调用的清理函数。

- [ ] **Step 4: 实现幂等迁移**

在 `migrate_config.uc` 的 node options 段之后调用 `migrateNodeGroupReferences(uci, uciconfig)`。只处理 `type in ['selector', 'urltest']`；成功解析的 label 才写回；section ID 和内建 tag 不变；ambiguous/missing 用 `warn()` 输出 section 与 reference。

- [ ] **Step 5: 实现订阅清理并保证失败可诊断**

删除订阅 node 前累计 section ID；删除后调用 `cleanRemovedNodeReferences()`：过滤 outbounds、被移除的 default 用 `uci.delete(..., 'default')`、空组写空列表并通过现有 log 记录组 ID/label。不得删除组，不得自动填 `direct-out`。继续运行现有 main URLTest 和 main UDP URLTest 清理。

- [ ] **Step 6: 运行迁移、订阅及全量 Node 测试**

```bash
node --test tests/*.test.js
git diff --check
```

Expected: 全部 PASS，空组测试证明下一次生成会明确失败。

- [ ] **Step 7: 提交 Task 5**

```bash
git add root/etc/homeproxy-ce/scripts/migrate_config.uc root/etc/homeproxy-ce/scripts/update_subscriptions.uc tests/migrate-node-groups.test.js tests/subscription-group-cleanup.test.js
git commit -m "fix: preserve outbound groups across node lifecycle"
```

---

### Task 6: 翻译、配置样例与完整验收

**Files:**
- Modify: `po/templates/homeproxy.pot`
- Modify: `po/zh_Hans/homeproxy.po`
- Modify: `README`
- Test: `tests/*.test.js`

**Interfaces:**
- Consumes: Tasks 1–5 的最终 UI、生成器、迁移与清理行为。
- Produces: 可构建、可翻译、可按 README 验收的 HomeProxy CE 包。

- [ ] **Step 1: 写完整功能 fixture 并先观察缺口**

在 `tests/generate-client-groups.test.js` 增加一个端到端 fixture：两个普通节点、嵌套 URLTest/Selector、一个旧 routing URLTest、DNS/route clash_mode、启用 Clash API 和 cache file。预期 JSON 同时包含稳定 tags、两种 URLTest、Selector、规则 mode、`experimental.cache_file` 与 `experimental.clash_api`。

Run: `node --test tests/generate-client-groups.test.js`

Expected: 若 Tasks 1–5 已覆盖全部行为则 PASS；若 FAIL，只修复测试揭示的真实集成缺口并记录 RED→GREEN 证据。

- [ ] **Step 2: 更新可见文案和 README**

更新 POT/简体中文翻译中的 Selector、URLTest、Outbounds、Default outbound、Interrupt existing connections、Clash mode 和所有验证错误。README 增加一段不含真实订阅/凭据的说明：section ID 是内部引用、label 可安全重命名、旧 label 会迁移、被引用节点需先从组中移除。

- [ ] **Step 3: 运行全量本地验证**

```bash
node --test tests/*.test.js
node --check htdocs/luci-static/resources/homeproxyce.js
node --check htdocs/luci-static/resources/view/homeproxy-ce/node.js
node --check htdocs/luci-static/resources/view/homeproxy-ce/client.js
git diff --check
```

Expected: 所有命令退出码 0，无 warning/error 输出。

- [ ] **Step 4: 执行可用的包构建或记录环境限制**

优先运行仓库 CI 使用的 OpenWrt SDK 构建流程；若本机缺少 SDK，不伪造成功，保存 GitHub Actions 构建结果。构建完成后在测试固件运行：

```bash
ucode -S /etc/homeproxy-ce/scripts/generate_client.uc
sing-box check -c /var/run/homeproxy-ce/sing-box-c.json
/etc/init.d/homeproxy-ce status
```

LuCI 验收包含：创建/编辑组、刷新后字段保留、节点改名、Clash 面板手动选择、URLTest 延迟、简单/自定义路由、订阅清理、旧 routing URLTest 和普通节点编辑。

- [ ] **Step 5: 提交 Task 6**

```bash
git add po/templates/homeproxy.pot po/zh_Hans/homeproxy.po README tests/generate-client-groups.test.js
git commit -m "docs: document HomeProxy CE outbound groups"
```

- [ ] **Step 6: 分支级复核与交付**

从 `origin/dev` 到 HEAD 生成完整 review package，交给独立 reviewer 检查规格符合性、生成器错误降级、UCI 兼容和测试真实性。修复后重新运行 Step 3；随后推送 `codex/port-homeproxy-ui` 并创建目标为 `dev` 的 PR，附上来源提交 `bulianglin/homeproxy@8d021bf`、迁移规则和验证证据。
