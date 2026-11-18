# NOTICE

## 关于 AI 生成

本仓库内的 **LTT 系列插件源码与全部文档均为 AI 生成**（DeepSeek Harness / DeepSeek 系列模型，
经多轮对话产出），不是作者手写；作者负责需求、实测反馈、审核采纳与运维。
使用前请自行审阅与测试，作者不对代码正确性、安全性或适用性作任何担保（详见 `LICENSE`）。

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
