#!/usr/bin/env bash
# 应用 SUSFS 补丁及各内核版本所需的上下文修复
#
# 依赖环境变量：
#   ANDROID_VERSION KERNEL_VERSION KSU_VARIANT OS_PATCH_LEVEL SUB_LEVEL
#   KERNEL_ROOT SUSFS4KSU KERNEL_PATCHES LEGACY_SUKISU_CONFIG
# 调用前必须将工作目录设为 $KERNEL_ROOT
set -eo pipefail

echo "应用 SUSFS 补丁..."

SUSFS_PATCH="50_add_susfs_in_gki-$ANDROID_VERSION-$KERNEL_VERSION.patch"
cp "$SUSFS4KSU/kernel_patches/$SUSFS_PATCH" ./common/
cp "$SUSFS4KSU"/kernel_patches/fs/* ./common/fs/
cp "$SUSFS4KSU"/kernel_patches/include/linux/* ./common/include/linux/

case "$KSU_VARIANT" in
  "SukiSU"|"BakaSU"|"ReSukiSU")
    echo "SukiSU/BakaSU 使用内置 SUSFS 支持"
    ;;
esac

cd "$KERNEL_ROOT/common"
CURRENT_SUB="$SUB_LEVEL"
if [[ ! "$CURRENT_SUB" =~ ^[0-9]+$ ]]; then
  CURRENT_SUB=99999
fi

# 兼容缺少 VMA padding 接口的 5.10.66～209、5.15.74～144 和 6.1.25～68
if grep -qF 'VMA_PAD_START(vma)' "$SUSFS_PATCH" \
  && ! grep -Rqs 'VMA_PAD_START' ./include/linux; then
  echo "目标内核未提供 VMA_PAD_START，使用 vma->vm_end 兼容 SUSFS OPEN_REDIRECT"
  sed -i 's/VMA_PAD_START(vma)/vma->vm_end/g' "$SUSFS_PATCH"
fi

adjust_legacy_fdinfo_context() {
  sed -i '/^[[:space:]]*\/\*$/,/^[[:space:]]*u32 mask = mark->mask & IN_ALL_EVENTS;$/d' fs/notify/fdinfo.c
  perl -i -pe 's/\bmask,\s*mark->ignored_mask/inotify_mark_user_mask(mark)/g' fs/notify/fdinfo.c
  perl -i -pe 's/ignored_mask:%x/ignored_mask:0/g' fs/notify/fdinfo.c
}

restore_legacy_fdinfo_context() {
  perl -i -pe 's/^(\s+if \(inode\) \{)/$1\n\t\t\/\*\n\t\t * IN_ALL_EVENTS represents all of the mask bits\n\t\t * that we expose to userspace.  There is at\n\t\t * least one bit (FS_EVENT_ON_CHILD) which is\n\t\t * used only internally to the kernel.\n\t\t *\/\n\t\tu32 mask = mark->mask & IN_ALL_EVENTS;/m' fs/notify/fdinfo.c
  perl -i -pe 's/\binotify_mark_user_mask\(mark\)/mask, mark->ignored_mask/g' fs/notify/fdinfo.c
  perl -i -pe 's/ignored_mask:0/ignored_mask:%x/g' fs/notify/fdinfo.c
}

# 临时调整旧内核源码上下文，使 SUSFS 主补丁可以匹配
if [[ "$ANDROID_VERSION" == "android12" && "$KERNEL_VERSION" == "5.10" ]]; then
  if [[ -n "$LEGACY_SUKISU_CONFIG" && "$CURRENT_SUB" -le 43 ]]; then
    echo "临时调整 Android 12 5.10 base.c 上下文"
    perl -i -pe 's/(int|size_t)\s+this_len\s*=\s*min_t\s*\(\s*\1\s*,/size_t this_len = min_t(size_t,/;' fs/proc/base.c
  fi
  if [[ "$CURRENT_SUB" -le 117 ]]; then
    echo "临时调整 Android 12 5.10 fdinfo.c 上下文"
    adjust_legacy_fdinfo_context
  fi
fi

if [[ "$ANDROID_VERSION" == "android13" && "$KERNEL_VERSION" == "5.15" ]]; then
  if [[ "$CURRENT_SUB" -le 41 ]]; then
    echo "临时调整 Android 13 5.15 namespace.c/open.c/fdinfo.c 上下文"
    if ! grep -qF '#include <linux/mnt_idmapping.h>' fs/namespace.c; then
      sed -i '/^#include <linux\/shmem_fs.h>$/a #include <linux/mnt_idmapping.h>' fs/namespace.c
    fi
    if ! grep -qF '#include <linux/mnt_idmapping.h>' fs/open.c; then
      sed -i '/^#include <linux\/compat.h>$/a #include <linux/mnt_idmapping.h>' fs/open.c
    fi
    adjust_legacy_fdinfo_context
  fi
  if [[ "$OS_PATCH_LEVEL" == "lts" ]]; then
    echo "临时调整 Android 13 5.15 LTS 头文件上下文"
    sed -i '/^#include <trace\/hooks\/blk.h>$/d' fs/namespace.c
    sed -i '/^#include <trace\/hooks\/mm.h>$/d' fs/proc/task_mmu.c
  fi
fi

if [[ "$ANDROID_VERSION" == "android14" && "$KERNEL_VERSION" == "6.1" ]]; then
  if [[ "$CURRENT_SUB" -le 25 ]] && ! grep -qF '#include <trace/hooks/sched.h>' fs/proc/base.c; then
    echo "临时调整 Android 14 6.1 sched.h 上下文"
    sed -i '/^#include <trace\/events\/oom.h>$/a #include <trace/hooks/sched.h>' fs/proc/base.c
  fi
  if [[ "$CURRENT_SUB" -le 141 ]] && ! grep -qF '#include <linux/dma-buf.h>' fs/proc/base.c; then
    echo "临时调整 Android 14 6.1 dma-buf.h 上下文"
    sed -i '/^#include <linux\/cpufreq_times.h>$/a #include <linux/dma-buf.h>' fs/proc/base.c
  fi
  if [[ "$CURRENT_SUB" -ge 157 ]]; then
    echo "临时调整 Android 14 6.1 namespace.c 上下文"
    sed -i '/^#include <trace\/hooks\/blk.h>$/d' fs/namespace.c
  fi
fi

if [[ "$ANDROID_VERSION" == "android15" && "$KERNEL_VERSION" == "6.6" ]]; then
  if [[ "$CURRENT_SUB" -le 92 ]] && ! grep -qF '#include <linux/dma-buf.h>' fs/proc/base.c; then
    echo "临时调整 Android 15 6.6 base.c 上下文"
    sed -i '/^#include <linux\/cpufreq_times.h>$/a #include <linux/dma-buf.h>' fs/proc/base.c
  fi
  if [[ "$CURRENT_SUB" -le 57 ]] && ! grep -qF '#include <linux/zswap.h>' mm/memory.c; then
    echo "临时调整 Android 15 6.6 memory.c 上下文"
    sed -i '/^#include <linux\/sched\/sysctl.h>$/a #include <linux/zswap.h>' mm/memory.c
  fi
fi

if [[ "$ANDROID_VERSION" == "android16" && "$KERNEL_VERSION" == "6.12" ]]; then
  if [[ "$CURRENT_SUB" -ge 58 ]]; then
    echo "临时调整 Android 16 6.12 exec.c 上下文"
    sed -i '/^#include <linux\/dma-buf.h>$/d' fs/exec.c
  fi
fi

# 新版内核在 super.c 的 internal.h 之后新增了 trace/hooks/fs.h，
# 旧版 SUSFS 主补丁以 thaw_super_locked 为上下文插入 extern 声明，会整段被拒绝；
# 上游 2026-09-15 起已把声明挪到 unnamed_dev_ida 之后，不再依赖这段上下文，
# 但 ShirkNeko fork 尚未同步（固定提交的旧版补丁不改 super.c），只对旧版补丁做临时调整
SUPER_FS_H_REMOVED=""
if grep -q '^ static int thaw_super_locked' "$SUSFS_PATCH" \
  && grep -qF '#include <trace/hooks/fs.h>' fs/super.c; then
  echo "临时调整 super.c 上下文"
  sed -i '/^#include <trace\/hooks\/fs.h>$/,+1d' fs/super.c
  SUPER_FS_H_REMOVED=1
fi

patch -p1 < "$SUSFS_PATCH" || true

# ---- 预期冲突处理：上游已包含同款修改的 .rej 剔除，真实缺失的手工补齐 ----

# 1) fs/unicode：ASB 内核已包含上游 "unicode: don't special case ignorable code
#    points" 提交，主补丁删除 ignore_init / 重生成 utf8data 的 hunk 已天然满足
if [[ -f fs/unicode/mkutf8data.c.rej ]] && ! grep -q 'ignore_init' fs/unicode/mkutf8data.c; then
  echo "fs/unicode .rej 为上游已包含同款修改，剔除预期冲突文件"
  rm -f fs/unicode/*.rej
fi

# 2) mm/rmap.c：6.6.127+ 已包含 huge_pmd_unshare 的 tlb 化改造
if [[ -f mm/rmap.c.rej ]] && grep -q 'tlb_gather_mmu_vma' mm/rmap.c; then
  echo "mm/rmap.c .rej 为上游已包含同款修改，剔除预期冲突文件"
  rm -f mm/rmap.c.rej
fi

# 3) fs/proc/task_mmu.c（6.12.69+）：show_smap 重构（vma_pages → vma_data_pages）
#    导致 SUS_MAP 检查 hunk 上下文失配被拒，属于真实缺失，手工补回
if [[ -f fs/proc/task_mmu.c.rej ]] \
  && grep -qF 'static int show_smap(struct seq_file *m, void *v)' fs/proc/task_mmu.c; then
  SHOW_SMAP_BODY="$(sed -n '/^static int show_smap(struct seq_file \*m, void \*v)/,/^}/p' fs/proc/task_mmu.c)"
  if [[ -n "$SHOW_SMAP_BODY" ]] && ! grep -qF 'SUSFS_IS_INODE_SUS_MAP' <<< "$SHOW_SMAP_BODY"; then
    echo "为 show_smap 手工补入 SUS_MAP 检查（6.12.69+ 上下文漂移）"
    perl -0pi -e 's/(static int show_smap\(struct seq_file \*m, void \*v\)\n\{\n\tstruct vm_area_struct \*vma = v;\n\tstruct mem_size_stats mss = \{\};\n)/$1\n#ifdef CONFIG_KSU_SUSFS_SUS_MAP\n\tif (vma->vm_file) {\n\t\tif (SUSFS_IS_INODE_SUS_MAP(file_inode(vma->vm_file)))\n\t\t\treturn 0;\n\t}\n#endif \/\/ #ifdef CONFIG_KSU_SUSFS_SUS_MAP\n/' fs/proc/task_mmu.c
    if ! grep -qF 'SUSFS_IS_INODE_SUS_MAP' fs/proc/task_mmu.c; then
      echo "::error::show_smap SUS_MAP 检查手工补丁失败，请人工核对 fs/proc/task_mmu.c"
      exit 1
    fi
    rm -f fs/proc/task_mmu.c.rej
  fi
fi

# 为尚未提供 SU 会话 FD 接口的 SukiSU/BakaSU 恢复旧版 exec hook 行为
EXEC_HELPER=""
if [[ "$KSU_VARIANT" == SukiSU* || "$KSU_VARIANT" == "BakaSU" || "$KSU_VARIANT" == "ReSukiSU" ]]; then
  if grep -qF 'ksu_install_su_fd();' fs/exec.c; then
    EXEC_HELPER="ksu_install_su_fd"
  elif grep -qF 'ksu_handle_post_execveat_sucompat(' fs/exec.c; then
    EXEC_HELPER="ksu_handle_post_execveat_sucompat"
  fi
fi
if [[ -n "$EXEC_HELPER" ]] \
  && ! grep -RqsE --include='*.c' "^[[:space:]]*int[[:space:]]+${EXEC_HELPER}[[:space:]]*\(" "$KERNEL_ROOT/KernelSU/kernel"; then
  echo "$KSU_VARIANT 尚未提供 $EXEC_HELPER，恢复旧版 exec hook"
  sed -i '/^extern int ksu_install_su_fd(void);$/d' fs/exec.c
  sed -i '/^extern int ksu_handle_post_execveat_sucompat(/,+1d' fs/exec.c
  sed -i 's/is_su_session = !\(ksu_handle_execveat[^;]*;\)/\1/' fs/exec.c
  sed -i '/^[[:space:]]*bool is_su_session = false;$/d' fs/exec.c
  sed -i '/^[[:space:]]*if (unlikely(is_su_session && retval >= 0))$/,+1d' fs/exec.c
  sed -i '/^[[:space:]]*if (unlikely(is_su_session))$/,+1d' fs/exec.c
  sed -i '/^#ifdef CONFIG_KSU_SUSFS$/N;/^#ifdef CONFIG_KSU_SUSFS\n#endif \/\/ #ifdef CONFIG_KSU_SUSFS$/d' fs/exec.c
  if grep -qE 'ksu_install_su_fd|ksu_handle_post_execveat_sucompat|is_su_session' fs/exec.c; then
    echo "::error::$KSU_VARIANT exec hook 结构已变化，无法完成兼容修复"
    exit 1
  fi
fi

# 上游 5.10 主补丁把 susfs_sus_kstat_spoof_vfs_statfs 的 extern 声明放在了
# fs/statfs.c 的使用点之后（vfs_statfs 之前），clang -Werror 报隐式声明；
# 声明属于 SUSFS 接口，直接补进公共头 include/linux/susfs_def.h：
# 不依赖 statfs.c 内锚点与行号比较，声明重复合法，上游后续自行修复也不冲突
SUSFS_DEF_H="$KERNEL_ROOT/common/include/linux/susfs_def.h"
if [[ -f fs/statfs.c ]] && grep -qF 'susfs_sus_kstat_spoof_vfs_statfs(' fs/statfs.c \
  && [[ -f "$SUSFS_DEF_H" ]] \
  && ! grep -qF 'susfs_sus_kstat_spoof_vfs_statfs(' "$SUSFS_DEF_H"; then
  echo "将 susfs_sus_kstat_spoof_vfs_statfs 声明补入 include/linux/susfs_def.h"
  sed -i '/^#endif \/\/ #ifndef KSU_SUSFS_DEF_H$/i extern int susfs_sus_kstat_spoof_vfs_statfs(struct inode *inode, struct kstatfs *buf, bool *is_fuse);' "$SUSFS_DEF_H"
fi

# 上游 susfs.c 直接调用 security_sb_statfs 却没有包含 linux/security.h，
# 5.15+ 靠其他头文件间接带入，5.10 没有这条路径，clang -Werror 报隐式声明；缺失时补上
if [[ -f fs/susfs.c ]] && grep -qF 'security_sb_statfs(' fs/susfs.c \
  && ! grep -qF '#include <linux/security.h>' fs/susfs.c; then
  echo "为 susfs.c 补充 linux/security.h 头文件"
  sed -i '0,/^#include <linux\/fs.h>$/s//#include <linux\/fs.h>\n#include <linux\/security.h>/' fs/susfs.c
fi

# 在编译前报告 SUSFS 主补丁产生的冲突文件
SUSFS_REJ_COUNT=$(find . -name '*.rej' | wc -l)
if [ "$SUSFS_REJ_COUNT" -gt 0 ]; then
  echo "::warning title=SUSFS 补丁冲突::SUSFS 主补丁产生了 ${SUSFS_REJ_COUNT} 个 .rej 冲突文件，可能导致后续编译失败（详见 Rejects 产物）"
  find . -name '*.rej' -print
fi

# 还原仅用于补丁匹配的临时源码调整
if [[ "$ANDROID_VERSION" == "android12" && "$KERNEL_VERSION" == "5.10" ]]; then
  if [[ -n "$LEGACY_SUKISU_CONFIG" && "$CURRENT_SUB" -le 43 ]]; then
    echo "还原 Android 12 5.10 base.c 临时调整"
    sed -i 's/^size_t this_len = min_t(size_t, count, PAGE_SIZE);$/int this_len = min_t(int, count, PAGE_SIZE);/' fs/proc/base.c
  fi
  if [[ "$CURRENT_SUB" -le 117 ]]; then
    echo "还原 Android 12 5.10 fdinfo.c 临时调整"
    restore_legacy_fdinfo_context
  fi
fi

if [[ "$ANDROID_VERSION" == "android13" && "$KERNEL_VERSION" == "5.15" ]]; then
  if [[ "$CURRENT_SUB" -le 41 ]]; then
    echo "还原 Android 13 5.15 临时调整"
    sed -i '/#include <linux\/mnt_idmapping.h>$/d' fs/namespace.c
    sed -i '/#include <linux\/mnt_idmapping.h>$/d' fs/open.c
    restore_legacy_fdinfo_context
    sed -i 's|i_uid_into_mnt(i_user_ns(&fi->inode), &fi->inode).val|i_uid_into_mnt(\&init_user_ns, \&fi->inode).val|g' fs/susfs.c
    sed -i 's|i_uid_into_mnt(i_user_ns(inode), inode).val|i_uid_into_mnt(\&init_user_ns, inode).val|g' fs/susfs.c
  fi
  if [[ "$OS_PATCH_LEVEL" == "lts" ]]; then
    echo "还原 Android 13 5.15 LTS 头文件上下文"
    if ! grep -qF '#include <trace/hooks/blk.h>' fs/namespace.c; then
      sed -i '/^#include "internal.h"$/a #include <trace/hooks/blk.h>' fs/namespace.c
    fi
    if ! grep -qF '#include <trace/hooks/mm.h>' fs/proc/task_mmu.c; then
      sed -i '/^#include <linux\/pkeys.h>$/a #include <trace/hooks/mm.h>' fs/proc/task_mmu.c
    fi
  fi
fi

if [[ "$ANDROID_VERSION" == "android14" && "$KERNEL_VERSION" == "6.1" ]]; then
  if [[ "$CURRENT_SUB" -le 25 ]]; then
    sed -i '/^#include <trace\/hooks\/sched.h>$/d' fs/proc/base.c
  fi
  if [[ "$CURRENT_SUB" -le 141 ]]; then
    echo "还原 Android 14 6.1 base.c 临时调整"
    sed -i '/^#include <linux\/dma-buf.h>$/d' fs/proc/base.c
  fi
  if [[ "$CURRENT_SUB" -ge 157 ]] && ! grep -qF '#include <trace/hooks/blk.h>' fs/namespace.c; then
    echo "还原 Android 14 6.1 namespace.c 临时调整"
    sed -i '/^#include "internal.h"$/a #include <trace/hooks/blk.h>' fs/namespace.c
  fi
fi

if [[ "$ANDROID_VERSION" == "android15" && "$KERNEL_VERSION" == "6.6" ]]; then
  if [[ "$CURRENT_SUB" -le 92 ]]; then
    echo "还原 Android 15 6.6 base.c 临时调整"
    sed -i '/^#include <linux\/dma-buf.h>$/d' fs/proc/base.c
  fi
  if [[ "$CURRENT_SUB" -le 57 ]]; then
    echo "还原 Android 15 6.6 memory.c 临时调整"
    sed -i '/^#include <linux\/zswap.h>$/d' mm/memory.c
  fi
fi

if [[ "$ANDROID_VERSION" == "android16" && "$KERNEL_VERSION" == "6.12" ]]; then
  if [[ "$CURRENT_SUB" -ge 58 ]] && ! grep -qF '#include <linux/dma-buf.h>' fs/exec.c; then
    echo "还原 Android 16 6.12 exec.c 临时调整"
    sed -i '0,/^#include /s//#include <linux\/dma-buf.h>\n&/' fs/exec.c
  fi
fi

if [[ -n "$SUPER_FS_H_REMOVED" ]] \
  && ! grep -qF '#include <trace/hooks/fs.h>' fs/super.c; then
  echo "还原 super.c 临时调整"
  sed -i '/^#include "internal.h"$/a #include <trace/hooks/fs.h>' fs/super.c
fi

fix_missing_vm_flags_clear() {
  if [[ "$OS_PATCH_LEVEL" == "2024-11" ]] && grep -qF 'vm_flags_clear(new_vma, VM_PAD_MASK);' ./mm/mmap.c; then
    sed -i 's/vm_flags_clear(new_vma, VM_PAD_MASK);/new_vma->vm_flags \&= ~VM_PAD_MASK;/' ./mm/mmap.c
  fi
}

fix_task_mmu_show_pad() {
  local max_sub="$1"
  local excluded_patch_level="${2:-}"

  # 仅固定旧版 SUSFS 补丁会引入 goto show_pad，最新版已不再包含该代码
  if [[ -n "$LEGACY_SUKISU_CONFIG" && "$CURRENT_SUB" -le "$max_sub" ]] \
    && { [[ -z "$excluded_patch_level" ]] || [[ "$OS_PATCH_LEVEL" != "$excluded_patch_level" ]]; }; then
    sed -i -e 's/goto show_pad;/return 0;/' ./fs/proc/task_mmu.c
  fi
}

# Android 12 - 5.10 修复
if [[ "$ANDROID_VERSION" == "android12" && "$KERNEL_VERSION" == "5.10" ]]; then
  # 修复 2024-11 分支: mmap.c 调用了 vm_flags_clear()，但同分支 mm.h 未提供 helper
  fix_missing_vm_flags_clear
  fix_task_mmu_show_pad 209
fi

# Android 13 - 5.15 修复
  if [[ "$ANDROID_VERSION" == "android13" && "$KERNEL_VERSION" == "5.15" ]]; then
  # 修复 2024-11 分支: mmap.c 调用了 vm_flags_clear()，但同分支 mm.h 未提供 helper
  fix_missing_vm_flags_clear
  fix_task_mmu_show_pad 148 "2024-05"
fi

# Android 14 - 6.1 修复
if [[ "$ANDROID_VERSION" == "android14" && "$KERNEL_VERSION" == "6.1" ]]; then
  fix_task_mmu_show_pad 75 "2024-05"
fi

# Android 15 - 6.6 修复
if [[ "$ANDROID_VERSION" == "android15" && "$KERNEL_VERSION" == "6.6" ]]; then
  # 修复老版 SukiSU 6.6.50~6.6.58: task_mmu.c 打入 SUSFS 后使用 vma，但旧源码没有对应声明
  if [[ -n "$LEGACY_SUKISU_CONFIG" && "$CURRENT_SUB" -ge 50 && "$CURRENT_SUB" -le 58 ]] \
    && grep -qF 'vma = find_vma(mm, start_vaddr);' ./fs/proc/task_mmu.c; then
    TASK_MMU_PATCH="$KERNEL_PATCHES/wild/archived/susfs_fix_patches/v2.1.0/a15-6.6/task_mmu.c.patch"
    if [ ! -f "$TASK_MMU_PATCH" ]; then
      echo "::error::补丁不存在: $TASK_MMU_PATCH"
      exit 1
    fi
    cp "$TASK_MMU_PATCH" ./
    if patch -p1 --dry-run < task_mmu.c.patch >/dev/null 2>&1; then
      patch -p1 --no-backup-if-mismatch < task_mmu.c.patch
      echo "已应用 Android 15 6.6.50~6.6.58 task_mmu.c 归档修复补丁"
    else
      echo "Android 15 6.6.50~6.6.58 task_mmu.c 归档修复补丁已应用或当前上下文不匹配，跳过"
    fi
  fi
fi

# Android 16 - 6.12 修复
if [[ "$ANDROID_VERSION" == "android16" && "$KERNEL_VERSION" == "6.12" ]]; then
  # 固定旧版 SukiSU 在 6.12 上会重复定义 setresuid hook
  SETUID_HOOK="$KERNEL_ROOT/common/drivers/kernelsu/setuid_hook.c"
  if [[ -n "$LEGACY_SUKISU_CONFIG" && -f "$SETUID_HOOK" ]] \
    && grep -qF 'defined(CONFIG_KSU_MANUAL_HOOK))' "$SETUID_HOOK"; then
    sed -i 's/defined(CONFIG_KSU_MANUAL_HOOK))/!defined(CONFIG_KSU_SUSFS) \&\& defined(CONFIG_KSU_MANUAL_HOOK))/' "$SETUID_HOOK"
    echo "已修复 setuid_hook.c 重复定义问题"
  fi
fi
###############################################################################
# SELinux hide 跨版本兼容（按上游给出的修复思路实现）
#
# 上游 SUSFS/KSU 的 selinux_hide 换成了新形态（backup_sepolicy + 8 参 _with_policy），
# 与旧内核源码组合时会编译报错、或运行时 kernel panic。按内核版本分流：
#   1) 内核 < 6.6：security/selinux/hooks.c 里没有 should_check_current，但 KSU 侧
#      能扫到 ksu_selinux_hide_running —— 即 KSU_COMPAT_HAS_SUSFS_FEATURE_SELINUX_HIDE：
#      该组合不受支持，阻断编译并要求更新内核源码 / SUSFS 补丁。
#   2) 内核 >= 6.6：必须使用二改的 security_context_to_sid_with_policy /
#      security_sid_to_context_with_policy / security_compute_av_user_with_policy，
#      否则运行时 kernel panic；缺失即报错。
#   3) 内核 < 6.6：必须把旧版 fake_state 重新提供（同步上游时被一并删掉），
#      否则编译报错；检测到“有引用、无定义”就在 include 之后补回定义。
###############################################################################
selinux_hide_compat() {
  local ksu_dirs="$KERNEL_ROOT/common/drivers/kernelsu $KERNEL_ROOT/KernelSU"
  local hide_file
  hide_file=$(grep -Rls 'ksu_selinux_hide_running' $ksu_dirs 2>/dev/null | head -n 1 || true)
  if [ -z "$hide_file" ]; then
    echo "SELinux hide 兼容：KSU 侧未启用 selinux_hide，跳过"
    return 0
  fi
  echo "SELinux hide 兼容：KSU 侧实现 = ${hide_file#"$KERNEL_ROOT"/}"

  local ge66=false
  if [ "$(printf '%s\n6.6\n' "$KERNEL_VERSION" | sort -V | head -n 1)" = "6.6" ]; then
    ge66=true
  fi

  if [ "$ge66" = true ]; then
    local missing="" fn
    for fn in security_context_to_sid_with_policy security_sid_to_context_with_policy security_compute_av_user_with_policy; do
      grep -Rqs "$fn" $ksu_dirs || missing="$missing $fn"
    done
    if [ -n "$missing" ]; then
      echo "::error title=SUSFS SELinux hide 不兼容::$KERNEL_VERSION（>=6.6）需要二改的 *_with_policy 函数（否则运行时 kernel panic），当前缺失:$missing。请更新 SUSFS/KSU 源码后重试" >&2
      exit 1
    fi
    echo "SELinux hide 兼容：>=6.6，二改 *_with_policy 已就位"
    return 0
  fi

  # ---------------- 内核 < 6.6 ----------------
  local hooks="$KERNEL_ROOT/common/security/selinux/hooks.c"
  if [ -f "$hooks" ] && ! grep -qs 'should_check_current' "$hooks"; then
    echo "::error title=KSU_COMPAT_HAS_SUSFS_FEATURE_SELINUX_HIDE::$KERNEL_VERSION（<6.6）的 security/selinux/hooks.c 缺少 should_check_current，而 KSU 侧已启用 selinux_hide（ksu_selinux_hide_running）。该组合不受支持，已阻断编译；请更新内核源码或 SUSFS 补丁后重试" >&2
    exit 1
  fi

  if grep -q 'fake_state' "$hide_file" \
    && ! grep -qE '^[[:space:]]*(static[[:space:]]+)?struct selinux_state[[:space:]]+fake_state' "$hide_file"; then
    echo "SELinux hide 兼容：<6.6 缺少旧版 fake_state 定义，按上游思路就地补回"
    awk 'NR==FNR { if ($0 ~ /^#include/) last=NR; next }
         { print; if (FNR==last && !done) { print "static struct selinux_state fake_state;"; done=1 } }' \
      "$hide_file" "$hide_file" > "$hide_file.tmp"
    mv "$hide_file.tmp" "$hide_file"
    if ! grep -qE '^static struct selinux_state fake_state;' "$hide_file"; then
      echo "::error::补回 fake_state 定义失败（$hide_file）" >&2
      exit 1
    fi
    echo "SELinux hide 兼容：已补回 static struct selinux_state fake_state;"
  else
    echo "SELinux hide 兼容：<6.6，fake_state 无需补回"
  fi
}
selinux_hide_compat

# ---- 上游 BakaSU 的硬失败放行 ----
# kernel/tools/susfs_compat.mk 末尾目前无条件写着
#   $(info -- $(REPO_NAME): susfs has NOT update with latest KernelSU source)
#   $(info -- $(REPO_NAME): Please wait simonpunk update)
#   $(error Please wait susfs update.)
# 于是所有构建都在等 simonpunk 更新 SUSFS 之前无法通过。按上游给出的修复思路自行放行：
# 该文件上面的 KSU_COMPAT_* 宏仍按源码自动探测（不改动其判断），版本相关的兼容规则由
# 上面的 selinux_hide_compat 负责（<6.6 缺 should_check_current 阻断、>=6.6 需二改
# 的 *_with_policy、<6.6 补回旧版 fake_state），所以这里仅摘掉那句无条件硬失败。
susfs_compat_unblock() {
  local mk=""
  local cand
  for cand in "$KERNEL_ROOT/KernelSU/kernel/tools/susfs_compat.mk" \
              "$KERNEL_ROOT/common/drivers/kernelsu/kernel/tools/susfs_compat.mk"; do
    if [ -f "$cand" ]; then mk="$cand"; break; fi
  done
  if [ -z "$mk" ]; then
    echo "SUSFS compat：未找到 susfs_compat.mk（该分支可能不含此检查），跳过"
    return 0
  fi
  if grep -q '^\$(error' "$mk"; then
    echo "SUSFS compat：移除上游硬编码的 \$(error Please wait susfs update.)（按上游修复思路自行放行）"
    sed -i '/^\$(error/d' "$mk"
    if grep -q '^\$(error' "$mk"; then
      echo "::error::移除 $mk 里的硬失败失败" >&2
      exit 1
    fi
    grep -n 'KSU_COMPAT_HAS_SUSFS_FEATURE_SELINUX_HIDE\|KSU_COMPAT_HAS_SUSFS_INSTALL_SU_FD_DIRECT_CALL' "$mk" | head -4
  else
    echo "SUSFS compat：susfs_compat.mk 已无硬失败，跳过"
  fi
}
susfs_compat_unblock

# ---- SukiSU 新宏在旧内核上的回退 ----
# SukiSU 最新源码的 manager/pkg_observer.c 使用 TRACK_THRONE_FORCE_SYNCHRONOUS，该宏只在
# 较新内核里存在；6.1 等旧内核只有 PROBE_FORCE_SYNCHRONOUS，编译即报
#   error: use of undeclared identifier 'TRACK_THRONE_FORCE_SYNCHRONOUS'
# 内核头文件没有新宏时，把源码里的新名字回退成旧名字。
ksu_track_throne_compat() {
  local f="" cand
  for cand in "$KERNEL_ROOT/common/drivers/kernelsu/manager/pkg_observer.c" \
              "$KERNEL_ROOT/KernelSU/manager/pkg_observer.c"; do
    if [ -f "$cand" ]; then f="$cand"; break; fi
  done
  if [ -z "$f" ] || ! grep -q 'TRACK_THRONE_FORCE_SYNCHRONOUS' "$f"; then
    echo "KSU 新宏兼容：pkg_observer.c 未使用 TRACK_THRONE_FORCE_SYNCHRONOUS，跳过"
    return 0
  fi
  if grep -Rqs 'TRACK_THRONE_FORCE_SYNCHRONOUS' "$KERNEL_ROOT/common/include" 2>/dev/null; then
    echo "KSU 新宏兼容：内核已提供该宏，保持原样"
    return 0
  fi
  sed -i 's/TRACK_THRONE_FORCE_SYNCHRONOUS/PROBE_FORCE_SYNCHRONOUS/g' "$f"
  if grep -q 'TRACK_THRONE_FORCE_SYNCHRONOUS' "$f"; then
    echo "::error::回退 TRACK_THRONE_FORCE_SYNCHRONOUS 失败（$f）" >&2
    exit 1
  fi
  echo "KSU 新宏兼容：已把 pkg_observer.c 的 TRACK_THRONE_FORCE_SYNCHRONOUS 回退为 PROBE_FORCE_SYNCHRONOUS"
}
ksu_track_throne_compat

# ---- SukiSU builtin 的 dynamic manager ioctl 标识符合并残留 ----
# 上游 builtin 把 main 的 dynamic manager 移植过来时，uapi/supercall.h 里 106 号
# ioctl 那一行漏改（main 用的是 KSU_IOCTL_MANAGER）：
#   DECLARE(__u32, KSU_IOCTL_KPM, _IOWR('K', 106, ksu_manager_cmd));
# 这一行有两个缺陷：
#   1) 标识符仍叫 KSU_IOCTL_KPM，与同一文件里 200 号的真正 KPM ioctl 重名 ——
#      enum 里出现重复 enumerator，编译必报错；
#   2) 类型漏了 struct 关键字（树里没有 ksu_manager_cmd 的 typedef）——
#      clang 报 error: use of undeclared identifier 'ksu_manager_cmd'。
# 而 kernel/supercall/dispatch.c 的 do_manager 注册用的是 KSU_IOCTL_MANAGER，
# 于是这个被使用的名字在头文件里从未被声明。注意 manager.h / dynamic_manager.c
# 在 builtin 与 main 里逐字节相同（且已由 ksu.c 引入），不需要从 main 搬文件，
# 只要把这一行补正成 KSU_IOCTL_MANAGER + struct ksu_manager_cmd 即可。
# 上游修正后本步骤按内容检测自动跳过。
ksu_manager_ioctl_compat() {
  local candidates=(
    "$KERNEL_ROOT/KernelSU/kernel/include/uapi/supercall.h"
    "$KERNEL_ROOT/common/drivers/kernelsu/include/uapi/supercall.h"
    "$KERNEL_ROOT/KernelSU/uapi/supercall.h"
    "$KERNEL_ROOT/common/drivers/kernelsu/uapi/supercall.h"
  )
  local uapi="" cand
  for cand in "${candidates[@]}"; do
    if [ -f "$cand" ]; then uapi="$cand"; break; fi
  done
  if [ -z "$uapi" ]; then
    echo "KSU manager ioctl 兼容：未找到 uapi/supercall.h（该分支布局可能已变化），跳过"
    return 0
  fi

  # DECLARE(__u32, NAME, ...) 与 static const __u32 NAME = ... 两种声明形态都认
  if grep -qE '\bKSU_IOCTL_MANAGER\b[[:space:]]*[=,]' "$uapi"; then
    echo "KSU manager ioctl 兼容：$uapi 已声明 KSU_IOCTL_MANAGER，跳过"
    return 0
  fi

  local used_in
  used_in=$(grep -Rls 'KSU_IOCTL_MANAGER' \
              "$KERNEL_ROOT/KernelSU" "$KERNEL_ROOT/common/drivers/kernelsu" 2>/dev/null \
            | head -n 1 || true)
  if [ -z "$used_in" ]; then
    echo "KSU manager ioctl 兼容：树内未引用 KSU_IOCTL_MANAGER，无需处理"
    return 0
  fi
  echo "KSU manager ioctl 兼容：${used_in#"$KERNEL_ROOT"/} 引用了未声明的 KSU_IOCTL_MANAGER，补正 $uapi 的 106 号 ioctl 行"

  # 只动“同一行里既有 KSU_IOCTL_* 标识符、又出现 ksu_manager_cmd”的那一行，
  # 即 106 号 ioctl 的声明行；不锚定行尾，兼容 CRLF 检出。
  perl -i -pe '
    next unless /\bKSU_IOCTL_[A-Z0-9_]+\b/ && /\bksu_manager_cmd\b/;
    s/(?<!struct )\bksu_manager_cmd\b/struct ksu_manager_cmd/g;
    s/\bKSU_IOCTL_[A-Z0-9_]+\b/KSU_IOCTL_MANAGER/;
  ' "$uapi"

  # 写后校验：MANAGER/KPM 各自恰好一个定义，且 106 号行带上 struct 关键字
  local mgr_count kpm_count
  mgr_count=$(grep -cE '\bKSU_IOCTL_MANAGER\b[[:space:]]*[=,]' "$uapi" || true)
  kpm_count=$(grep -cE '\bKSU_IOCTL_KPM\b[[:space:]]*[=,]' "$uapi" || true)
  if [ "$mgr_count" != "1" ] || [ "$kpm_count" != "1" ] \
    || ! grep -qE "106[^)]*struct[[:space:]]+ksu_manager_cmd" "$uapi"; then
    echo "::error title=KSU manager ioctl 兼容失败::未能补正 $uapi 的 106 号 ioctl 声明（KSU_IOCTL_MANAGER 定义数=$mgr_count，KSU_IOCTL_KPM 定义数=$kpm_count）。上游布局可能已变化，请对比 main 分支的 uapi/supercall.h 人工核对" >&2
    exit 1
  fi
  echo "KSU manager ioctl 兼容：已把 106 号 ioctl 补正为 KSU_IOCTL_MANAGER = _IOWR('K', 106, struct ksu_manager_cmd)"
}
ksu_manager_ioctl_compat

# ---- SukiSU builtin 的 throne_tracker 合并残留（与上一处同一批移植）----
# 上游 builtin 移植 dynamic multi-manager（a233901 / PR #987）时还漏改了一处：
# crown_manager() 里 pkg 是 if (sig_fallback) 块内的局部变量，函数末尾那个
# 「跳过内置管理器、只给动态管理器加冕」的循环却在块外引用它：
#   common/drivers/kernelsu/manager/throne_tracker.c:97: error:
#     use of undeclared identifier 'pkg'
# main 分支该行用的是 KSU_PACKAGE_NAME（语义＝跳过内置管理器自己那条记录，
# 见 main 对应循环里的 continue），按 main 换回去即可；块内那处合法用法不动。
# 该文件里这串调用只会出现两次（一次块内、一次块外），据此判定并按内容跳过。
ksu_throne_tracker_pkg_compat() {
  local f="" cand
  for cand in "$KERNEL_ROOT/common/drivers/kernelsu/manager/throne_tracker.c" \
              "$KERNEL_ROOT/KernelSU/kernel/manager/throne_tracker.c"; do
    if [ -f "$cand" ]; then f="$cand"; break; fi
  done
  if [ -z "$f" ]; then
    echo "KSU throne_tracker 兼容：未找到 manager/throne_tracker.c（该分支布局可能已变化），跳过"
    return 0
  fi

  local pat='strncmp(np->package, pkg, KSU_MAX_PACKAGE_NAME)'
  local n
  n=$(grep -oF "$pat" "$f" | wc -l || true)
  if [ "$n" -eq 1 ]; then
    echo "KSU throne_tracker 兼容：pkg 只在 sig_fallback 块内使用，无需处理"
    return 0
  fi
  if [ "$n" -eq 0 ]; then
    echo "KSU throne_tracker 兼容：未找到 \"$pat\"（上游可能已重构该函数），跳过"
    return 0
  fi
  if [ "$n" -ne 2 ]; then
    echo "::error title=KSU throne_tracker 兼容失败::$f 中 \"$pat\" 出现 $n 次（期望 0/1/2 次），无法判定哪一处是块外残留，请对照 main 分支人工核对" >&2
    exit 1
  fi

  echo "KSU throne_tracker 兼容：块外残留引用了局部变量 pkg，按 main 换回 KSU_PACKAGE_NAME"
  # 第一处在 if (sig_fallback) 块内（合法），只改最后一处
  perl -0777 -i -pe '
    my $pat = q{strncmp(np->package, pkg, KSU_MAX_PACKAGE_NAME)};
    my $n = () = /\Q$pat\E/g;
    my $i = 0;
    s{\Q$pat\E}{ ++$i == $n ? "strncmp(np->package, KSU_PACKAGE_NAME, KSU_MAX_PACKAGE_NAME)" : $& }ge;
  ' "$f"

  # 写后校验：块内那处保留、块外那处已换掉
  n=$(grep -oF "$pat" "$f" | wc -l || true)
  if [ "$n" -ne 1 ] \
    || ! grep -qF 'strncmp(np->package, KSU_PACKAGE_NAME, KSU_MAX_PACKAGE_NAME)' "$f"; then
    echo "::error::throne_tracker.c 补正失败（剩余 \"$pat\" $n 处），请对照 main 分支人工核对" >&2
    exit 1
  fi
  echo "KSU throne_tracker 兼容：已把块外的 pkg 换回 KSU_PACKAGE_NAME"
}
ksu_throne_tracker_pkg_compat