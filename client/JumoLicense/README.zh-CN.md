# 百鸣科技：每个 App 独立卡密

版本 baiming-independent-v4，使用此前 JUMO 授权接口和 v1 Ed25519 签名。每个 App 独立激活、独立保存设备码和卡密。本轮撤销配对及实例数限制需求，原三个动态库和原“巨魔注入.tipa”输入保持原样，修改另行输出。

## 使用

1. 用 GitHub Actions → Build JUMO iOS，编译并下载 JUMO-device-test。
2. 在原注入器中撤销先前配对版整组插件后，向目标 App 注入同一成品包的 JumoLicense.dylib、Cam.dylib、MM.dylib、Sky.dylib，四个库放在相同加载目录。
3. 每个 App 分别输入自己的 JUMO 卡。首次联网通过后记住卡，后续自动续验。月卡起始日期和有效期由原服务器决定，不因重新打开、重复验证延长。
4. 点击插件面板“授权”可查看/复制本 App 设备码，或输入卡重新验证。换卡只有联网成功后才覆盖原卡，失败不会替换当前有效记录。

沿用原注入器，不要求新增共享钥匙串权限；原注入器自身的宿主兼容范围仍然存在。此次回退不构成此前启动闪退的定位或真机修复证明；没有崩溃日志时不能确认原因。

## 卡密和存储

卡密属于本项目之前接入的 JUMO 平台，不切回原作者的旧服务，不使用对话中的旧系统卡密。生产公钥仍从 Config/license-public.b64 编译入库，其 DER SHA-256 为 77b448206f7390f82de60391f7d34480f28e24d15b0428991d42e9587f81d706。

宿主默认私有钥匙串服务为 site.czongz.JUMO.baiming.independent.v4.<宿主 bundle>，关闭同步并使用 AfterFirstUnlockThisDeviceOnly。按 bundle 再分服务名，避免同一团队默认钥匙串组中的不同 App 共用当前记录。

每个 App 持久化自己的设备码。可读取更早 JUMO private v1 的 machine-code，以继续原有绑定，但仍需重新输入卡联网验证。不会导入原作者的卡密或配对版/shared-v2 的共享身份、卡与缓存。配对版已占用的卡不会由客户端自动解绑：请改用该 App 的独立新卡，或让管理员按既有流程处理绑定，卡期不重置。

同一卡已绑定另一 App 的 machine_code 时，原服务端会拒绝，不能通过重新输入实现跨 App 共享。重装可能保留钥匙串；设备码丢失则需要管理员处理旧绑定。本版不承诺物理硬件身份鉴别。

## 接口

端点：
POST https://back.czongz.site/ai/ai_key/card_vip/detail
Content-Type: application/x-www-form-urlencoded; charset=utf-8

仅传 key、machine_code、software_id=JUMO。不传 client_version、installation_id、bundle_id。不再要求配对、实例名额表或 ERP 激活数设置。

v1 签名原文：

~~~
v1|normalizedKey|normalizedMachine|serverTime|graceUntil|expiresAt|ok
~~~

使用现有生产 Ed25519 公钥，标准 Base64 签名，直接验 UTF-8 原文，无预哈希。布尔值必须一致，HTTP 200 仍可能为签名拒绝。服务器时间、宽限和卡期校验保持原规范。v2 响应不是本版可用协议，不能混用配对版服务。

本轮没有修改服务端或 ERP。此前 BACKEND-PROMPT.zh-CN.md 的配对方案已撤销，不执行。如果已经自行部署强制 v2 服务器，需要先恢复 JUMO v1 支持；不要以错误协议上线此客户端。

## 续验

各 App 正常前台使用时随机 55–65 分钟续验，后台不主动轮询。每分钟的本地检查不发网络请求。断网/5xx/408/429 使用指数退避及随机量；429 至少遵循 Retry-After。

已有成功响应必须持续验签、匹配当前卡和设备，并在本机同次启动、可信时间下使用；有效期取本地最多 2 小时、服务端 graceUntil、卡到期三者最早值。无有效缓存的首次激活必须联网。坏签名、格式错误或明确拒绝关闭授权，不允许降级放行。明确拒绝等待用户显式重试，避免自动请求风暴。

停用/解绑通常到下一次在线续验才感知，网络异常时仍受已有有效缓存的硬截止约束，不是实时远程踢下线。请求量按前台活跃 App 实例计算，不再跨 App 去重。

## 构建和验证

Mac + Xcode：

~~~sh
python3 -m pip install -r client/JumoLicense/requirements-test.txt
python3 -m pytest client/JumoLicense/Tests -q
python3 analysis/verify_jumo.py
python3 client/JumoLicense/build.py --public-key-file client/JumoLicense/Config/license-public.b64
~~~

只运行原生协议测试：python3 client/JumoLicense/build.py --test-only。原生测试覆盖 Java v1 向量、输入规范化、全部 C0/C1 控制符、表单编码、签名/卡/设备/时钟篡改、到期、缓存、重启、回拨及退避。

Windows 可运行 Python 准备和 ARM64 检查，也可把源码包上传 GitHub 执行上述 Actions。当前没有在这台 Windows 上生成新版可用动态库；Swift 语法树解析不能替代编译、原生测试或真机验证。

源码打包命令：python client/package_source.py。默认输出 BAIMING-independent-source.zip，并更新两个兼容名称。包内不包含历史配对源码、服务端配对提示词或新版注入器。

真机需验收：原注入器加载四库、启动稳定、首次输入卡、重复验证、不同 App 用不同卡、重开不丢设备码、旧卡绑定处理、换卡失败保留原记录、停用/到期、弱网退避、两小时上限、后台切换及摄像/本地媒体功能。

本轮未调用真实卡激活、后台管理、生产迁移或部署；此前“最新配对版启动就闪退”的用户报告尚无 .ips 日志，原因未确认。

