# thyme 内核的 CI 构建与 Linux 系统适配

本仓库在 GitHub Actions 上提供两条流水线：

| 工作流 | 产物 |
|---|---|
| `build-thyme.yml` | 内核 `Image.gz`、DTB、三张 Android boot 镜像、arm64 libcamera v0.7.0 |
| `build-rootfs.yml` | 可直接写入根分区的 Ubuntu arm64 rootfs（可选 GNOME） |

首次构建记录：

| 运行 | 结果 | 耗时 |
|---|---|---|
| [内核 run 42371543172](https://github.com/yinghuo0721/linux-xiaomi-thyme-mainline/actions/runs/42371543172) | success | 约 30 分钟 |
| [rootfs minimal run 42385798649](https://github.com/yinghuo0721/linux-xiaomi-thyme-mainline/actions/runs/42385798649) | success | 约 3 分钟 |
| [rootfs desktop run 42386635701](https://github.com/yinghuo0721/linux-xiaomi-thyme-mainline/actions/runs/42386635701) | success | 约 3 分钟 |

## 内核流水线

推送到 `master` 且修改工作流文件时自动运行；也可以手动：

```sh
gh workflow run build-thyme.yml --repo <owner>/<repo> --ref master \
  -f build_userspace=true
```

产物 `thyme-kernel-7.2.0-rc5`（保留 30 天）：

| 文件 | 说明 |
|---|---|
| `thyme-camera-menu.img` | 正常启动镜像，cmdline 含 `root=/dev/sda38` |
| `thyme-camera-logdump.img` | 日志诊断镜像，无 `root=` |
| `thyme-camera-display-test.img` | 显示/initcall 诊断镜像 |
| `thyme-userdata.img` | 单系统镜像：cmdline `root=PARTLABEL=userdata rw rootwait` |
| `raw/Image`、`raw/Image.gz` | 未打包内核 |
| `raw/kernel.config` | 实际参与编译的配置 |
| `dts/*.dtb` | 主设备树与 logdump 设备树 |
| `SHA256SUMS-all.txt` | 全部产物的 SHA256 |

内核版本字符串为 `7.2.0-rc5-sm8250-modem+`。配置中只有
`CONFIG_CRYPTO_BENCHMARK=m` 一个模块，相机、显示、GPU、音频、WiFi 驱动全部内置，
boot 镜像之外不需要 `/lib/modules`。

### 本地复现

```sh
sudo apt-get install build-essential gcc-aarch64-linux-gnu bc bison flex \
  libssl-dev libelf-dev device-tree-compiler python3

mkdir -p /tmp/kernel-build
cp thyme-camera/config/kernel-build.config /tmp/kernel-build/.config
make O=/tmp/kernel-build ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- olddefconfig
make O=/tmp/kernel-build ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j"$(nproc)" \
  Image.gz qcom/sm8250-xiaomi-thyme.dtb qcom/sm8250-xiaomi-thyme-logdump.dtb

python3 thyme-camera/tools/pack-images.py \
  --build-dir /tmp/kernel-build --output-dir ./out
```

## 刷入设备

> 前提：已解锁 bootloader，且根分区已写入 Linux rootfs。模板 cmdline 指向
> `/dev/sda38`；如果你的分区号不同，需要同步修改 boot 镜像 cmdline 和
> rootfs 的 `/etc/fstab`。操作前先备份 boot/dtbo。

```sh
fastboot boot thyme-camera-menu.img      # 先只启动验证
fastboot flash boot thyme-camera-menu.img
fastboot reboot
```

## rootfs 流水线

`build-rootfs.yml` 只允许手动触发（rootfs 里会写入构建时指定的密码，不适合
每次 push 自动出包）：

```sh
gh workflow run build-rootfs.yml --repo <owner>/<repo> --ref master \
  -f suite=resolute \
  -f desktop=false \
  -f hostname=thyme \
  -f user_password='改成你的密码' \
  -f root_part=/dev/sda38
```

主要输入：

| 输入 | 说明 |
|---|---|
| `suite` | `resolute`（Ubuntu 26.04 LTS，默认）或 `noble`（24.04 LTS） |
| `desktop` | 是否安装 `ubuntu-desktop-minimal`（GNOME 50） |
| `user_password` | `thyme` 用户密码，默认 `thyme`，请改 |
| `ssh_public_key` | 可选，写入 `authorized_keys` |
| `wifi_ssid` / `wifi_psk` | 可选，生成 NetworkManager 连接 |
| `root_part` | 根分区：`/dev/sda38`，或单系统刷 userdata 时用 `PARTLABEL=userdata` |
| `image_format` | `tar`（默认）、`ext4`（fastboot 刷 userdata）或 `both` |
| `firmware_url` / `firmware_sha256` | 可选，注入原厂固件（见下） |

选择 `resolute` 是因为当前 Ubuntu 26.04 的 libcamera 正好是 0.7.0，与 CI 编译的
patched libcamera 的 `libcamera.so.0.7` ABI 一致；chroot 脚本检测到 ABI 匹配时会
自动启用 PipeWire/WirePlumber 的 `LD_LIBRARY_PATH` drop-in。

产物 `thyme-rootfs-<suite>[-desktop]`（minimal 约 940 MB，desktop 约 1.2 GB
tar.zst，保留 30 天）：

```sh
sudo mkfs.ext4 /dev/sda38
sudo mount /dev/sda38 /mnt
sudo tar --zstd --numeric-owner -xpf thyme-rootfs-resolute-desktop-<date>.tar.zst -C /mnt
sudo umount /mnt
```

### 手机上还没有 Linux：单系统刷入 `userdata`

用 `image_format=ext4` 构建，拿到 `thyme-rootfs-<suite>[-desktop]-<date>.img.zst`，
配合内核产物里的 `thyme-userdata.img`（cmdline 为
`root=PARTLABEL=userdata rw rootwait`）：

```bat
:: 1. 解开 ext4 镜像（Windows 可用 7-Zip，或 Linux 上 zstd -d）
7z e thyme-rootfs-resolute-desktop-<date>.img.zst

:: 2. 两个 boot slot 都刷同一份内核镜像
fastboot flash boot_a thyme-userdata.img
fastboot flash boot_b thyme-userdata.img

:: 3. 擦除并刷入 userdata（会清空 Android 数据！）
fastboot erase userdata
fastboot flash userdata thyme-rootfs-resolute-desktop-<date>.img

fastboot reboot
```

首次启动会把 ext4 自动扩到 `userdata` 分区大小（fstab 的
`x-systemd.growfs`），需要几分钟。rootfs 与 boot 镜像必须来自同一次内核构建；
ABL 保持原厂，不要刷第三方 ABL。回滚用原厂 `images/boot.img` 刷回
`boot_a`/`boot_b`。

镜像内已包含：systemd、NetworkManager/wpa_supplicant、OpenSSH、BlueZ、
PipeWire/WirePlumber、Mesa/freedreno、`alsa-ucm-conf`、`v4l-utils`/`i2c-tools`、
patched libcamera（`/opt/thyme-camera-focus-color`）、相机/GL 用户配置、串口
`ttyMSM0` getty 和首次启动生成 SSH host key 的 unit。

`desktop=true` 时额外安装 `ubuntu-desktop-minimal`（GNOME 50）和
`gnome-tweaks`，并做了三项手机化设置：

- GDM 自动登录 `thyme` 用户（`/etc/gdm3/custom.conf`），避免无键盘时卡在登录界面；
- 创建 `~/.config/gnome-initial-setup-done` 并 mask 首次登录向导；
- 安装 `90-thyme-native-gl.conf` 到
  `~/.config/systemd/user/org.gnome.Shell@ubuntu.service.d/`，让 GNOME Shell 使用
  freedreno 原生驱动，避开 Zink/Turnip 崩溃。

GNOME 首次进入后建议在“设置 → 显示”里调整缩放，触屏键盘与旋转需要按实际
桌面环境再调。

本地构建（arm64 Linux，或带 qemu binfmt 的 x86 主机）：

```sh
LIBCAMERA_STAGE=/path/to/libcamera-stage bash ci/build-rootfs.sh
```

## 固件

`linux-firmware` 已覆盖 `ath11k/QCA6390`（Wi-Fi/蓝牙）、`qcom/a650_sqe.fw`
等通用固件，但设备树引用的原厂 blobs 不在发行版里：

```text
/lib/firmware/qcom/sm8250/umi/adsp.mbn
/lib/firmware/qcom/sm8250/umi/cdsp.mbn
/lib/firmware/qcom/sm8250/umi/venus.mbn
/lib/firmware/qcom/sm8250/umi/slpi.mbn
/lib/firmware/qcom/sm8250/umi/a650_zap.mbn
```

原厂镜像里这些文件是 Qualcomm 拆分格式（`foo.mdt` + `foo.b00`、`foo.b01`…）。
内核的 `qcom_mdt_loader` 会把 firmware name 最后三位替换成 `bNN` 去找分段，
所以把 `.mdt` 重命名为 `.mbn`、旁边保留 `.bNN` 即可被 DT 路径直接加载，不需要
改设备树。

仓库提供了提取工具，直接在 stock 刷机包目录上运行：

```sh
python3 ci/rootfs/extract-stock-firmware.py \
  --rom-dir "/path/to/OuySky_Mi10s_..." \
  --out stock-firmware
```

它会解析 `super.img` 的 LP 元数据取出 vendor 分区（ext4），再用 7-Zip 从
`modem.img`（FAT，adsp/cdsp/slpi/venus）和 vendor（a650_zap、a650_sqe.fw）
提取并校验每个 PT_LOAD 分段，输出 `/lib/firmware` 覆盖层（约 71 个文件）。
需要本机有 7-Zip（`7z`/`7za`/`7zz`）。

两种使用方式：

1. 在 CI 构建时注入：把 `stock-firmware/out` 打包成 tar.zst 放到一个不公开的
   直链，触发 `build-rootfs.yml` 时填 `firmware_url` 和 `firmware_sha256`；
2. 已经构建好的 rootfs 包：在 Linux 上执行

   ```sh
   ./ci/rootfs/inject-firmware.sh \
     thyme-rootfs-resolute-<date>.tar.zst stock-firmware/out
   ```

   或解压到分区后 `sudo cp -a stock-firmware/out/lib/firmware/. /mnt/lib/firmware/`。

装入后检查：

```sh
sudo thyme-check-firmware
```

缺少原厂固件不会阻止启动，但 GPU（zap shader）、ADSP 音频、Venus 视频编解码和
SLPI 传感器低功耗岛会不可用。只在你自己的设备上使用提取出的 blobs。

## 已知限制

上游 README 已明确：本树当前手机运行的是 #18 + 热加载驱动，#19 镜像尚未做完整
启动验证；前摄反复启停仍有 CCI 超时、OV13B10 selection ioctl 警告；GC02M1 微距、
OIS、EEPROM 校准和 108MP 完整模式尚未实现。CI 只是把同一份源码/配置可重复地
编译、打包出来，不改变这些功能状态。

rootfs 产物尚未在真机上启动验证；默认密码写在镜像里，首次登录后请立即修改，
并建议关闭密码登录、改用 SSH key。
