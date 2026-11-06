# 百鸣科技授权插件：原注入器配对版

源码版本 baiming-pairing-v3，服务端协议 v2。为 Cam/MM/Sky 接入百鸣科技授权界面、手动配对和按小时续验。原三个动态库及“巨魔注入.tipa”输入保持原样，修改另行输出。当前 Windows 环境没有编译出新版可用动态库。

## 使用流程

- 保留原注入器，向目标 App 注入成品包的四个库：JumoLicense.dylib、Cam.dylib、MM.dylib、Sky.dylib。四个库来自同一构建，位于相同的加载目录；不要混用以前共享组版的 JumoLicense.dylib。
- 第一个 App：输入新 JUMO 卡密，配对码留空；联网验证成功后显示配对码，点击“继续使用”进入原有功能。
- 其他 App：填写前一个 App 的配对码，并输入同一张卡密，联网登记成功后各自记住授权。
- 插件面板原徽标位置改成“授权”按钮。授权有效时也可打开管理页，随时查看/复制配对码及当前实例 UUID，随后点击“继续使用”返回。
- 配对码不是卡密，也不是成功授权，只有导入配对码不能解锁。输入错误或联网拒绝不会覆盖已保存的卡、授权编号或有效缓存。
- 不自动读取剪贴板；用户手动粘贴。复制按钮将内容以仅本机方式写入剪贴板，10 分钟后过期；管理页仍可再次查看和复制。

## 身份和数量限制

使用宿主默认私有钥匙串，不指定共享 access group，不要求修改宿主签名增加权限，也不要求新版百鸣注入器。原注入器自身的签名、加载和 App 兼容范围仍然存在，本改动不承诺任意 App 都能注入。

服务名 site.czongz.JUMO.baiming.pairing.v3.<宿主 bundle>，AfterFirstUnlockThisDeviceOnly，关闭同步。每个 App 有持久化 installation_id，bundle_id 来自 Bundle.main.bundleIdentifier。每次验证都提交实例信息，并要求签名绑定该实例及宿主 bundle，别的 App 不能直接复用这份成功响应。

配对码将授权编号编码为 BM1.<无填充 Base64URL UTF8>.<前 8 字节 SHA256 的大写十六进制>；校验和原文是 BM1. 与载荷相连。校验和只防输入错误，不能证明手机身份。配对码和卡一起分享后可在其他手机上登记，用户已接受此限制；激活实例上限只能减少滥用，不能严格保证“一手机一卡”。

已登记实例重复验证不增加数量；上限由服务端/ERP 管理，客户端不固定为 10。达到上限只拒绝新实例，现有实例保留。管理员按“复制 App 实例编号”定位旧记录并撤销，墓碑阻止撤销后自动登记。重装时钥匙串可能保留：编号不变则沿用记录，编号丢失则需新登记。

从更早 private v1 客户端升级时，可保留可读的旧 JUMO 私有授权编号，但仍需重新输入卡并通过 v2 登记。不会读取原作者的授权凭证。上一共享组版的身份不自动读取：已有绑定的用户应从管理员取得原 machine_code 后编码配对码，或由管理员按流程处理整卡解绑；不要把旧响应缓存当作新实例授权。

## 服务端必须先升级

完整可复制提示词：BACKEND-PROMPT.zh-CN.md。本轮没有修改 aiVideo 后端或 ERP，也没有执行生产操作。

端点仍为 POST https://back.czongz.site/ai/ai_key/card_vip/detail，表单在 key、machine_code、software_id=JUMO 外增加 client_version=2、installation_id、bundle_id。

v2 签名原文：

~~~
v2|JUMO|normalizedKey|normalizedMachine|installation_id|bundle_id|serverTime|graceUntil|expiresAt|ok|reasonCode
~~~

Ed25519，直接签 UTF-8，无额外预哈希。reasonCode 位于外层业务 data 中，与 signVersion 同级；详情 data.expiresAt 保持原路径。成功 reasonCode=OK；上限拒绝 ACTIVATION_LIMIT，实例撤销 INSTALLATION_REVOKED。全部原因枚举及事务/迁移/ERP 要求见提示词。

生产公钥从 Config/license-public.b64 编译入库；公钥 DER SHA-256 为 77b448206f7390f82de60391f7d34480f28e24d15b0428991d42e9587f81d706。两个向量文件的公钥都是测试公钥，构建脚本均拒绝用于生产。

运行时始终提交实例并要求 v2。v1 只保留用于原协议回归测试，不能作为线上降级路径。后端未升级时页面明确提示先更新服务，不能直接使用现有 v1 服务上线新版插件。后端升级强制实例登记也意味着旧 JUMO 客户端需同步升级，其他软件保持原协议。

## 续验与服务器负载

- 每个 App 独立随机 55–65 分钟续验，只在前台运行。约每分钟的本地检查只验证本 App 的缓存，不是每分钟联网。
- 每个进程避免重叠请求；失败有持久化指数退避与随机量，429 遵守 Retry-After。明确拒绝不自动反复重试，等待用户点击；重新打开页面不会绕过冷却。
- 每份成功响应实际截止取本地 2 小时、服务端 graceUntil、卡到期三者最早值。重启、系统时间异常、坏签名或明确拒绝都会锁定，不能通过修改缓存延长。
- 断网/5xx/408/429 时仅可继续使用仍有效且独立验签的原缓存。无缓存的首次激活必须联网。停用或撤销通常到下一次在线校验才感知，弱网下最长受 2 小时硬期限约束，并非即时推送。
- 不再跨 App 共享卡密、租期、锁或退避。负载按活跃实例估计：10000 个持续前台实例约 10000/3600=2.8 次/秒的稳态续验，不包括首次登记、失败重试、集中上线；不是按手机数统一去重后的压力。

## 构建

Windows 可上传本包到 GitHub。包含 .github/workflows/build-jumo-ios.yml，运行 Build JUMO iOS，下载唯一所需 Artifact：JUMO-device-test。无需运行历史 build-baiming-injector 工作流。macOS 构建包含真正的 Swift 测试，失败时不能使用残留包。

Mac + Xcode：

~~~sh
python3 -m pip install -r client/JumoLicense/requirements-test.txt
python3 -m pytest client/JumoLicense/Tests -q
python3 analysis/verify_jumo.py
python3 client/JumoLicense/build.py --public-key-file client/JumoLicense/Config/license-public.b64
~~~

只执行原生协议测试：python3 client/JumoLicense/build.py --test-only。测试包含原 Java v1 向量、Python 生成的 v2 跨语言签名向量、配对码、字段篡改、卡期、重启/回拨、硬截止、实例/宿主绑定、禁止 v1 降级和请求字段。协议测试不覆盖 UIKit 或真实钥匙串权限。

源码打包：python client/package_source.py。生成 output/jumo-integration/BAIMING-integration-source.zip 以及兼容别名 JUMO-integration-source.zip；两者都是源码包。历史新注入器源码保留在工作区供查阅，不再放进本次源码包或主构建流程。

## 真机验收

先部署提示词中的服务端变更，再构建、注入并测试：
1. 第一个 App 成功激活后查看/复制配对码，原功能可用。
2. 点击插件“授权”按钮可反复查看，关闭页面后功能继续。
3. 第二个 App 导入配对码并输入卡，服务端显示两个不同实例；重开和续验不增加数量。
4. 错误配对码、换卡、超限、被撤销、坏签名、服务器未升级均不可获得新授权；失败导入保留原授权。
5. 管理员撤销、恢复和调整上限符合提示词规则，原卡期不变。
6. 断网、限流、后台切换、重启、修改时间及最长截止正确；撤销不能靠重开 App 自动恢复。
7. 原注入器可按原流程加载四个库，授权管理按钮可操作，摄像/本地媒体及全部原功能无回归。

本地 Python/ARM64/语法检查不能替代 macOS 原生编译与真机验收。本轮未调用真实卡激活、未执行生产解绑、未部署服务端。

