# LTT 系列 —— L4D2 多特服务器插件源码

> 本仓库**只收录我们自己写的 LTT 系列插件源码**（`.sp`）。
> 第三方插件（AlliedModders 各家作者、豆瓣酱な 等）的源码**不在本仓库**，见 `NOTICE.md`。

## ⚠️ 关于作者与 AI 生成内容

**本仓库的代码与文档全部由 AI 生成**（DeepSeek Harness / DeepSeek 系列模型，经多轮对话产出），
**不是作者逐行手写的**。作者承担的角色是：提出需求、在真实服务器上实测与反馈、审核与采纳、以及运维。

- AI 生成的代码**没有软件工程层面的质量保证**：可能存在没覆盖的边界、没测到的分支、
  或与特定 SourceMod / 游戏版本耦合的假设。请自行审阅后再用于生产环境。
- 每个插件的头注释里写了「为什么这么写」和踩过的坑，那是**调试记录**，不是同行评审结论。
- 因使用本仓库代码造成的任何后果由使用者自行承担（见 `LICENSE` 的免责条款）。
- `NOTICE.md` 里列出的第三方插件**不是 AI 生成的**，它们的版权归各自作者，也不在本仓库内。

## 编译

需要 **SourceMod 1.12.x** 的 `spcomp`，以及 `left4dhooks 1.168`（部分插件依赖）。
每个插件都是单文件，直接编译即可：

```bash
spcomp plugins/ltt_kd/ltt_kd.sp -o ltt_kd.smx -i <sourcemod>/scripting/include
```

部署：把 `.smx` 放到 `addons/sourcemod/plugins/`，然后 `sm plugins load <名字>`（或 `reload`）。
每次插件都会自动生成 `cfg/sourcemod/<插件名>.cfg`，改配置不用重编。

## 插件清单

| 插件 | 版本 | 文件 | 作用 |
|---|---|---|---|
| `ltt_autorelease` | 1.1.3 | `ltt_autorelease.sp` | ltt_autorelease —— 特感控人后自动解控（单人练习「防控」用） |
| `ltt_bile_retarget` | 1.0.4 | `ltt_bile_retarget.sp` | [LTT] Bile Retarget —— 特感目标接管（取代 [L4D & L4D2] Target Override） |
| `ltt_boss` | 1.2.0 | `ltt_boss.sp` | ltt_boss v1.1.0 —— 坦克（Tank）管理：数量上限 / 本图不刷 / 一键处死 / 出场播报 |
| `ltt_client_cvars` | 1.0.0 | `ltt_client_cvars.sp` | [LTT] Client Cvar Pusher — 服务器下发客户端参数 |
| `ltt_diag` | 2.2.1 | `framelog_v220.sp` | 帧耗时/卡顿归因日志（framelog 系列最终版） |
| `ltt_direct_probe` | 1.1.1 | `ltt_direct_probe.sp` | ltt_direct_probe —— 突破特感上限实验，用完即删 |
| `ltt_firez` | 1.2.0 | `ltt_firez.sp` | ltt_firez v1.2.0 —— 只用于实测的一次性探针 |
| `ltt_flashlight` | 1.0.3 | `ltt_flashlight.sp` | [LTT] Server Flashlight — 服务端手电筒 |
| `ltt_healvote` | 1.0.2 | `ltt_healvote.sp` | LTT Heal Amount Vote  ——  投票决定「击杀特感回复多少血量」 |
| `ltt_hitsound` | 1.1.10-Optimized | `ltt_hitsound.sp` | 玩家音效选择状态 |
| `ltt_kd` | 1.0.16 | `ltt_kd.sp` | ltt_kd  v1.0.10 —— 击杀统计 + 排行榜（聊天框） |
| `ltt_laugh` | 1.2.1 | `ltt_laugh.sp` | ltt_laugh  v1.2.0  ——  玩家"笑声/嘲讽"→ 全服广播 + 惩罚（三种方式 + 按重开次数升级） |
| `ltt_level_heal` | 1.7.0 | `ltt_level_heal.sp` | v1.4.0：换图后读图慢的人补血 |
| `ltt_longad` | 1.0.0 | `ltt_longad.sp` | LTT Long Ads  ——  长文案广告 |
| `ltt_loopguard` | 1.1.1 | `ltt_loopguard.sp` | （见源码头注释） |
| `ltt_megamob` | 2.10.0 | `ltt_megamob.sp` | [LTT] Mega Mob（机关尸潮可调）—— 独立插件 v1.0.0 |
| `ltt_melee_lag` | 1.4.0 | `ltt_melee_lag.sp` | ltt_melee_lag —— 「刀不掉飞扑」**只记账、不动作**探针（v1.2.0） |
| `ltt_melee_onehit` | 1.0.2 | `ltt_melee_onehit.sp` | ltt_melee_onehit —— 近战武器对特感**一刀死**（可配置哪些特感；默认牛牛除外） |
| `ltt_no_interrupt` | 1.1.0 | `ltt_no_interrupt.sp` | ltt_no_interrupt  v1.1.0  —— 小丧尸不能打断救助 |
| `ltt_sdk_probe` | 1.0.1 | `ltt_sdk_probe.sp` | ltt_sdk_probe  ——  最终对照实验，用完即删 |
| `ltt_servername` | 1.0.15 | `ltt_servername.sp` | ltt_servername v1.0.0 —— 服务器名按模板动态刷新（照 NekoServerName 那套机制重写） |
| `ltt_si_ai` | 1.1.0 | `ltt_si_ai.sp` | ltt_si_ai  v1.0.0  ——  特感主动进攻修正（纯脚本，不依赖 BinHooks） |
| `ltt_si_bile_probe` | 1.0.2 | `ltt_si_bile_probe.sp` | ltt_si_bile_probe v1.0.1 —— 只在"有人被胆汁喷中"的窗口里记账（**零动作**） |
| `ltt_si_menu` | 1.2.23 | `ltt_si_menu.sp` | ltt_si_menu  v1.2.13  —— 刷特设置的玩家菜单 + 原生投票（F1 同意 / F2 反对） |
| `ltt_si_probe` | 1.1.1 | `ltt_si_probe.sp` | ltt_si_probe  ——  临时探针，用完即删 |
| `ltt_si_spawner` | 1.49.10 | `ltt_si_spawner.sp` | ltt_si_spawner  v1.18.0  —— 刷特核心 |
| `ltt_si_witch` | 1.0.0 | `ltt_si_witch.sp` | ltt_si_witch  v1.0.0  —— 女巫（Witch）控制：总开关 + 数量上限 |
| `ltt_skill_lite` | 1.2.1 | `ltt_skill_lite.sp` | ltt_skill_lite |
| `ltt_skillreward` | 1.0.0 | `ltt_skillreward.sp` | LTT Melee Skill Reward  ——  低难度下「刀空爆 / 刀牛」额外回血 |
| `ltt_stagger_damage` | 1.0.0 | `ltt_stagger_damage.sp` | ltt_stagger_damage  v1.0.0 —— 硬直追击伤害（Boomer 爆炸 / Hunter 扑 / Jockey 骑） |
| `ltt_svote` | 1.2.11 | `ltt_svote.sp` | LTT Server Vote v1.2.7 |
| `ltt_t1vote` | 1.0.2 | `ltt_t1vote.sp` | ltt_t1vote —— 全图 T2→T1 武器替换（含三方图）+ 原生投票开关 |

> 版本号以各文件里的 `#define PLUGIN_VERSION` 为准；本表由脚本从源码自动抽取。

---

## 目录结构

```
plugins/<插件名>/<插件名>.sp     # 源码（个别插件的主文件名与目录名不同，如 ltt_diag → framelog_v220.sp）
```

## 说明

- **不含**编译产物（`.smx`）、**不含** `cfg`（配置由插件首次加载时自动生成）；编译好的 `.smx` 见 [Releases](https://github.com/buludebin/l4d2-ltt-plugins/releases)。
- 完整设计稿**不随仓库公开**（含真实玩家昵称与服务器运维细节）；关键决策与踩坑记录保留在各插件头注释里。
- 每个插件头注释里一般都有「为什么这么写」的说明与踩坑记录，改之前建议先读头注释。

## 开源协议

本项目以 **GNU GPL v3** 发布，全文见 [`LICENSE`](LICENSE)。

```
Copyright (C) 2026 buludebin (LTT)

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.
```

- 你可以自由使用、修改、再发布，**但修改后的源码必须以同一协议公开**（GPL 的传染性）。
- **第三方插件源码不在本仓库**（见 `NOTICE.md`），它们的版权归各自作者，不在本协议覆盖范围内。
- 如果你想用在闭源/商业项目里，GPL-3.0 不适用 —— 可另行联系作者谈授权。
