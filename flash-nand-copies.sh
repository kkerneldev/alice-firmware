#!/bin/sh
# This script is a workaround for bug with swupdate 2019.11:
# Flash handler erases whole partition, that makes it
# impossible to write backup copies of bootloader on other
# offsets of the same partition.
# Furthermore, flashing only 1 copy of uboot erases all
# backups, so first OTA upgrade makes device very vulnerable.

set -e
# set -x

SCRIPT_NAME=$(basename $0)

log() {
  echo "$SCRIPT_NAME: $@"
}

exit_error() {
  log "Error: $@" > /dev/stderr
  exit 1
}

set_vars() {
  [ $# -ge 4 ] || exit_error "Wrong number of arguments: $@"

  FILENAME=$2
  FILENAME_READ=$FILENAME.read
  FILENAME_SHA1SUM=$FILENAME.sha1
  DEVICE=$3
  [ -c "$DEVICE" ] || exit_error "$DEVICE doesn't exist"
  BLOCK_SIZE=$(mtdinfo $DEVICE | grep "Eraseblock size" | awk '{print $3}' )
  BLOCKS_AMOUNT=$(mtdinfo $DEVICE | grep "Amount of eraseblocks" | awk '{print $4}' )
  [ $((0x100000)) -gt "$BLOCK_SIZE" -a "$BLOCK_SIZE" -gt $((0x1000)) ] \
    || exit_error "Could not determine block size"
  BADBLOCKS=$(mtdinfo -M $DEVICE | sed 's/ *\([0-9]\+:.\{16\}\)/\1\n/g' \
                | awk "/BAD/ { print \$2 }" | tr '\n' ' ')
  log "BADBLOCKS: $BADBLOCKS"
  shift 3
  OFFSETS=
  while [ $# -gt 0 ]; do
    OFFSET_C=$1
    OFFSET_C=${OFFSET_C/M/*1024K}
    OFFSET_C=${OFFSET_C/K/*1024}
    OFFSET_C=$(($OFFSET_C))
    OFFSETS="$OFFSETS $OFFSET_C"
    shift 1
  done
  OFFSETS=${OFFSETS# }
  OFFSETS_COUNT=$(echo "$OFFSETS" | wc -w)
}

pp_nand() {
  [ $# -lt 2 ] && return
  log "Bytes at $2:$1:"
  nanddump -s $1 -p -l 16 $2 2>/dev/null | head -2
}

do_preinst() {
  log "running $@"
  set_vars $@
  log "Preparing to flash $FILENAME to $DEVICE at offsets $OFFSETS"
  for offset in $OFFSETS; do
    pp_nand $offset $DEVICE
  done
}

find_next_offset() {
  local offset=$1
  # for the last copy - it must fit till the end of partition
  local next_offset=$(($BLOCK_SIZE * $BLOCKS_AMOUNT))
  for cur_offset in $OFFSETS; do
    if [ $cur_offset -gt $offset -a $cur_offset -lt $next_offset ]; then
      next_offset=$cur_offset
    fi
  done
  echo $next_offset
}

find_blocks_available() {
  local offset=$1
  local next_offset=$(find_next_offset $offset)
  local blocks_available=$((($next_offset - $offset + $BLOCK_SIZE - 1) / $BLOCK_SIZE))
  for badblock in $BADBLOCKS; do
    if [ $((0x$badblock)) -ge $offset -a $((0x$badblock)) -lt  $next_offset ]; then
      blocks_available=$(($blocks_available - 1))
    fi
  done
  echo $blocks_available
}

check_flash_required() {
  local offset=$1

  pp_nand $offset $DEVICE
  log "Dumping from $DEVICE:$offset (size $FILESIZE)"
  nanddump -s $offset -l $FILESIZE $DEVICE -f $FILENAME_READ
  log "Checking sha1sum of $DEVICE:$offset"
  sha1sum -c $FILENAME_SHA1SUM
}

flash_offset() {
  local offset=$1
  local next_offset=$(find_next_offset $offset)
  local blocks_toerase=$((($next_offset - $offset + $BLOCK_SIZE - 1) / $BLOCK_SIZE))
  # flash_erase counts badblocks as part of total size,
  # while nandwrite skips them, e.g.:
  # 00000000(BAD), 00020000, 00040000, 00060000
  # flash_erase 0 3 will erase 2 blocks 00020000 and 00040000
  # nandwrite 0 3 will write to blocks 00020000, 00040000, 00060000
  # so 00060000 become not erased, but written

  log "Erasing $blocks_toerase blocks from $DEVICE:$offset"
  flash_erase -q $DEVICE $offset $blocks_toerase
  log "Flashing $FILENAME to $DEVICE:$offset $FILESIZE bytes"
  nandwrite -a -p -m -s $offset $DEVICE $FILENAME
}

do_postinst() {
  log "running $@"
  set_vars $@
  [ -f "$FILENAME" ] || exit_error "$FILENAME doesn't exist"
  FILESIZE=$(wc -c $FILENAME | awk '{print $1}')
  log "Flashing $FILENAME($FILESIZE) to $DEVICE at offsets $OFFSETS"
  BLOCKS_COUNT=$((($FILESIZE + $BLOCK_SIZE - 1) / $BLOCK_SIZE))

  cleanup() {
    log "cleanup..."
    log "rm $FILENAME_READ"
    rm -f $FILENAME_READ
    log "rm $FILENAME_SHA1SUM"
    rm -f $FILENAME_SHA1SUM
  }

  trap cleanup EXIT

  sha1sum $FILENAME > $FILENAME_SHA1SUM
  local cksum=$(cat $FILENAME_SHA1SUM | awk '{print $1}')
  log "Source file sha1sum: $cksum"
  sed -i "s#"$FILENAME"#"$FILENAME_READ"#g" $FILENAME_SHA1SUM

  SUCCESS_COUNT=$OFFSETS_COUNT
  for offset in $OFFSETS; do
    if [ $(find_blocks_available $offset) -lt $BLOCKS_COUNT ]; then
      log "Error: Not enough space at $DEVICE:$offset due to badblocks"
      SUCCESS_COUNT=$((SUCCESS_COUNT - 1))
      continue
    fi
    if [ "$SUCCESS_COUNT" -lt 2 ]; then
      exit_error "All copies have failed except the last. Leaving it untouched."
    fi
    if check_flash_required $offset; then
      log "Skip flashing at $DEVICE:$offset - its already the same"
      continue
    fi
    flash_offset $offset
    if ! check_flash_required $offset; then
      SUCCESS_COUNT=$((SUCCESS_COUNT - 1))
    fi
  done
  log "Flashing finished ($SUCCESS_COUNT of $OFFSETS_COUNT success)"
}


case "$1" in
  preinst)
    do_preinst "$@"
    ;;
  postinst)
    do_postinst "$@"
    ;;
  *)
    echo "Usage: $SCRIPT_NAME (preinst|postinst)"
    exit 1
    ;;
esac
