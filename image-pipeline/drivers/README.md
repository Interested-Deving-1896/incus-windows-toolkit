# Drivers

Place additional Windows drivers here for injection into the image.

VirtIO drivers are downloaded automatically during build.
WOA (Windows on ARM) drivers can be supplied via `--woa-drivers PATH`.

Subdirectory structure:
```
drivers/
  custom/
    my-driver/
      my-driver.inf
      my-driver.sys
```

Custom drivers in this directory are copied into the image's `$WinPEDriver$`
folder so Windows Setup picks them up automatically.
