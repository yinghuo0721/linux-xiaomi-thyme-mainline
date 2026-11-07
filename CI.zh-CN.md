# thyme 内核的 CI 构建与 Linux 系统适配

本文对应 `.github/workflows/build-thyme.yml`。工作流在 GitHub Actions 上完成两件事：

1. 交叉编译小米 10S（thyme）内核，产出 `Image.gz`、设备树和可直接 `fastboot` 的 Android boot 镜像；
2. 在 arm64 runner 上编译带连续自动对焦/颜色修正的 libcamera v0.7.0 用户态。

首次构建已通过（run
[42371543172](https://github.com/yinghuo0721/linux-xiaomi-thyme-mainline/actions/runs/42371543172)）：

| Job | 结果 | 耗时 |
|---|---|---|
| Kernel / DTBs / boot images | success | 约 29 分钟 |
| libcamera v0.7.0 (arm64) | success | 约 1 分钟 |

## 触发方式

- 推送到 `master` 且修改了工作流文件时自动运行；
- 手动运行（可关闭用户态构建）：

```sh
gh workflow run build-thyme.yml --repo <owner>/<repo> --ref master \
  -f build_userspace=true
gh run watch --repo <owner>/<repo>
```

## 产物

内核产物名形如 `thyme-kernel-7.2.0-rc5`，保留 30 天：

| 文件 | 说明 |
|---|---|
| `thyme-camera-menu.img` | 正常启动镜像，cmdline 含 `root=/dev/sda38` |
| `thyme-camera-logdump.img` | 日志诊断镜像，无 `root=` |
| `thyme-camera-display-test.img` | 显示/initcall 诊断镜像 |
| `raw/Image`、`raw/Image.gz` | 未打包的内核 |
| `raw/kernel.config` | 实际参与编译的配置 |
| `dts/sm8250-xiaomi-thyme.dtb` | 主设备树 |
| `dts/sm8250-xiaomi-thyme-logdump.dtb` | logdump 设备树 |
| `SHA256SUMS-all.txt` | 全部产物的 SHA256 |

构建出的内核版本字符串为 `7.2.0-rc5-sm8250-modem+`（`+` 表示构建时源码树带未提交改动，
与原作者本地构建一致，不影响功能）。配置中只有 `CONFIG_CRYPTO_BENCHMARK=m` 一个模块，
相机、显示、GPU、音频、WiFi 等驱动全部为内置，因此 boot 镜像之外不需要额外安装
`/lib/modules`。

libcamera 产物 `thyme-libcamera-v070-arm64.tar.gz` 解包后是
`opt/thyme-camera-focus-color/`（`libcamera.so.0.7.0`、simple pipeline 的
`ipa_soft_simple.so`、`s5khmx.yaml` 等），安装方式见下文。

## 本地复现

在 Linux x86_64 主机上：

```sh
sudo apt-get install build-essential gcc-aarch64-linux-gnu bc bison flex \
  libssl-dev libelf-dev device-tree-compiler python3

cp thyme-camera/config/kernel-build.config /tmp/kernel-build/.config
make O=/tmp/kernel-build ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- olddefconfig
make O=/tmp/kernel-build ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j"$(nproc)" \
  Image.gz qcom/sm8250-xiaomi-thyme.dtb qcom/sm8250-xiaomi-thyme-logdump.dtb

# pack-images.py 已修复为真正使用 --build-dir
python3 thyme-camera/tools/pack-images.py \
  --build-dir /tmp/kernel-build --output-dir ./out
```

## 刷入设备

> 前提：已解锁 bootloader，且手机上已存在 Linux 根文件系统（模板 cmdline 指向
> `/dev/sda38`，无 initramfs）。操作前先备份现有 boot/dtbo 分区。

```sh
# 只启动、不写入，先验证
fastboot boot thyme-camera-menu.img

# 验证通过后写入当前 slot
fastboot flash boot thyme-camera-menu.img
fastboot reboot
```

`logdump`/`display-test` 只用于排障，不建议作为日常启动镜像。

## 根文件系统（把 Linux 系统真正装起来）

内核与 boot 镜像只解决“启动”；用户态需要自己准备 arm64 rootfs。以下以 Ubuntu
arm64 + GNOME 为目标（与上游作者的环境一致）。注意 `mkfs` 会清空目标分区，
务必先确认分区号并备份数据。

在 arm64 环境（例如手机已能启动的现有 Linux，或 arm64 虚拟机）中执行：

```sh
# 1. 基础系统（示例：Ubuntu noble，也可换 Debian trixie）
sudo mkfs.ext4 /dev/sda38
sudo mount /dev/sda38 /mnt
sudo mmdebstrap --architectures=arm64 --components=main,universe \
  --include=linux-firmware,systemd,pipewire,wireplumber,ubuntu-desktop-minimal \
  noble /mnt

# 2. 相机栈运行库（libevent 在 noble 中的包名为 libevent-2.1-7t64）
sudo chroot /mnt apt install -y \
  libudev1 libyaml-0-2 libssl3t64 libevent-2.1-7t64 libdrm2

# 3. fstab / hostname / 时区等基础配置
echo "/dev/sda38 / ext4 defaults 0 1" | sudo tee -a /mnt/etc/fstab

# 4. 安装 libcamera（CI 产物）
sudo tar -C / -xzf thyme-libcamera-v070-arm64.tar.gz
echo "/opt/thyme-camera-focus-color/lib" | sudo tee /etc/ld.so.conf.d/thyme-libcamera.conf
sudo ldconfig

# 5. 按 thyme-camera/records 安装 PipeWire/WirePlumber 与相机命名配置
#    ~/.config/systemd/user/pipewire.service.d/96-thyme-focus-color.conf
#    ~/.config/systemd/user/wireplumber.service.d/96-thyme-focus-color.conf
#    ~/.config/libcamera/configuration.yaml
#    ~/.config/wireplumber/wireplumber.conf.d/91-thyme-camera-names.conf
systemctl --user daemon-reload
```

如果构建机是 x86_64，用 `mmdebstrap --architectures=arm64` 时需要安装
`qemu-user-static` 并配置 binfmt；更省事的方式是在手机本身已经能启动的 Linux 里
chroot 操作。

固件（`/lib/firmware`）是另一个必须项，主要来自 `linux-firmware` 与厂商分区：

- `ath11k/QCA6390/hw2.0/`（WiFi/蓝牙，含板级 BDF）
- `qcom/a650_sqe.fw`、`qcom/a650_gmu.bin`（Adreno 650）
- `qcom/venus-5.2/`（视频编解码）
- `qcom/camss/`（相机）
- `qcom/sm8250/` 下的 modem/adsp/cdsp 等固件（Android 分区中的 blob，需自行提取）

## 已知限制

上游 README 已明确：本树当前手机运行的是 #18 + 热加载驱动，#19 镜像尚未做完整启动
验证；前摄反复启停仍有 CCI 超时、OV13B10 selection ioctl 警告；GC02M1 微距、OIS、
EEPROM 校准和 108MP 完整模式尚未实现。CI 只是把同一份源码/配置可重复地编译出来，
不会改变这些功能状态。
