# NOTICE

## 关于 AI 生成

本仓库内的 **LTT 系列插件源码与全部文档均为 AI 生成**（DeepSeek Harness / DeepSeek 系列模型，
经多轮对话产出），不是作者手写；作者负责需求、实测反馈、审核采纳与运维。
使用前请自行审阅与测试，作者不对代码正确性、安全性或适用性作任何担保（详见 `LICENSE`）。

## 设计参考与二改来源

写这些插件之前，作者参考过社区里若干个现成插件的**行为与思路**（例如"刷特应该怎么选点""夜视仪怎么调亮度"），
然后由 AI 重新实现。**这几个插件的源码不在本仓库**，也不会随本仓库分发。

为了把这件事说清楚，我们对每一个都做了**逐行源码比对**（去掉注释与空行后，统计两边完全相同的行）：

| 我们的插件 | 参考过的插件 | 原作者 | 逐行相同 |
|---|---|---|---|
| `ltt_si_spawner` | `specialspawner v1.3.7` | Tordecybombo, breezy | 13 行 / 0.45% |
| `ltt_autorelease` | `Alone` | dong 的插件包 | 8 行 / 5.5% |
| `ltt_boss` | `l4d_boss_percent` | dong 的插件包 | 9 行 / 6.8% |
| `ltt_bile_retarget` | `l4d_target_override` | dong 的插件包 | 18 行 / 9.6% |
| `ltt_flashlight` | `l4d2_NightVision` | X光 | 23 行 / 9.9% |
| `ltt_hitsound` | `hitsound_branches 1.1.5` | 社区分支版 | 7 行 / 6.4% |
| `ltt_longad` | `advertisements (v1.0h)` | Tsunami & HarryPotter | 23 行 / 13.2% |
| `ltt_skill_lite` | `l4d2_skill_detect` | 社区技能提示插件 | 74 行 / 21.9% |
| `ltt_si_ai` | `aggresive_specials_patch` | sorallll, fdxx | 6 行 / 6.3% |
| `ltt_megamob` | `l4d2_horde_equaliser` / `l4d2_tank_horde_monitor` | dong 的插件包 | 14 行 / 2.4%；12 行 / 2.1% |
| `ltt_kd` | `NekoKillHud` | Neko 系列 | 8 行 / 3.0% |

**这些"相同行"是什么？** 全部是 SourceMod 插件的**必备样板**，例如：

```
#include <sourcemod>
#pragma newdecls required
public Plugin myinfo =
public void OnClientPutInServer(int client)
return Plugin_Continue;
```

换句话说：同一套 SourceMod 框架下，任何一个插件的这几行都会长得一模一样，它们不包含玩法逻辑。
在我们 11 个插件里，**没有任何一个存在成段的逻辑代码复制**。

### 许可证状态

- `fdxx` 的插件仓库是 **GPL-3.0**，与本仓库协议相同，兼容。
- 其余参考件在原发布包里**没有明确的许可证声明**。因此我们采取的做法是：
  **只参考行为，不复制代码，也不在本仓库分发它们的源码**。
- 如果你是被参考插件的作者，认为这里的表述或做法不妥，请开 Issue 告知，我们会调整说明或移除相关表述。

## 收录范围

本仓库**只收录我们自己（LTT）编写的插件源码**，目录前缀统一为 `ltt_`。

## 未收录的第三方源码

线上服务器还运行着大量第三方插件（例：AlliedModders 各家作者的作品、
`豆瓣酱な` 的特感/投票系列、`SilverShot` 的 left4dhooks 等）。这些**源码不在本仓库**，
原因是它们的版权属于各自作者，二次分发需要遵守原作者授权。

> 我们**修改过**的少数第三方插件（例如给 `bots(coop)` 加过一个 cvar、
> 把 `l4d2_away_player` 的几道硬闸撤掉）属于「衍生作品」，
> 同样不在本仓库，以避免授权争议；如需交接，另行单独提供。

## 依赖

- SourceMod 1.12.x
- `left4dhooks` 1.168（部分插件依赖，例如 `ltt_si_spawner` / `ltt_boss` / `ltt_level_heal`）
- 个别插件依赖 SourceMod 自带的 `sdktools` / `dhooks`

## 不包含的内容

- 编译产物（`.smx`）
- 服务器配置（`cfg/sourcemod/*.cfg`，插件首次加载会自动生成）
- 内部运维设计稿与日志
