# 第三方组件与分发条件

## 应用源码

基于 [MewX/light-novel-library_Wenku8_Android](https://github.com/MewX/light-novel-library_Wenku8_Android) 与原贡献者的工作。原始 [LICENSE](../LICENSE) 保留 GNU GPL version 2 或后续版本条款。本次 Flutter 组合版本按 [GPL version 3](../assets/licenses/GPL-3.0.txt) 分发，以兼容 LGPL v3 的协议适配代码。保留原署名、修改说明和构建脚本；发布 APK 时一并提供对应 Flutter 工程归档。

## 原版 API 运行库：libcpp.so

- 路径：`android/app/src/main/jniLibs/<abi>/libcpp.so`。
- 用途：现有文库联网接口的 JNI 运行库。
- 当前工作区的 arm64 运行库从用户提供的 `wenku8-0.5.6-arm64-v8a.apk` 原样解出，并已与 APK 内成员逐字节核对；SHA-256 为 `c3244b0564b5356fb2e78f9f9f8f5c768b5a18089ee16b53e387963f04bc7971`。未修改、不重新实现该二进制。
- 目前只配置 `arm64-v8a`；`armeabi-v7a` 和 `x86_64` 构建仍需分别提供对应库。
- 项目维护者于 2026-10-15 确认其可在**保持原样**的条件下再分发。正式 APK 继续使用原文件；与上游一致，公开仓库与源码归档不附带该实现。
- 该组件的源码不在本工程中；不能将应用源码的 GPL 许可视为对该组件源码、修改权或其他用途的授权。需要超出原样再分发条件时，应联系原版权方。
- 原项目当前公开构建使用 [api-stub](https://github.com/MewX/light-novel-library_Wenku8_Android/blob/master/studio-android/LightNovelLibrary/settings.gradle)，因此本工程源码归档不应被描述为该二进制的完整对应源码。

公开源码导出始终排除该运行库，无需额外参数。缺少这个运行库的构建不能使用现有文库联网接口；发布多 ABI 正式包时仍需维护者提供对应 ABI 的原文件，详见 [构建发布指南](RELEASING.md)。

## 阅读书源格式与搜索

应用可导入 [aoaostar/legado](https://github.com/aoaostar/legado) 提供的书源 JSON 配置，并保留配置中的规则字段。发现页搜索执行常见 GET/POST、网页选择器和基础 JSONPath；本工程不包含完整规则引擎，不执行 JavaScript/XPath，也不提供动态 Cookie 获取或验证码处理。

## 内置字体：Adobe 思源宋体 CN

使用 Adobe 官方发布的 CN 子集 Regular / Bold 原始字体，未提取或分发 OPPO 系统字体。

- [官方仓库](https://github.com/adobe-fonts/source-han-serif)
- [SIL Open Font License 1.1 原文与版权声明](../assets/fonts/OFL-SourceHanSerif.txt)
- [文件来源](../assets/fonts/README.md)

字体维持自己的 OFL 许可，不随应用改标为 GPL。

## 在线听书协议

`lib/listening/edge_protocol.dart` 为 [rany2/edge-tts](https://github.com/rany2/edge-tts) v2 校验算法的 Dart 适配，参考提交 `bd44c1d1aaebdc1db7f47456ee12431b42ec7cac`，修改日期 2026-10-15。遵循 LGPL v3；[完整许可](../assets/licenses/edge-tts.txt) 与 GPL v3 原文随源码和应用提供。代码可在本工程中替换、修改后重新构建，构建不依赖私有密钥。

在线音色由 Microsoft Edge 在线语音服务提供。代码许可不授予该服务的所有权或可用性保证；不包含付费凭证。朗读会将待合成文本发送给该服务，缓存仅保留在设备本地。

## Flutter 与依赖包

### MOBI 导入：libmobi

使用 [libmobi 0.12](https://github.com/bfabiszewski/libmobi/tree/v0.12)，Copyright 2014–2022 Bartek Fabiszewski，LGPL-3.0-or-later。完整、未修改的上游源码与许可在 `third_party/libmobi/`；Android 以独立 `libmobi.so` 动态链接，应用导出与 JNI 适配位于 `android/app/src/main/cpp/`，CMake 构建不启用加密支持。修改或替换库后可使用同一工程重新构建。源码导出包含库源码和构建脚本，应用开源许可页包含 LGPL v3 与 GPL v3 原文。

MOBI 在本机重建为 EPUB 后使用现有阅读器，不访问转换服务，不解密 DRM 文件。

### 文档导入

Android 文档转换使用 [jsoup 1.23.2](https://jsoup.org/)（MIT，Jonathan Hedley）、[commonmark-java 0.30.1](https://github.com/commonmark/commonmark-java)（BSD-2-Clause，Atlassian）和 [PDFBox Android 2.0.27.0](https://github.com/TomRoush/PdfBox-Android)（Apache-2.0，Tom Roush / Apache Software Foundation）。PDFBox 的 Bouncy Castle 1.72 依赖遵循 MIT-style 许可。Android 旧版本兼容使用 Google 的 `desugar_jdk_libs_nio` 2.1.5（GPL-2.0 with Classpath Exception）。固定版本列于 `android/app/build.gradle.kts`，原文与 PDFBox / FontBox 声明保存在 `assets/licenses/` 并注册到应用许可页。FB2 / DOCX 的 SAX 转换与 RTF 正文导入为本工程实现。

OpenJDK 兼容库的完整未修改源码、许可与构建脚本保存在 `third_party/desugar_jdk_libs-2.1.5/`，对应上游发布准备提交 `73170c345e6a762fc6a1f0301bb15218850023ef`；来源见 `third_party/DESUGAR_JDK_LIBS.md`，随应用对应源码一起提供。

依赖版本锁定于 `pubspec.lock`。Flutter、Cupertino Icons、音频与存储插件保留各自许可；Flutter 构建生成的许可集合可在 **设置 → 关于轻小说文库 → 开源许可与字体授权** 查看。该页面也包括上面的内置字体与协议适配声明。

阅读书源搜索使用 `charset` 2.0.1（Apache-2.0）处理 GBK 响应；原许可随依赖包提供。

液态玻璃基于 [liquid_glass_easy 5.0.0](https://pub.dev/packages/liquid_glass_easy/versions/5.0.0)，作者 Ahmed Gamil，使用 MIT License。源码和原许可保留于 [`third_party/liquid_glass_easy`](../third_party/liquid_glass_easy)；本地 GPU 性能修改单独记录在 [`PATCHES.md`](../third_party/liquid_glass_easy/PATCHES.md)。应用保留原作者署名，版权与许可随源码及 Flutter 的开源许可集合分发。

## 内容与展示图

中文显示使用 [OpenCC ver.1.1.9](https://github.com/BYVoid/OpenCC/tree/ver.1.1.9) 的原始字词典（BYVoid 及贡献者，Apache-2.0）。词典及来源说明位于 `assets/opencc/`，完整许可位于 `assets/licenses/opencc.txt`，注册到应用开源许可页。区域字形转换与有界缓存由 Dart 实现，不包含 OpenCC 原生二进制。

TXT / EPUB 目录解析、图片尺寸样式与同步归档使用 `archive`（MIT）、`html`（MIT）及 `csslib`（BSD-3-Clause），版本保留于锁文件，许可包含在 Flutter 生成的开源许可集合中。应用使用本项目选定的奶白人物剪影图标，原始位图与适配信息保留于 `assets/branding/`，不包含莱茵生命标志或宣传片素材。

小说、封面、插图归各自权利人所有，不包含在源码许可中。README 展示图使用独立演示数据、程序绘制封面，不包含个人账号、阅读记录或真实设备通知。
