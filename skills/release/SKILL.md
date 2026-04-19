---
name: release
description: 在 apple_view_model 仓库发布一个新版本。触发场景：用户说 "发版 / 发个 tag / 打新 tag / release / 发一版 / ship 一下"。做的事：决定新版本号 → 归并 CHANGELOG 的 [Unreleased] → 跑构建和测试 → 提交 → 打 tag → 推 main 与 tag → 把该版本 CHANGELOG 段落同步到 GitHub Release。
---

# Release Skill（apple_view_model）

本仓库的发版 SOP——从"代码/文档已 ready"到 "GitHub Release 出现一条新 Release Notes" 全流程。

## 何时触发

- 用户说 "发版" / "发个新 tag" / "发个 release" / "ship 一下" / "更新到 0.3.0"
- 用户明确给出新版本号（例："发 0.3.0"）——走"指定版本号"路径
- 用户没说版本号——走"推断版本号"路径（见下）

## 前置检查（必须先过）

1. **工作区干净或变更已归集**：`git status` 看当前 diff；要么都该进这个版本要么先 stash。
2. **跑完构建 + 测试**：`swift build && swift test`。任何一个失败就**停**，修好再继续。
3. **CHANGELOG 已写 `[Unreleased]` 段**：如果没有、或只有一行 `## [Unreleased]`，先跟用户确认本次到底改了什么，把 Added / Changed / Fixed / Removed / Deprecated / Security 条目写全。

## 步骤

### 1. 定版本号

查最近 tag：

```bash
git tag -l | tail -5
```

选择规则（优先级从高到低）：

- 用户给定 → 用用户给定的
- `0.x.y` 阶段（当前就是）：
  - **破坏性改动**（删 public API、改签名、重命名协议等）→ bump **minor**（0.1.0 → 0.2.0）
  - 新增 API / 功能增强 → bump **minor**
  - 纯 bug 修复 / 文档 / 内部重构 → bump **patch**（0.1.0 → 0.1.1）
- `1.0.0` 之后：严格 SemVer——破坏性必须撞 major。

不确定就把 `[Unreleased]` 的条目摊给用户，问一句 "按 X.Y.Z 发？"。

### 2. 归并 CHANGELOG

把 `## [Unreleased]` 下面的内容切走，放进新版本段落。保留一个空的 `## [Unreleased]` 在顶部。日期用 **今天的绝对日期**（格式 `YYYY-MM-DD`）。

示例（用户让发 0.3.0，今天 2026-05-01）：

```markdown
## [Unreleased]

## [0.3.0] - 2026-05-01

### Added

- ...

### Changed

- ...
```

### 3. 再跑一次构建/测试（防止 CHANGELOG 之外的尾巴）

```bash
swift build && swift test
```

### 4. 提交

用约束性 commit 规范。scope 用实际改动的模块名（`core` / `ui` / `binding` / `docs` / ...）。**发版本身不单独 commit**——发版 commit 应当就是"把改动 + CHANGELOG 归并" 一起提交的那个 commit。

如果 CHANGELOG 归并是单独的一步（比如你在 ready 状态下只需要归并 CHANGELOG），commit 消息可用：

```
docs(changelog): 归并 [Unreleased] 到 0.3.0
```

更常见的情况是功能改动和 CHANGELOG 在同一个 commit 里，用功能的 scope + 描述。破坏性改动用 `!`，并在正文里加 `BREAKING CHANGE:` 段。

### 5. 打 tag

```bash
git tag -a 0.3.0 -m "Release 0.3.0"
```

> ⚠️ tag 名用**纯数字版本号**，无 `v` 前缀（跟 `0.1.0` / `0.2.0` 保持一致）。

### 6. 推送

分两步推（别合并成一条）：

```bash
git push origin main
git push origin 0.3.0
```

### 7. 同步 CHANGELOG 到 GitHub Release

从 CHANGELOG 里抽出**新版本**的段落（从 `## [0.3.0] - DATE` 到下一个 `## [` 之前），用 `gh release create` 创建 release。正文直接用这一段。

**推荐命令**（用 HEREDOC 避免引号地狱）：

```bash
VERSION=0.3.0
DATE=$(date +%Y-%m-%d)   # 或者从 CHANGELOG 里 grep 出日期

# 用 awk 抽出这一版的段落（不含下一版标题）
NOTES=$(awk "/^## \[$VERSION\]/{flag=1; next} /^## \[/{flag=0} flag" CHANGELOG.md)

gh release create "$VERSION" \
  --title "$VERSION" \
  --notes "$NOTES"
```

如果 `gh` 还没装/没登录，提示用户：`brew install gh && gh auth login`。

想加 `--verify-tag` 做二次校验也行：

```bash
gh release create "$VERSION" --verify-tag --title "$VERSION" --notes "$NOTES"
```

### 8. 收尾校验

- 打开 `https://github.com/lwj1994/apple_view_model/releases/tag/0.3.0` 确认 Release 页正常
- `git ls-remote --tags origin | grep 0.3.0` 确认 tag 在远端
- 下游 SwiftPM 消费者如果 pin `from:`，下次 `swift package update` 就能拉到

## 硬性约束

1. **tag 一旦推上去不能移动**。下游已经 pin `from: "0.3.0"` 或 `.exact("0.3.0")`，tag 漂移 = 相同版本号不同内容 = 调试噩梦。需要修就发 0.3.1。
2. **永远不 `--force` 推 main**。
3. **commit 不 `--no-verify`、不 `--no-gpg-sign`**（除非用户明确让绕）。hook 失败就修 hook，别跳过。
4. **`[Unreleased]` 段永远保留**——归并后留一个空的在顶部，下次发版直接往里写。
5. 发版过程中每一步执行完都给用户短反馈（"commit 过了 / tag 打了 / push 完成 / release 建好了 <url>"），别闷头走完。

## 失败恢复

- **tag 已打、push 前发现问题**：`git tag -d 0.3.0`，改完再重打。
- **tag 已 push、release 没建**：tag 留着别动，直接补 `gh release create`。
- **tag 已 push、release 已建但发现 CHANGELOG 写错**：
  - CHANGELOG 改一遍，commit + push 到 main（不改 tag）
  - `gh release edit 0.3.0 --notes "$NEW_NOTES"` 只更新 Release 正文
- **版本号发错了**（比如该发 minor 发了 patch）：tag 不删，补发下一个正确的版本号。

## 最小化示例（把上面浓缩成一串命令）

给用户确认 VERSION 后，按顺序执行：

```bash
VERSION=0.3.0
DATE=$(date +%Y-%m-%d)

# 1. 归并 CHANGELOG（用 Edit 工具直接改 CHANGELOG.md，这里仅示意）
# 2. 验证
swift build && swift test || { echo "build/test failed, abort"; exit 1; }

# 3. 提交
git add -- CHANGELOG.md <其它改动文件>
git commit -m "<合适的 scope>: <描述>"

# 4. tag
git tag -a "$VERSION" -m "Release $VERSION"

# 5. 推
git push origin main
git push origin "$VERSION"

# 6. Release
NOTES=$(awk "/^## \[$VERSION\]/{flag=1; next} /^## \[/{flag=0} flag" CHANGELOG.md)
gh release create "$VERSION" --title "$VERSION" --notes "$NOTES"
```
