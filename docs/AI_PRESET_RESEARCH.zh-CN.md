# AI 预设调研

调研日期：2026-11-16。本轮仅核对源码和官方资料，没有做设备实验，也没有继续修改应用实现。

## 结论

此前新增的七个 AI 开关来自能力键清单，而不是七套经过独立验证的解锁流程。键名、引入系统版本及其他应用包含相同开关，只能证明映射和实现存在，不能证明单独写入后可以下载模型或使用功能。

也不应把七项全部合并写入 Siri AI：照片清理、翻译、手写相关能力有各自的用途和依赖，并不等于 Siri AI 的组成开关。

| 当前新增项 | 证据与局限 | 默认预设建议 |
| --- | --- | --- |
| Apple 智能支持 | Erosion、Nugget 有生成式模型能力设置；Erosion 明确区分传统 Apple Intelligence 与新 Siri AI | 作为适用设备的配置步骤，不与 Siri AI 并排重复呈现底层开关 |
| Siri AI 模式 | GestaltX 将 SiriMode 设为 2，并标注实验性质与下载不保证；不是设备运行验证 | 纳入单一 Siri AI 配置流程，按系统与设备分支处理 |
| 音频智能 | MGKeys/GestaltX 提供能力映射；本次没有找到独立开启成功的可复现设备证据 | 不进入默认功能列表 |
| 个人翻译 | 真实的翻译功能有模型、设备、语言及具体使用场景要求；MG 键不能直接等同于完整实时翻译解锁 | 不作为已验证解锁预设；以后有独立验证再考虑单列 |
| 照片清理 | Apple 将其列为 Photos 中由 Apple Intelligence 驱动的独立功能；能力键存在不证明旧设备单独可用 | 不塞入 Siri AI，也不凭一个键承诺开启；独立验证后才适合预设 |
| 手写合成 | MGKeys 有映射；官方手写功能位于 Notes/Journal 等使用场景，不能从映射直接推导其具体解锁路径 | 不归入 Siri AI 默认项 |
| 始终聆听 Siri | 能力映射存在，但不是启用生成式 Siri 的充分条件；不能与普通“嘿 Siri”支持混为一谈 | 不进入 AI 默认列表 |

这些键仍可通过通用字段编辑器研究。这里的“未找到验证”指本次检查的材料，不代表功能在所有设备上都无效。

## 开源实现不能相互循环举证

- [Erosion 的 UI](https://github.com/jailbreakdotparty/Erosion/blob/main/Erosion/Tweaks/MobileGestalt/GestaltView.swift)主要提供 Apple Intelligence、机型伪装和地区相关操作，并没有把上述七项都当作独立解锁功能。
- [Erosion 的说明和键值](https://github.com/jailbreakdotparty/Erosion/blob/main/Erosion/Tweaks/MobileGestalt/GestaltStore.swift)明确提示传统 AI 伪装流程不等于开启新 Siri AI。其 UI 用“系统地区不是美国”来显示地区选项，也不能作为“该地区不支持”的正确判定标准。
- [Nugget 的配置清单](https://github.com/leminlimez/Nugget/blob/main/src/tweaks/tweak_loader.py)将 MG 能力、设备身份、Feature Flags 和 Eligibility 配置区分；[eligibility 实现](https://github.com/leminlimez/Nugget/blob/main/src/tweaks/eligibility_tweak.py)还涉及 MG 以外的文件。因此不能把所有 Nugget 功能都直接复制成 MG 开关。
- [GestaltX](https://github.com/huamidev/GestaltX/blob/main/GestaltX/Capabilities.swift)包含较多能力标记，同时明确提示下载和可用性不保证。这是能力清单证据，不是实机成功证据。
- [WorkPlot 的 Intelligence 分类](https://github.com/gievano/WorkPlot/blob/main/WorkPlot/Models/Tweaks/IntelligenceTweaks.swift)实际为空，将 AI 交给专门配置流程。[其 Store](https://github.com/gievano/WorkPlot/blob/main/WorkPlot/Models/GestaltStore.swift)注明地区流程移植自 GestaltEdit，不能反过来当作 GestaltEdit 正确性的独立依据。另外，其 applySiriAI 将生成式模型键设为 2，与 GestaltX 使用 SiriMode=2 的路径不同；不能把不同键上的同一个数字当成同一种配置。

## 地区处理

「启用 Siri AI」不需要在标题标注美国地区。支持地区应保留原值，地区调整只能是必要的条件步骤，不能以“非美国”为触发条件。

不过，自动处理必须区分：MG 设备销售地区、系统地区、Apple Account 地区、语言、平台与服务端资格。它们不是同一个值。不能从 Locale.current 或一个 CH/A 字符串就宣称判断了全部 Siri AI 可用性。

Apple 的 [Siri AI 说明](https://support.apple.com/en-us/127893)将语言、合资格 Apple Account 地区和平台列为条件，区分欧盟 iOS/iPadOS/watchOS 与 macOS/visionOS，并说明中国大陆账户限制。另一方面，[Apple Intelligence 说明](https://support.apple.com/en-mo/121115)描述的部分应用 AI 功能在欧盟可用；所以 Siri AI 与其他 AI 功能也不能共用一张粗略地区开关表。

合理实现应保留支持地区，对能够确认的设备地区限制作针对性处理；无法观测的账户或服务端资格不应伪装成已自动解决。本文没有得出“仅改 MG 就能解决账户地区”的结论。

## 官方功能资料与键映射

- [MGKeys 映射](https://github.com/PoomSmart/MGKeys/blob/master/mapping.h)及[版本记录](https://github.com/PoomSmart/MGKeys/blob/master/keys_versions.py)：用于核对键名和引入版本，不验证覆盖写入的效果。
- [照片清理要求](https://support.apple.com/en-ph/121429)：Photos 的 Apple Intelligence 功能及设备条件。
- [AirPods 实时翻译](https://support.apple.com/guide/airpods/translate-in-person-conversations-dev9c215ca94/web)：耳机、iPhone、系统和 Apple Intelligence 条件；不能证明 PersonalTranslator 单键覆盖足够。
- [iPad 手写功能](https://support.apple.com/en-ie/guide/ipad/ipada87a6078/27/ipados/27)：手写使用场景及语言要求；不能据此断定某个私有 MG 键对应完整实现。

## 后续实现调整

根据用户后续提供的实机流程，旧设备（含 iOS 27）改为临时伪装机型下载模型，完成后使用特殊备份撤销身份伪装。普通备份仍按原时间格式命名，用于完整恢复；特殊备份只恢复 ProductType、HardwareModel、CPUModel 三个原值（原先缺失则移除），保留 SiriMode=2、生成式模型能力、地区与后续其他修改。本轮仅完成本地测试和构建，没有独立复验设备下载与面容 ID／听写恢复结果。
