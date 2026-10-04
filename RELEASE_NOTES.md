# Orange Pi Zero 3 iStoreOS ImageBuilder Lite · r0-25b2c28

首个经过完整验证的 Orange Pi Zero 3 Lite Standalone ImageBuilder 发布版。

## Release Asset

`istoreos-imagebuilder-orangepi-zero3-lite-r0-25b2c28.tar.zst`

SHA256:

```text
51164e2ed0004abbeda4cbc1fbbfa646dd21535e111a91c515bbab5b5645c453
```

压缩包约 176 MiB，解压后的精简 ImageBuilder 约 314 MiB。

默认固件 Manifest SHA256：

```text
dd94db30b8962143ff0239be76462e32d959780970a5998ecc4d0ee53d3b6005
```

## 使用

```bash
tar --zstd -xf istoreos-imagebuilder-orangepi-zero3-lite-r0-25b2c28.tar.zst
cd imagebuilder-zero3-lite
make image
```

输出目录：

```text
bin/targets/sunxi/cortexa53/
```

最终发布包已经完成“从 `.tar.zst` 全新解压后直接执行 `make image`”验证：

```text
IMAGE_EXIT=0
```

Lite 版只保留默认固件需要的本地 IPK。如果需要添加 Lite 包仓库中不存在的软件包，请使用完整版 ImageBuilder 或重新生成包含目标 IPK 的 ImageBuilder。
