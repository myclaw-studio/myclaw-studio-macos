#!/bin/bash
set -e

# ── clean-release 同步脚本 ──────────────────────────────
# 从 open-source 分支 squash 合并最新代码，自动排除内部文件
#
# 用法:
#   git checkout clean-release
#   ./scripts/sync-to-public.sh
#   git push public clean-release:main

BRANCH=$(git branch --show-current)
if [ "$BRANCH" != "clean-release" ]; then
    echo "ERROR: 请先切换到 clean-release 分支"
    echo "  git checkout clean-release"
    exit 1
fi

echo ">>> 从 open-source 分支 squash 合并..."
git merge --squash open-source

# 排除内部文件（不应出现在公开仓库）
EXCLUDE_FILES=(
    ".gitattributes"
    "scripts/hooks/pre-merge-commit"
    "MemoryManagerTests.swift"
    "debug-screenshot/"
    ".github/workflows/branch-protection.yml"
    ".github/workflows/build-dmg-arm64.yml"
    ".github/workflows/build-dmg-intel.yml"
    ".github/workflows/build-dmg-main.yml"
    ".github/workflows/build-dmg-open-source.yml"
    ".github/copilot-instructions.md"
    ".github/workflows/build.yml"
)

echo ">>> 排除内部文件..."
for f in "${EXCLUDE_FILES[@]}"; do
    git reset -- "$f" 2>/dev/null || true
    git checkout -- "$f" 2>/dev/null || true
    # 如果是新增文件，从暂存区移除
    git rm --cached -r "$f" 2>/dev/null || true
done

# 确保 clean-release 自己的 build.yml（触发 main 分支）不被覆盖
git checkout -- .github/workflows/build.yml 2>/dev/null || true

echo ""
echo "========================================="
echo "同步完成！请检查变更后提交："
echo ""
echo "  git diff --cached --stat"
echo "  git commit -m \"v2.x.x: 更新说明\""
echo "  git push public clean-release:main"
echo "========================================="
