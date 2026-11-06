# 百鸣科技独立卡密版源码包

当前源码版本 baiming-independent-v4，授权协议 v1。每个 App 单独输入并保存自己的 JUMO 卡密。保留原“巨魔注入”程序、百鸣科技界面及正常前台使用时 55–65 分钟续验。

本包是待编译源码，不是可直接注入的成品。本轮没有 macOS / iOS 原生编译、没有真机运行，不能把此次协议回退当作已修复此前启动闪退。

1. 不执行之前的配对版服务端提示词。客户端恢复原有 POST /ai/ai_key/card_vip/detail，仅传 key、machine_code、software_id=JUMO，验签版本 v1。若服务端仍是原有 v1 实现，无需为本版做改造；如果已经执行过强制 v2 的服务端改造，需先恢复 JUMO 的 v1 支持。
2. 将本包全部内容上传 GitHub，包含隐藏的 .github 目录。运行 Actions → Build JUMO iOS → Run workflow。
3. 成功后下载 JUMO-device-test，内含四个编译和签名后的库。使用原注入器撤销旧配对版整组插件后，再注入新成品包内的 JumoLicense.dylib、Cam.dylib、MM.dylib、Sky.dylib，四个库应来自同一次构建并位于相同加载目录。
4. 每个 App 输入一张独立的 JUMO 卡密，联网成功后在此 App 内记住，后续自动续验。不能把已经绑定另一个 App 设备码的同一卡密直接用于新 App。
5. 点击插件面板“授权”可重新验证卡密或查看此 App 的设备码。没有配对码、跨 App 自动共享或激活名额管理。

“之前的卡密”指本项目此前已接入的 JUMO 系统，不是原作者的旧授权系统。现有生产公钥不变，不回传对话中的任何旧卡。

源码包：output/jumo-integration/BAIMING-independent-source.zip。output/jumo-integration/BAIMING-integration-source.zip 和 JUMO-integration-source.zip 是同内容的兼容名称。不要将源码包中的原始三个输入库或 prepared 中间文件直接注入。

详细规则、迁移边界及验证步骤见 client/JumoLicense/README.zh-CN.md。

