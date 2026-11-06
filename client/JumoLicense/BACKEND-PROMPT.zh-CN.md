# 服务端实施提示词（整段复制给负责 aiVideo 的编程助手）

请修改 `D:/code/aiVideo` 的 JUMO 软件授权服务及 ERP。先阅读仓库 AGENTS.md，沿用已有 Java 17 / Spring / MyBatis 和 ERP Vue 3 / TypeScript 结构，做最小修改并完成测试。只实现和验证，不部署、不操作生产数据库、不激活真实卡、不输出私钥或卡密。

客户端已在 `D:/code/jumo/client/JumoLicense` 改为“原注入器 + 手动配对 + App 安装实例登记”。请以本文的协议为准，不另设计不兼容的字段或签名顺序。客户端源码版本是 `baiming-pairing-v3`，线上协议版本是 `v2`，两者不要混淆。

## 产品规则

1. 同一卡密仍只绑定一个 `machine_code`，但现在这个字段表示可转移的“授权编号”，不承诺物理手机身份。其他 App 导入配对码后，会提交同一个 `machine_code`，但有各自独立的 `installation_id` 和宿主 `bundle_id`。
2. 配对码由客户端本地编码授权编号，并带输入错误校验和，不包含卡密、实例编号、授权签名。服务端无需生成或解析配对码，也不能把配对码当作授权凭据。
3. 每张 JUMO 卡增加 `max_activations`，默认 10，ERP 可以为每张卡调整，范围 1–1000。只限制目前状态为 active 的 App 安装实例总数，不限制累计启动次数或联网验证次数。默认 10 是本次产品默认值，不要写死在插件中。
4. 第一个 App 也占一个名额。同一实例重复验证、插件更新、App 启动、后台切换、55–65 分钟续验均不新增计数。钥匙串可能在重装后保留：编号保留则仍算同一实例；编号丢失则是新实例，需要管理员解绑旧条目。
5. 达到上限只拒绝新实例，已经 active 的实例可正常续验，不自动踢出任何实例。调低上限也不自动踢出；新登记在 active 数低于上限前持续拒绝。
6. 管理员可查看卡下的实例列表、解绑单个实例、恢复被解绑实例。解绑采用 revoked 墓碑记录，立即释放 active 名额，但不能删除记录后让被解绑客户端下次校验又自动登记。恢复也要检查上限。
7. 卡整体解绑应同时撤销全部 active 实例，保留审计与原到期时间；旧实例不会自动恢复。新授权编号下的新实例仍按规则登记。任何解绑、恢复、调限都不延长卡期。
8. 此方案降低分享滥用，不能保证实例都在同一手机，也不能抵抗修改客户端后复用实例编号。不能以 IP、IDFV、客户端提供的 UUID 宣称识别了真实手机。不要增加基于 IP 的硬性换机判定。

## 先检查这些现有文件

- `backend/docs/license/巨魔接入说明.md`
- `backend/ruoyi-ai/src/main/java/com/ruoyi/ai/service/impl/AiLicenseServiceImpl.java`
- 同目录 `AiLicenseSigner.java`、`AiLicenseRateLimiter.java`
- `backend/ruoyi-ai/src/main/resources/mapper/ai/AiLicenseMapper.xml`
- `backend/ruoyi-ai/src/main/java/com/ruoyi/ai/domain/AiLicenseCard.java` 及 BO / VO / Mapper / Service
- `backend/ruoyi-admin/src/main/java/com/ruoyi/web/controller/ai/AiLicenseClientController.java`
- ERP 的 `src/api/system/aiLicense.ts`、`src/types/api/system/aiLicense.ts` 及软件授权页面
- 现有服务、控制器授权测试和 SQL migration

## 与客户端严格匹配的接口

继续使用：

```text
POST /ai/ai_key/card_vip/detail
Content-Type: application/x-www-form-urlencoded; charset=utf-8

key=<卡密>
machine_code=<授权编号>
software_id=JUMO
client_version=2
installation_id=<大写 UUID>
bundle_id=<宿主 Bundle ID>
```

- 卡密、授权编号继续复用现有 Java 规范化、长度、控制字符校验，保持原有大小写规则。`software_id` 必须严格等于 `JUMO`。
- `installation_id` 为客户端普通私有钥匙串持久化的 UUID，校验大写标准 `8-4-4-4-12` 格式，不自动换大小写；客户端已发送标准大写形式。
- `bundle_id` 保留大小写，ASCII `[A-Za-z0-9._-]{1,255}`，不 trim，不含 `|`。同一登记实例的 bundle 不允许修改。
- JUMO 必须强制新版登记协议。缺少或错误的 `client_version` / 实例字段应拒绝，不能继续通过旧 v1 JUMO 请求绕过数量限制；其他软件原有协议和行为保持兼容。旧 JUMO 客户端会因此需要更新，要在交付说明中写清切换影响。
- 规范化输入后的业务拒绝继续 HTTP 200、外层 `code=200`，两个布尔值均为 false，附带有效 v2 签名；格式错误可以返回 HTTP 400。HTTP 429 保留 Retry-After，不能缓存授权响应。

成功响应结构（时间值为示例，不是固定值）：

```json
{
  "code": 200,
  "data": {
    "status": true,
    "canUse": true,
    "serverTime": 2000000000,
    "graceUntil": 2000007200,
    "signVersion": "v2",
    "reasonCode": "OK",
    "sig": "<标准 Base64 的 64 字节 Ed25519 签名>",
    "data": { "expiresAt": 2002592000 }
  }
}
```

保留已有其他展示字段没问题，但客户端只凭已验签字段放行。可以在 ERP 内展示激活数，插件目前不读取或依赖服务器返回的数量展示字段。

v2 签名原文为以下各字段的 UTF-8，使用 `|` 连接，无空格、无结尾换行：

```text
v2|JUMO|normalizedKey|normalizedMachine|installation_id|bundle_id|serverTime|graceUntil|expiresAt|ok|reasonCode
```

- `ok` 是字符 `1` 或 `0`；status 与 canUse 必须完全一致，且必须为 JSON boolean。
- 成功时 `reasonCode=OK`；拒绝时必须是下面之一，不能为 OK：
  - `INVALID_CARD`：不存在或无效卡。
  - `SOFTWARE_MISMATCH`：软件不匹配。
  - `DISABLED`：卡或软件停用。
  - `EXPIRED`：卡已过期。
  - `MACHINE_MISMATCH`：卡绑定的授权编号不匹配。
  - `ACTIVATION_LIMIT`：新实例达到上限。
  - `INSTALLATION_REVOKED`：此实例已被管理员撤销。
  - `INSTALLATION_MISMATCH`：既有实例的 bundle 不匹配。
  - `CLIENT_UPGRADE_REQUIRED`：可构造规范 v2 响应时的客户端升级拒绝。
- 拒绝响应签名也绑定本次请求的卡、授权编号、实例及 bundle，`graceUntil=0`、`expiresAt=0`。
- 所有时间为整数 Unix 秒，范围 0–9007199254740991；永久卡 expiresAt=0。
- 使用现有生产 Ed25519 私钥直接签名，不做额外预哈希、不换密钥、不在代码中添加私钥。客户端配置的现有 SPKI DER 公钥 SHA-256 为 `77b448206f7390f82de60391f7d34480f28e24d15b0428991d42e9587f81d706`。
- 新客户端不接受 v1 响应，不允许服务端悄悄回落 v1。签名中增加软件、实例、bundle 和原因是必要协议变更，禁止只在旧请求里加字段但仍签旧原文。
- 沿用已有最长 72 小时 graceUntil 约束，不能超过卡到期；建议至少覆盖正常 65 分钟续验间隔。客户端本地另设最多 2 小时硬截止，实际以更早的服务端宽限和卡到期为准。

## 数据结构和事务

1. 用新增 migration 扩展卡表上限，并增加实例表，例如 `ai_license_installation`，包括 ID、license_id、installation_id、bundle_id、active/revoked 状态、首次登记、最后成功验证、撤销时间、操作人等。设置唯一约束 `(license_id, installation_id)` 和按卡统计 active 的索引。字段长度、排序规则应与协议严格匹配，bundle 比较大小写敏感。
2. 沿用现有卡行 `SELECT ... FOR UPDATE`。在同一事务中锁卡、取锁后时间、验证卡/软件/授权编号、检查实例、检查数量、首次计时/绑定、创建实例、签名。管理员调限/撤销/恢复也要锁同一卡行，保证并发下不超额、不错误占位。
3. 有 active 行：验证 bundle 相同后续验，不增加数量，即使已达到或超过新上限仍通过。revoked 行：签名拒绝，不自动恢复。不存在：统计 active，达到上限则拒绝；否则创建。
4. 无效卡、换授权编号、过期/停用、超额、实例不匹配都不得消耗名额、错误绑定或启动卡期。签名失败必须使本次新增实例和首次激活全部回滚。
5. 月卡仍每月 30 天，首次成功激活才计时；同卡在其他 App 新登记不会重新计时。管理员续费和原有审计语义继续保留。
6. 不存明文卡密，不把明文卡、配对码写进日志或审计；沿用现有卡哈希存储。实例列表只暴露给有权限的 ERP 管理员。
7. 不新增每次校验查全量列表等低效路径，不引入客户端每 5 分钟心跳。签名/锁卡事务应保持短小。超限拒绝和 revoked 拒绝不写重复激活审计；普通续验可更新 last_seen，避免无限日志增长。

## ERP

- 卡片/卡列表增加“已激活实例 / 最大激活数”，支持创建时和后续修改 max_activations，默认 10；其他软件页面不强加这套产品规则。
- 卡详情增加实例列表：实例 UUID、bundle、状态、首次登记、最后验证时间；可按 UUID 查询，方便用户从插件「复制 App 实例编号」后定位。
- 增加单实例撤销、恢复操作及权限、审计，恢复时上限检查。保留既有整卡停用、续费、解绑操作。
- 调低上限若低于现有数量应明确展示“既有实例继续可用，新增实例受限”。

## 必须验证

- 两个不同 bundle / UUID 使用同卡同授权编号可登记；每个新实例只加一次。
- 第 N 个成功、第 N+1 个签名拒绝 ACTIVATION_LIMIT；既有实例到上限后仍能续验。
- 同一实例并发请求只登记一次；多个新实例同时抢最后一个名额时只有一个成功。不能只靠 JVM synchronized，应验证数据库事务及唯一约束。
- revoked 释放名额，被撤销实例不能自动重新登记；恢复需检查空位；调低上限不会自动踢人。
- 换卡/授权编号、bundle 不匹配、停用、过期、超额及签名异常均不会错误计数或延长卡期；签名异常回滚首次激活。
- v2 任一卡/授权编号/实例/bundle/软件/时间/ok/reasonCode 篡改都验签失败；缺少实例的旧 JUMO 请求不能绕过限制；其他软件旧测试继续通过。
- 使用客户端提供的 `D:/code/jumo/client/JumoLicense/Tests/pairing-test-vectors.json` 作为跨语言验签/原文对照向量，其中公钥仅用于测试，不能替换生产公钥。保持旧 Java v1 向量测试。
- 客户端正常 55–65 分钟续验，因此停用或解绑通常要到下一次联网才被感知；网络故障时，已有租期最多延续 2 小时且不能超过卡期/宽限。不得对外承诺即时远程踢下线。

执行对应后端测试及编译、ERP 构建，更新 `backend/docs/license/巨魔接入说明.md`，交付 migration、变更清单、协议示例和验证结果。若环境缺少数据库等依赖，明确报告未执行的验证，不假称通过。交付部署顺序应为先完成迁移并部署支持 v2 的服务，再让新版插件接入；提示旧 JUMO 客户端需同步升级。不要替用户部署。
