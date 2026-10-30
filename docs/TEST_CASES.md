# Codex Project Flow 0.14.1 测试用例

## 范围

验证 schema 13、八个受管路径、默认模型参数省略、升级时唯一新中枢交接、独立规划聊天、自动 `$grilling` 决策树、双文件项目记忆、五名额、自然语言 continue/pause、验收同步、升级空快照与跨平台事务。未在本轮实际运行的项目不得标记通过。

## 自动化与交互模型用例

本表是验收目标，不是全部通过清单。POSIX 文件事务与 Python 记忆工具可以本机运行；PowerShell 交互模型本机无运行环境，属于未动态覆盖。原生聊天动作另在应用验收中验证。A-62、A-64 至 A-71 是新增规划行为的 forward checks；A-72/A-73 的 registry/helper 子路径由真实临时磁盘测试验证，原生聊天项仍须应用验收。

| ID | 场景 | 预期结果 |
| --- | --- | --- |
| A-01 | 版本与 JSON | `VERSION`、plugin manifest、workflow 和 managed metadata 可解析；版本 `0.14.1`、schema 13 |
| A-02 | 受管路径闭包 | manifest 精确包含八个路径；`PROJECT_PLAN`、`PROJECT_STATE` 为 `seed_once`，memory helper 为插件所有 |
| A-03 | 基线闭包 | 七份保留基线路径集和哈希有效；历史基线不可变 |
| A-04 | 干净安装 | 两平台安装八个路径并部署 schema 13；manifest 自身版本仍为 schema 1 |
| A-05 | 支持窗口升级 | 八个支持源版本均能直接 plan 到 0.14.1；更早或无 manifest 项目拒绝 |
| A-06 | Apply/rollback | 每份保留基线可 apply、validate 并字节级 rollback |
| A-07 | 项目事实保留 | `AGENTS.md` 项目事实段升级后保留，其他托管内容采用目标版本 |
| A-08 | 计划状态保留 | 已有 plan/state 升级后内容保持；缺失文件只 seed 一次 |
| A-09 | Helper 部署 | project-memory helper 随升级采用目标版本，语法与命令帮助通过 |
| A-10 | 初始读取 | 中枢、规划、执行和升级角色启动时都要求读取 plan/state |
| A-11 | 计划结构 | plan 含目标、总体进度和稳定步骤 ID；未验收步骤使用未勾选框 |
| A-12 | 进度计算 | 总体进度只按已验收步骤/总步骤计算，不能由代码存在或历史输出推进 |
| A-13 | 状态结构 | state 保存当前步骤、决定、结果、验证、阻塞、待验收、未完工作、下一行动和续接身份 |
| A-14 | Helper read | 只读返回两个文件的结构化状态，不修改内容 |
| A-15 | Helper save | 有效输入按预期 state 哈希原子保存状态；结构、哈希或路径边界错误时零写入 |
| A-16 | Helper accept | 只勾选精确步骤并同步状态；未知、重复或未确认步骤拒绝 |
| A-17 | 保存失败门 | memory 写入失败时禁止归档和继任创建 |
| A-18 | Planning begin | 首次调用原子建立 `creating` intent，返回 `create` 和唯一 token |
| A-19 | Planning begin 幂等 | 同项目重复调用返回 `reuse`/`recover`，token 不变且不授权第二次 create |
| A-20 | Planning bind real | exact token 绑定一个真实 ID；换 token/项目/中枢或第二身份拒绝 |
| A-21 | Planning bind queued | exact token 绑定一个 client ID，queued 占一个名额且不能交给 ID-only API |
| A-22 | Planning resolve | exact token/client/real 三元组把 queued 原子解析为 real；错误三元组零变化 |
| A-23 | Unknown create | 创建结果未知时保留 creating intent；后续只能恢复同一身份，创建计数不增加 |
| A-24 | Planning registry 验证 | schema 含 `reboundFromHubThreadId`；控制字符、额外字段、跨项目/跨中枢矛盾、非法状态均失败关闭 |
| A-25 | Bootstrap 自动规划 | fresh bootstrap 完成 hub 后先证明 gate，再 begin 并在同一连续动作中只创建一个规划聊天 |
| A-26 | Bootstrap 授权边界 | 初始化授权覆盖 planning 创建和八个受管文件，不覆盖实施计划步骤 |
| A-27 | Hub fast path | 有效 hub 与 planning real 登记只定向读取，不扫全量任务 |
| A-28 | Planning create gate | registry 缺失时先穷尽元数据；满五、路径/身份不明或 provisional/active 屏障时不调用 begin、零 registry、零创建 |
| A-29 | 精确项目 ID | `create_thread` 之前完整项目列表精确匹配路径/ID；模糊名称或矛盾停止 |
| A-30 | 能力降级 | 缺 listing/read/create/identity/mutation 任一必需能力时停止，不伪造证据 |
| A-31 | 渐进规划 | 规划允许不完整背景进入；未知目标或步骤保留 draft/unchecked，不要求预先最终结果 |
| A-32 | 目标步骤确认 | 用户确认后规划聊天以 helper `save-plan` 双哈希 CAS 原子保存 plan/state；无逐文件 gate |
| A-33 | 经确认计划复用 | 升级或重启仅在 plan 完整有效且 STATE/可信原始记录有明确人类确认依据时跳过访谈；格式合法不算确认，已有内容可用时只补问缺项/确认而不从头重做 |
| A-34 | 五名额 | 规划、active、blocked、waiting、queued、awaiting_acceptance 均占位；hub 不占；总数不超五 |
| A-35 | 中枢移交 | requestId 和首次执行项获批后只创建当前代一次；身份建立后中枢退出请求 |
| A-36 | 当前代唯一 | 同一请求只有一个可工作的 current generation；修改轮次不新建任务 |
| A-37 | Continue 保存顺序 | continue 先 save，再在有保留名额时创建 generation+1 |
| A-38 | Continue 归档门 | 后继在 exact predecessor 归档确认前不得工作；归档失败时后继保持 gated |
| A-39 | Continue 容量 | 已有五占位时不创建后继，保持当前任务等待；任何瞬间不超过五 |
| A-40 | Pause | save 成功后归档当前任务，不创建后继、不标记验收 |
| A-41 | 含糊归档 | save 后询问 continue/pause，未澄清时归档计数和创建计数均为零 |
| A-42 | 验收 | 明确接受只同步对应步骤和 state，精确自归档，不创建下一步骤任务 |
| A-43 | 验收失败 | accept 或 archive 返回错误 ID/失败/未知时保持待验收且不释放名额 |
| A-44 | 历史验证 | 继任读取历史证据但必须重新核对工作区和执行需要的本轮验证 |
| A-45 | 冲突旧代清理 | 仅清理同请求且证明永不可继续的冲突旧身份；当前代和新范围补充不受影响 |
| A-46 | 升级 provisional 竞态 | barrier 在空快照前发布；期间 hub 与 planning 创建数均保持零 |
| A-47 | 升级非空快照 | 任一规划或执行占位使文件事务计数为零；升级任务不归档、不建后继 |
| A-48 | 升级恢复 | blockers 各自保存并归档后，原升级任务重新穷尽元数据并继续同一 claim |
| A-49 | 升级记忆保留 | apply/rollback 保留 facts/plan/state，未知步骤不被勾选 |
| A-50 | 升级后规划 | verified transaction 与 final scan 后先 release；再按容量 begin/reuse/recover/create planning |
| A-51 | 升级后不自动执行 | planning 恢复不开始下一步骤；无映射的升级验收不勾任何项目步骤 |
| A-52 | Barrier 与规划失败隔离 | barrier released 后 planning 因容量/能力失败只报告待恢复，不恢复 active barrier |
| A-53 | 文档规则 | 本轮更新 Markdown 首标题为 `#`、标题不跳级；无草稿哈希状态残留 |
| A-54 | 原子性 | 最终验证、备份认证、内容漂移、锁竞争失败时不留下部分事务 |
| A-55 | 跨平台对等 | PowerShell/POSIX 的 install/plan/apply/validate/rollback 与 helper 结果一致 |
| A-56 | Skill 闭包 | Bootstrap/Upgrade/Manager 技能与 references 全部在插件清单内并通过快速验证 |
| A-57 | 发布卫生 | JSON、PowerShell、Shell、Python、Mermaid、差异格式和工作区范围检查通过 |
| A-58 | Planning rebind | 仅正式 hub replacement 的退役与 owner 锁释放成功后，exact old hub/token/task 可原子改为 new hub；记录 `reboundFromHubThreadId`、返回 `rebound`，规划身份保持且零创建 |
| A-59 | Planning rebind 失败关闭 | queued 无可信原始创建证据、跨项目/原始 key 不符、token 或 old hub 不符时保留旧登记，不凭标题迁移 |
| A-60 | 并发计划合并 | `save-plan` 保留已有勾选/稳定 ID、拒绝新增勾选；任一 hash 漂移时零写入并要求重新合并 |
| A-61 | 非标准旧计划 | `read` 返回 unsupported warning；`save-plan` 仅接受全 unchecked candidate，并把旧有效信息合并进 state |
| A-62 | 自动 Grilling | 新建或不完整计划自动主动使用 `$grilling`；完整有效且有明确人类确认依据的计划直接复用，缺确认时只补问必要内容 |
| A-63 | 原生项目 ID | `local-*` 等 opaque exact projectId 可用；控制字符、路径/ID 矛盾仍拒绝 |
| A-64 | 依赖决策树 | 每个规划决定记录依赖；前置未决的问题不进入当前 frontier，回答后重新计算 |
| A-65 | 完整 Frontier 轮次 | 每轮一次列出全部当前可决定问题，每题含建议，然后停止并等待用户回答 |
| A-66 | 事实助手 | 环境/代码事实由事实助手查询而非询问用户；只暂停其下游分支，同轮其他 frontier 继续 |
| A-67 | 规划状态持久化 | 每轮把未决树、问题/回答、事实和下一 frontier 保存到 state；继任从未决节点继续且不重复已答问题 |
| A-68 | Save-plan 完成门 | 目标、包含/排除、验收标准、步骤明确，frontier 为空且用户确认共同理解后才允许 `save-plan` |
| A-69 | 未完成规划 | 任一完成字段、用户确认或树分支仍未决时保持讨论状态，不保存最终计划、不启动执行 |
| A-70 | Grilling 打包与恢复 | 正常包包含上游 `grilling` 和 `grill-me` 入口及许可，源文件哈希符合固定版本；技能缺失或名称错误时校验失败；规划提示传递实际技能路径。仅旧路径或安装损坏时告知异常再执行协议兼容流程；事实代理不可用时自行只读查证 |
| A-71 | Planning continue 顺序 | STATE 先保存 rotation 意图及所得 real/queued 身份，再以根 token、精确前任、预期 generation 和前任 `rotation.key` 精确首行 CAS registry，最后归档前任 |
| A-72 | Planning continuation 唯一性 | `planning-continue` 严格校验由 project/current hub/root token/predecessor/下一代组成的 `rotation.key`，只推进一个 generation 并保存该代 `hubThreadId`；相同交接在 hub rebind 后仍按原 key 幂等，不同 tuple 零写入 |
| A-73 | Queued continuation | queued 后继的 `planning-resolve` 补 real ID 且保留 client/lineage；Bootstrap/Upgrade 跟随当前代，不恢复旧前任 |

## Codex 应用验收

| ID | 场景 | 预期结果 |
| --- | --- | --- |
| C-01 | Fresh Bootstrap | 当前任务成为永久中枢，另有一个可见规划聊天，二者项目绑定精确 |
| C-02 | Queued Planning | 返回 client ID 后不重复创建；物化时解析为唯一 real ID |
| C-03 | 不完整想法 | 用户只提供背景时规划聊天继续提问，不要求立即给最终结果 |
| C-04 | 计划确认 | 用户确认目标/步骤后两文件正确写入，步骤仍未验收勾选 |
| C-05 | 普通请求 | 中枢先确认执行项，再创建一个当前代任务并完全移交 |
| C-06 | Continue | 自然语言“保存并继续到新聊天”创建一个 gated 后继，前任归档后才运行 |
| C-07 | Pause | “保存并暂停归档”只保存和归档，无后继且计划不误勾 |
| C-08 | 含糊归档 | “归档一下”触发 continue/pause 追问，任务仍保持打开 |
| C-09 | 最终验收 | 只勾对应步骤、同步 state、归档当前任务，不自动启动下一步 |
| C-10 | 五名额 | 规划聊天加四个占位后，新请求/后继排队；释放后恢复且不超限 |
| C-11 | Upgrade 非空快照 | 原升级任务保留 provisional，现有任务在各自聊天结束，零强制归档 |
| C-12 | Upgrade 完成 | 0.12.0 / 0.13.0 到 0.14.0 保留 facts/plan/state，中枢交接完成后才释放 barrier 并恢复 planning |
| C-13 | 任务 API 缺失 | 能力不全时明确失败关闭，不宣称创建、绑定、保存或归档成功 |
| C-14 | UI/上下文信号限制 | 无消息直接点击归档或缺少可靠 80% 阈值信号时，不承诺自动保存或避免所有压缩 |
| C-15 | Plugin cache | 新任务加载最终 cachebuster，技能内容来自发布后实际安装版本 |
| C-16 | 原生列表完整性 | 普通列表 non-pinned 数小于 `limit<=50` 且无 unavailable 才完整；命中上限失败关闭；归档 cursor 走到 null；本机只读正常列表不代替边界分支演练 |
| C-17 | 已归档规划聊天 | 完整有效且有明确人类确认依据的计划默认保持规划聊天 archived；缺失、不完整、缺确认或用户要求讨论时精确 unarchive；本机尚未执行 |
| C-18 | 自动启动 Grilling | 新规划聊天无需用户点名 skill 即进入依赖决策树；已有计划只有在完整有效且有明确人类确认依据时才跳过，缺确认时只补问必要内容 |
| C-19 | 多问题轮次 | 同一轮展示全部已可决定问题及逐题建议，提交后等待用户回答再展开下一 frontier |
| C-20 | 事实与决策分工 | 可查事实由助手获取并回填；用户只回答决策，其他不依赖该事实的问题照常提出 |
| C-21 | 规划继任 | 规划聊天续接后从 state 中的未决树和下一 frontier 继续，不重问已记录答案 |
| C-22 | 规划完成门 | 完整范围与验收标准、空 frontier 和用户明确确认共同满足后才 `save-plan`；任一缺失时继续讨论 |
| C-23 | Grilling/事实助手降级 | Skill 或事实代理缺失时明确告知并按同一内置流程推进，只读查证失败则保存未决事实 |
| C-24 | 规划聊天续接 | real 后继身份写入 STATE 后，registry CAS 到唯一下一代，前任归档确认后才继续未决 frontier |
| C-25 | Queued 规划续接 | queued 身份先进入 STATE 与 lineage，物化后精确 resolve；重启 Bootstrap 不回到旧前任 |
| C-26 | 默认模型 | 创建和后续唤醒省略模型/推理覆盖；可见聊天采用 Codex 默认，隐藏代理按平台继承，不修改全局配置 |
| C-27 | 升级中枢创建恢复 | begin 一次持久意图；unknown/queued/重启只恢复同一身份，不能重复创建或把升级任务变成中枢 |
| C-28 | 中枢 CAS 与退役 | 精确原始 registryToken 对接引擎；CAS 冲突不退役旧中枢；CAS 后未 checkpoint 的中断可恢复 |
| C-29 | 交接完成门 | 新中枢版本、登记、标题、置顶确认后才退役旧中枢；退役失败保留锁/屏障；规划 root token 和 lineage 不变 |
| C-30 | 预览与回滚 | plan 和 rollback 不创建或替换中枢；新中枢在屏障 released 前不派发项目任务 |

## Windows 锁释放回归

- 正确 owner 释放后锁文件消失，其他 owner 可重新获取。
- owner、project ID 或项目路径不匹配时拒绝释放并保留原锁字节。
- 另一进程持有独占句柄时，读取、释放与重复获取均不能绕过互斥。
- 标记删除后、关闭句柄前，旧引擎风格的独占打开及竞争获取仍被拒绝；关闭后才允许新建。
- replacement 准备阶段及未确认旧中枢退休时拒绝释放；确认后正常删除。
- acquire 无效参数及 replacement prepare 的错误 CAS token 不遗留新锁；竞争失败不删除他人锁。

## 验证记录

### 0.14.1：Windows 修复验证（2026-10-11）

- 本机 Windows 10（10.0.19045）/ PowerShell 7.6.5：先复现 `current owner could not release lock`，修复后 `tests/test-bootstrap-engine.ps1` 与完整 `tests/test.ps1` 均退出 0。
- 完整入口覆盖八份基线升级、计划/状态保留、字节级回滚、引擎互斥与锁恢复；记忆测试 22 项运行、21 项通过、1 项因 WinError 1314 缺少符号链接权限跳过；模型策略 5/5、中枢交接引擎集成 6/6 通过。
- `tests/test-parity.ps1 -BaselineVersion 0.14.0 -RequirePosix` 退出 0：8 受管文件、2 类锁；实际 Windows PowerShell/Git Bash/Python 引擎互操作。
- PowerShell 5.1.19041.6456 与 7.6.5 的原生句柄冒烟验证通过：标记删除后其他打开仍失败，关闭句柄后锁文件消失。没有声称完整 Windows PowerShell 5.1 回归。
- Python 测试夹具改为明确字节写入，并在同一 read 测试中覆盖 LF 与 CRLF 原文和原始字节 SHA-256；生产记忆 helper 不变。Windows 集成用例实际调用 PowerShell，不再依赖 `sh` 或跳过引擎检查。
- 源码 validator、基线认证与差异检查通过；新增 GitHub Actions Windows/Linux 持续回归，远端结果以该提交的 Actions 记录为准。
- 本轮不覆盖真实 Codex 任务 API 的模型选择、置顶、归档及完整中枢交接；不模拟磁盘写入故障，不自动升级其他项目。

### 0.14.0：历史验证

以下为历史版本证据，不替代 0.14.1 本轮验证。

2026-10-11，0.14.0 本轮源码 validator、完整 POSIX 回归和本机 macOS PowerShell 7.6.6 完整回归均退出 0。两套入口均覆盖七份历史基线升级、plan/state 保留和字节级 rollback；记忆测试 22/22、默认模型策略测试 5/5、新中枢交接集成测试 6/6 通过。Bootstrap/Upgrade Skill 格式验证及差异检查通过。

临时 JSON 状态文件的续接、验收和中枢交接模拟属于协议检查，不是原生任务 API 测试。模型规则测试包含实际 POSIX 验证器的有效输入与四种无效契约拒绝；它不证明原生聊天实际选择的模型。回滚采用恢复后的兼容 helper 与规则，不补建已移除文件。

PowerShell 本轮是在 macOS 执行 `.ps1` 的动态回归，不等于 Windows 原生认证。Windows 原生运行及 Windows/Git Bash 跨引擎差分仍未覆盖；新增六项交接测试实际调用 POSIX 引擎，不能冒称为原生聊天接口或 Windows 交接验证。

0.13.0 曾在隔离临时项目实际创建中枢和规划聊天，验证双文件读取及首轮主动访谈；用户随后自行归档并取消独立演练，选择在真实项目日常使用中验证。0.14.0 的原生新中枢交接与模型选择尚未在实际项目验收；本轮不恢复已归档测试聊天，也不自动升级其他项目。仅更新本机插件，不提交或推送远程。

## 0.14.2 本机验证：2026-10-11

- 原版 Matt Pocock grilling 固定在提交 `49dd158d1076134a641b33efb035946536778336`；技能及许可字节与记录哈希匹配，grill-me 仅入口调用做 Codex 适配。
- Windows PowerShell 完整回归通过：记忆 21 项通过、1 项因符号链接权限跳过，模型策略 5/5、包测试 6/6、中枢交接 6/6。
- Git Bash/POSIX 包测试 6/6 通过；0.14.1 基线跨引擎差分通过，覆盖 8 受管文件及 2 类锁。
- 安装到本机后，缓存五个第三方文件哈希符合 provenance；原生 Codex skills/list 返回两个带插件前缀的技能，均启用且路径为 0.14.2。
- 本轮未运行 Linux 全量回归或真实用户访谈。CI 配置已更新，但未推送运行；文件存在和原生可发现性不等于访谈行为已验收。

## Drawio 技能验收场景（0.14.3）

- D-01：已有文件仅修改指定 page 的填充色。保留文字、其他页面和关系；渲染最新内容并内存回传。
- D-02：用户直接给定按钮文案并要求填入，不再重复请求同一文案批准。只有本地 PNG 导出能力时不得偷偷落盘，明确图片回传与视觉检查未完成。
- D-03：参考截图重建需区分重建与恢复；自行拟定的完整文案和未确认业务关系先评审，不能由布局推断关系。设计未定或部署目标不明时不执行上线。
- D-04：技能随插件安装；缺少技能文件、名称错误、空描述或错误技能发现路径时，两端源码校验拒绝通过。
- D-05：每轮分别记录文案、图形和整体设计认可范围；局部认可不勾选总体步骤，图稿手动修改须从最新内容接续。

本轮范围为技能整理和工作流集成。行为走查属于模拟决策检查，不等于真实图稿编辑、原生渲染或手机端图片展示验收。

### 0.14.3 本轮结果：2026-10-13

Skill Creator 和源包 PowerShell 校验通过。两端包测试各 6/6 通过（PowerShell 21.185 秒、Git Bash/POSIX 5.448 秒）；0.14.2 基线跨引擎差分通过（8 受管文件、2 类锁）。三个模拟场景走查符合授权及输出限制。安装后原生 skills/list 识别并启用 codex-project-flow:drawio-review，路径为 0.14.3；Skill、UI 元数据和三份工作流规则均与源码一致。未进行真实图稿渲染或手机评审，未重复此前无关全量回归。

## 0.14.4 工具发现验证：2026-10-18

- 在当前 Windows 会话通过 Code Mode ALL_TOOLS 发现原生 list_projects、set_thread_title、create_thread、move_thread_to_sidebar_section 等接口，读取其真实调用定义；只读 list_projects 调用成功，返回 PlcEAP 的精确已保存路径及原生 ID。未修改 PlcEAP 文件或聊天。
- 两端插件包专项各 7/7 通过，含必需 native-tools.md 缺失时拒绝通过。模拟走查覆盖工具延后可发现且无预先ID、create_thread缺失、list_projects访问被拒绝三种情境。
- 走查发现“ALL_TOOLS保证完整schema”的表述过强，已修正为仅保证元数据，必须确认真实调用契约；无契约不猜参数。
- 未实测原报错聊天，不将当前会话成功当作该聊天已恢复；未试改标题或创建规划聊天，不声称完成新项目端到端初始化。

## 指导式编程场景（0.15.0）

- G-01：先共同确认架构，复用已有确认；本轮只给一个接口或关键逻辑的聊天代码方案，说明真实文件位置及原因，等待用户写入或提问。
- G-02：用户选择性复制修改后，重读实际实现再检查自测；建议已给出、用户称已写入、实际文件已观察和本轮验证通过必须区分。
- G-03：测试失败时在聊天说明原因和修正片段，源码不被助手自动修复；新增持久测试代码也由用户写入。检查脚本不能暗中执行auto-fix、安装或生成源码。
- G-04：普通“继续”只推进当前聊天的一个小目标，未写入或当前实现失败时不能跳过；明确换聊天继续才创建受门控继任，恢复不重复消费旧继续指令。
- G-05：检查自测由Codex执行，其他项目操作给用户步骤；必要自测产物隔离。既有Bootstrap/Upgrade事务、项目记忆和聊天管理按精确授权执行，保留身份/锁/并发保护。
- G-06：包完整性校验要求guided-coding技能及UI元数据，缺失/错名/空描述应拒绝；0.14.4的已部署计划和状态升级时保留。

### 2026-10-29 本轮证据

Skill Creator校验通过，两端包专测各7/7通过。独立模拟项目中实际运行已有2项单元测试，观察到正数通过、负数拒绝失败；助手在聊天给出修正方案并停留当前目标，未开展后续配置支持。被测源码及测试文件前后SHA-256均保持原样，无额外缓存或配置写入。该失败是模拟夹具故意保留的实现问题，证明流程会报告问题而非自动修改用户代码；不是插件回归失败。自测钩子、继续与受管事务仅做只读情境走查，未实测npm或真实聊天换代。完整Windows回归与跨引擎升级检查结果见项目状态，不把旧轮次结果当作本轮结果。

完整Windows回归退出0：记忆21通过/1符号链接权限跳过、模型策略5/5、包7/7及中枢交接6/6。收紧两句暂停文案后，最终源包校验和0.14.4->0.15.0跨引擎差分再次通过（8受管文件、2类锁）；单纯暂停讨论不归档。原生skills/list已识别并启用codex-project-flow:guided-coding。本轮未执行Linux全量CI或真实用户指导编程验收。
