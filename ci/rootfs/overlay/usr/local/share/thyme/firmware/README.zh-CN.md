# thyme 固件说明

内核与设备树会从 `/lib/firmware` 加载下列文件。rootfs 镜像只带
`linux-firmware` 里的通用固件，**原厂 blobs 需要你从手机 stock 固件提取**。

## 设备树引用的原厂固件

`sm8250-xiaomi-thyme.dts` 使用 `umi`（小米 10 系列）路径：

```text
/lib/firmware/qcom/sm8250/umi/adsp.mbn
/lib/firmware/qcom/sm8250/umi/cdsp.mbn
/lib/firmware/qcom/sm8250/umi/venus.mbn
/lib/firmware/qcom/sm8250/umi/a650_zap.mbn
/lib/firmware/qcom/sm8250/umi/slpi.mbn
```

提取方式（在能读取 stock 分区的环境，例如 root 后的 Android / TWRP）：

```sh
adb root
adb pull /vendor/firmware/adsp.mbn
adb pull /vendor/firmware/cdsp.mbn
adb pull /vendor/firmware/venus.mbn
adb pull /vendor/firmware/a650_zap.mbn
adb pull /vendor/firmware/slpi.mbn
sudo install -Dm644 adsp.mbn      /lib/firmware/qcom/sm8250/umi/adsp.mbn
sudo install -Dm644 cdsp.mbn      /lib/firmware/qcom/sm8250/umi/cdsp.mbn
sudo install -Dm644 venus.mbn     /lib/firmware/qcom/sm8250/umi/venus.mbn
sudo install -Dm644 a650_zap.mbn  /lib/firmware/qcom/sm8250/umi/a650_zap.mbn
sudo install -Dm644 slpi.mbn      /lib/firmware/qcom/sm8250/umi/slpi.mbn
```

不同 ROM/分区布局下文件位置可能不同，也可能在 `vendor.img` 或 `dsp` 分区里，
请按自己的设备确认。缺少这些文件不会阻止系统启动，但 GPU（zap）、
ADSP 音频、Venus 视频编解码和传感器低功耗岛会不可用。

## linux-firmware 已覆盖的部分

Ubuntu 26.04 的 `linux-firmware` 以 `.zst` 压缩形式安装（例如
`ath11k/QCA6390/hw2.0/amss.bin.zst`）；内核配置已启用
`CONFIG_FW_LOADER_COMPRESS_ZSTD`，可以直接加载，不需要手动解压。

```text
ath11k/QCA6390/hw2.0/{amss.bin,m3.bin,board-2.bin}.zst  # Wi-Fi / 蓝牙
qcom/a650_sqe.fw.zst                                     # Adreno 650
qcom/a650_gmu.bin.zst                                    # Adreno 650 GMU
qcom/sm8250/a650_zap.mbn.zst                             # 通用 zap（本机用 umi 版本）
qcom/venus-5.2/...                                       # 若使用上游 venus 路径
```

`/lib/firmware` 在 usrmerge 系统上是 `/usr/lib/firmware` 的符号链接，两条路径
等价。原厂 blobs 请安装为未压缩的 `.mbn`/`.bNN` 文件。

QCA6390 的板级校准数据（BDF）若与通用 `board-2.bin` 不匹配，Wi-Fi 仍可能
无法启动；此时需要从原厂 `vendor`/`persist` 分区补齐对应板级的 BDF。

## 检查

```sh
sudo thyme-check-firmware
```

请遵守设备固件的授权与许可，仅在你自己的设备上使用提取出的 blobs。
