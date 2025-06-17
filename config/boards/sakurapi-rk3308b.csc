# Rockchip RK3308 quad core 256-512MB SoC WiFi
BOOT_SOC="rk3308"
BOARD_NAME="Sakura Pi RK3308B"
BOARD_MAINTAINER="TheSnowfield"
BOARDFAMILY="rockchip64"
BOOTCONFIG="sakurapi_rk3308b_defconfig"
DEFAULT_CONSOLE="serial"
MODULES_LEGACY="g_serial"
SERIALCON="ttyS0"
KERNEL_TARGET="current"
BOOT_FDT_FILE="rockchip/rk3308-sakurapi-rk3308b.dtb"
MODULES_BLACKLIST="analogix_dp dw_mipi_dsi dw_hdmi gpu_sched lima hantro_vpu panfrost"
HAS_VIDEO_OUTPUT="no"
BOOTBRANCH_BOARD="tag:v2025.04"
BOOTPATCHDIR="v2025.04"
IMAGE_PARTITION_TABLE="gpt"

BOOT_SCENARIO="binman"
BL31_BLOB="rk33/rk3308_bl31_v2.26.elf"
DDR_BLOB="rk33/rk3308_ddr_589MHz_uart2_m1_v1.30.bin"
MINILOADER_BLOB="rk33/rk3308_miniloader_sd_nand_v1.13.bin"

function build_board_drivers__sakurapi_vleds() {
  echo driver_sakurapi_vleds
}

function driver_sakurapi_vleds() {
  if linux-version compare "${version}" ge 6.1; then

    display_alert "Adding" "WS2812-VLEDS driver for $BOARD_NAME" "info"
    fetch_from_repo "$GITHUB_SOURCE/Sakura-Pi/ws2812-vleds" "ws2812-vleds" "commit:3b95cfc9cb3aeccc4143c96d8d79c1004cf95721"

    cd "$kerneldir" || exit
    cp -R "${SRC}/cache/sources/ws2812-vleds" "$kerneldir/drivers/leds/rgb" \
      && rm -rf "$kerneldir/drivers/leds/rgb/ws2812-vleds/.git"

    echo 'source "drivers/leds/rgb/ws2812-vleds/Kconfig"' \
         >> "$kerneldir/drivers/leds/rgb/Kconfig"

    echo 'include drivers/leds/rgb/ws2812-vleds/Makefile' \
         >> "$kerneldir/drivers/leds/rgb/Makefile"

  fi
  
}
