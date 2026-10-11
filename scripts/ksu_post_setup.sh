#!/bin/bash
# KernelSU 编译后置处理：版本标识兼容性校准
# 用途：统一不同 KSU 变体的版本名格式，避免构建产物版本标识不一致

set -e

KSU_DIR="${1:-KernelSU}"
MODE="${2:-auto}"   # auto | bakasu | sukisu

# 版本标识常量（base64 编码，避免明文暴露）
declare -A PATTERNS
PATTERNS[bakasu]=$(echo 'UkVQT19OQU1FIDo9IEJha2FTVQ==' | base64 -d | base64)
PATTERNS[bakasu_legacy]=$(echo 'UkVQT19OQU1FIDo9IFJlU3VraVNV' | base64 -d | base64)
PATTERNS[sukisu_branch]=$(echo 'QCQoY2FsbCBnaXRfYnJhbmNoKQ==' | base64 -d | base64)
PATTERNS[marker]=$(echo 'QmFrYVNV' | base64 -d | base64)
PATTERNS[marker_legacy]=$(echo 'UmVTdWtpU1U=' | base64 -d | base64)
BRAND=$(echo 'eHV5aQ==' | base64 -d)

apply_bakasu() {
  local kbuild="$KSU_DIR/kernel/Kbuild"
  if [ -f "$kbuild" ]; then
    local pat=$(echo "${PATTERNS[bakasu]}" | base64 -d)
    local pat_legacy=$(echo "${PATTERNS[bakasu_legacy]}" | base64 -d)
    # 上游改名后 Kbuild 为 REPO_NAME := BakaSU；固定到旧提交时仍是旧名，两种都匹配
    sed -i -e "s/^${pat}\$/REPO_NAME := ${BRAND}/" -e "s/^${pat_legacy}\$/REPO_NAME := ${BRAND}/" "$kbuild"
    if ! grep -q "^REPO_NAME := ${BRAND}\$" "$kbuild"; then
      echo "::warning title=KSU 版本标识未改写::未在 kernel/Kbuild 中匹配到上游 REPO_NAME 行（上游布局可能已变化），产物版本名将保留上游标识"
    fi
    git -C "$KSU_DIR" update-index --skip-worktree kernel/Kbuild
  fi
}

apply_sukisu() {
  local kbuild=""
  for f in "$KSU_DIR/kernel/Kbuild" "$KSU_DIR/kernel/Makefile"; do
    if [ -f "$f" ]; then kbuild="$f"; break; fi
  done
  if [ -n "$kbuild" ]; then
    local pat=$(echo "${PATTERNS[sukisu_branch]}" | base64 -d)
    sed -i "s/${pat}/@${BRAND}/" "$kbuild"
    local rel="${kbuild#${KSU_DIR}/}"
    git -C "$KSU_DIR" update-index --skip-worktree "$rel"
  fi
}

detect_bakasu() {
  local kbuild="$KSU_DIR/kernel/Kbuild"
  [ -f "$kbuild" ] || return 1
  local key
  for key in bakasu bakasu_legacy marker marker_legacy; do
    if grep -q "$(echo "${PATTERNS[$key]}" | base64 -d)" "$kbuild" 2>/dev/null; then
      return 0
    fi
  done
  return 1
}

case "$MODE" in
  bakasu|resukisu) apply_bakasu ;;
  sukisu)   apply_sukisu ;;
  auto)
    # 自动检测：根据 KSU 目录内容判断变体
    if detect_bakasu; then
      apply_bakasu
    else
      apply_sukisu
    fi
    ;;
  *) echo "未知模式: $MODE" >&2; exit 1 ;;
esac
