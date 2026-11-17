# 文库 API 运行库

当前工作区的 `arm64-v8a/libcpp.so` 从用户提供的 `wenku8-0.5.6-arm64-v8a.apk` 原样解出，用于既有 `TokenManager.getMagicVersionCpp` JNI 入口。与 APK 内文件逐字节比对一致，SHA-256：`c3244b0564b5356fb2e78f9f9f8f5c768b5a18089ee16b53e387963f04bc7971`。未修改二进制内容。

这份库只覆盖 `arm64-v8a`；`armeabi-v7a`、`x86_64` 等 ABI 仍需各自的库文件。构建配置对该文件关闭符号裁剪，发布构建应核对 APK 内的原始字节。`TokenManager.getMagicVersionCpp` JNI 声明和调用代码位于本工程；二进制本身仍按 `docs/THIRD_PARTY.md` 记录的条件原样使用。
