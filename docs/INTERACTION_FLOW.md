# 工作流交互模式

本文档是 Codex Project Flow 0.14.0 / schema 13 的共享交互设计。机器字段以 `.agents/workflow.json` 为准，角色步骤以 `.agents/WORKFLOW_PROTOCOL.md` 为准。创建可见聊天采用 Codex 默认模型设置；隐藏子代理采用平台默认继承，不附带模型或推理强度覆盖。

## 初始化与规划

```mermaid
flowchart TD
    A["用户授权 Bootstrap"] --> B["当前任务安装并认领永久中枢"]
    B --> C["验证受管文件并登记 hub"]
    C --> D["helper read 读取 plan / state / planning registry"]
    D --> E{"已有可复用或待恢复的规划身份？"}
    E -- "是" --> F["复用或解析同一 real / queued 身份"]
    E -- "否" --> G{"无升级屏障且五名额有空位？"}
    G -- "否" --> H["保持无 registry，等待 gate 打开"]
    G -- "是" --> I["begin 后同一连续动作只创建一次规划聊天"]
    I --> J["立即 bind real threadId 或 queued clientThreadId"]
    F --> K["规划聊天读取 PROJECT_PLAN 与 PROJECT_STATE"]
    J --> K
    K --> O{"计划完整有效，且 STATE 或可信原始记录有明确人类确认？"}
    O -- "是" --> Z["复用计划，等待用户决定启动哪个步骤"]
    O -- "否" --> L["使用 $grilling；不可用则告知并执行协议内置同流程"]
    L --> R["重算 frontier；事实代理不可用则自行只读查证，只冻结依赖节点"]
    R --> S["立即提出其余全部已可决定问题，并逐题给出建议"]
    S --> T["等待用户回答本轮问题"]
    T --> U["保存未决树、问题/回答、事实与下一 frontier 到 STATE"]
    U --> V{"目标、包含/排除、验收标准和步骤明确，frontier 为空且用户确认？"}
    V -- "否" --> R
    V -- "是" --> N["helper save-plan 以双哈希原子保存 plan/state"]
    N --> Z
```

规划聊天允许从不完整想法开始，不要求用户预先给出最终结果。同一轮覆盖全部当前可决定问题，每题附建议；依赖未解决的问题留给后续 frontier。事实助手可并行查询，不阻塞同轮其他可决定问题。每轮保存未决树与下一 frontier，继任从未决处继续。确认绑定的是完整规划理解，不是每份 Markdown 的草稿；未知步骤保持未勾选。只有完整有效且有明确人类确认依据的计划才跳过 grilling；格式合法不等于已确认，已有内容有用但缺项或缺确认时只补问必要内容，不从头重做。

## 规划聊天续接

```mermaid
flowchart TD
    A["用户明确换聊天继续规划"] --> B["STATE 保存唯一 rotation 意图"]
    B --> C["按容量与屏障门创建唯一 gated 后继"]
    C --> D["STATE 保存 real / queued 后继身份"]
    D --> E["planning-continue 用前任 rotation.key 首行，对根 token、精确前任和 generation 做 CAS，并追加 lineage"]
    E --> F["STATE 与 registry 均确认后，前任精确归档"]
    F --> G{"后继是否 queued？"}
    G -- "是" --> H["物化后 planning-resolve 补 real ID，保留 client ID 与 lineage"]
    G -- "否" --> I["后继核对前任归档"]
    H --> I
    I --> J["读取 STATE，从未决 frontier 继续"]
```

`rotation-request` 必须是 helper 按 registry project/current hub/root token/predecessor/下一 generation 严格计算的前任机器 `rotation.key` 精确首行，不是用户描述；lineage 同时保存该代的 `hubThreadId`。hub rebind 后，旧交接按已存 old-hub key 幂等恢复，新交接使用 current hub。任一步失败或结果未知都保留同一次交接并恢复，不重复创建。Bootstrap/Upgrade 读取规划 registry 的当前 generation 与 lineage，不能把已续接前任当作当前规划聊天恢复。

## 请求执行与归档

```mermaid
flowchart TD
    A["用户在永久中枢提出请求"] --> B["中枢生成 requestId，输出理解和执行项"]
    B --> C{"用户确认首次执行授权？"}
    C -- "否" --> B
    C -- "是" --> D{"无升级屏障、名额可用、路径不冲突？"}
    D -- "否" --> E["请求留在中枢排队"]
    E --> D
    D -- "是" --> F["创建当前唯一可见执行任务"]
    F --> G["任务读取 plan/state 并接管请求"]
    G --> H{"目标、范围或验收标准变化？"}
    H -- "是" --> I["当前任务输出新的理解和执行项"]
    I --> J{"用户确认？"}
    J -- "否" --> I
    J -- "是" --> G
    H -- "否" --> K["实施、验证并保存有意义进展"]
    K --> L["输出 changes / verification / uncovered / risk"]
    L --> M{"用户意图？"}
    M -- "验收" --> N["只 accept 明确映射步骤；无映射只保存状态"]
    N --> O["精确自归档，不自动开始下一步"]
    M -- "不同意" --> I
    M -- "continue" --> P["保存后预留名额并创建 generation+1 后继"]
    P --> Q["前任精确归档"]
    Q --> R["后继确认前任已归档后继续"]
    M -- "pause" --> S["保存后归档；无后继、无验收"]
    M -- "含糊归档" --> T["保存并询问 continue 或 pause；暂不归档"]
```

同一请求任何时刻只有一个可执行的当前代。continue 后继继承同一 `requestId`、当前计划步骤和既有边界，generation 加一；它重读工作区，历史验证只算历史证据。名额不足时等待，不能突破五个占位身份。

## 升级协调

```mermaid
flowchart TD
    A["升级任务收到 apply / resume / rollback 授权"] --> B["发布或恢复 provisional 创建屏障"]
    B --> C["穷尽同项目任务元数据并固定活动快照"]
    C --> D{"除中枢与当前升级任务外是否为空？"}
    D -- "否" --> E["零文件事务；保留原升级任务与屏障"]
    E --> F["其他任务各自在原聊天保存并结束、暂停或归档"]
    F --> C
    D -- "是" --> G["屏障推进 active，执行并验证事务"]
    G --> R{"是否为 apply，且中枢交接尚未完成？"}
    R -- "是" --> S["保存唯一新中枢创建意图，只创建一次并绑定 real / queued 身份"]
    S --> T["新中枢加载新版但保持派发关闭；登记 CAS、规范标题与置顶均确认"]
    T --> U["精确旧中枢退役、取消置顶并归档；保留并重绑规划身份"]
    U --> H["交接完成，最终重扫并释放屏障"]
    R -- "否：rollback 或已完成的恢复" --> H
    H --> I{"规划聊天是否需创建或恢复且名额可用？"}
    I -- "是" --> J["durable begin / bind / resolve，不重复创建"]
    I -- "否" --> K["保留经明确确认的完整有效计划，或报告待恢复状态"]
    J --> L["升级任务输出完成项并等待验收"]
    K --> L
```

升级不能强制归档活动执行任务，也不从归档推断验收。apply 在文件验证后自动交接到新中枢，旧中枢只在新登记、规范标题和置顶均确认后精确归档；创建未知、queued 或交接失败保持同一意图和屏障，不重复创建。plan 和 rollback 不更新中枢。事务保留项目事实、计划和状态，规划聊天保留原身份与续接链。屏障释放后可确保规划聊天，但不会自动启动下一项目步骤。

## 角色边界

- 永久中枢：只做新请求初始理解、首次授权、排队和可见任务创建；不长谈项目计划，不接管已移交请求。
- 规划聊天：自动用 `$grilling` 的依赖决策树讨论背景、范围、验收与步骤，保存每轮未决 frontier；不实施计划步骤。
- 执行任务：读取记忆，完成当前请求的确认、实施、验证、同步、验收与归档。
- 升级任务：是升级请求唯一协调执行者，拥有屏障和文件事务，但不替用户结束其他任务。

原生 UI 归档没有可靠的自动拦截能力，也没有稳定的 80% 上下文阈值信号。只有任务收到自然语言 continue/pause/含糊归档意图或其他高可信信号时，才能执行保存与后继流程；流程不承诺避免所有上下文压缩。
