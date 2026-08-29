# 新增供应商五步法

给 `agent-credentials-skill` 增加一个供应商（如 npm、Hugging Face、Docker Hub）时，按五步走：

1. **令牌文件命名**：`~/.machine-tokens/<provider>_token.txt`（如 `npm_token.txt`），命令里写 `$env:USERPROFILE\.machine-tokens\<provider>_token.txt`。
2. **注入命令**：在 `SKILL.md` 增加一个小节，定义读文件 → 环境变量的标准片段：
   ```powershell
   $env:NPM_TOKEN = (Get-Content -Raw "$env:USERPROFILE\.machine-tokens\npm_token.txt").Trim()
   ```
3. **校验 API**：在 `scripts/check.ps1` 增加一个 `Test-<Provider>` 函数，用官方只读接口判断有效：
   - npm：`npm whoami`（需 `NPM_TOKEN`）
   - Hugging Face：`GET https://huggingface.co/api/whoami-v2`（`Authorization: Bearer <token>`）
   - Docker Hub：`GET https://hub.docker.com/v2/users/me/`
   只输出掩码，不打印明文；沿用退出码约定（0 全部有效 / 1 存在失效 / 2 存在缺失）。
4. **刷新命令**：在 `scripts/refresh.ps1` 增加对应重新注册/配置文件生成逻辑（如 npm 写 `.npmrc`），写文件前先备份。
5. **示例与登记**：在 `SKILL.md` 补使用示例，在 `README.md` 的目录规范表里登记文件与环境变量。

## 通用注意事项

- 校验一律用只读接口，避免把令牌发到非官方端点。
- 含明文令牌的配置文件（`.pypirc`、`.npmrc`）不提交、不进同步盘。
- 各供应商令牌有效期检查方式不同：PyPI 可解码 base64 内嵌到期时间；其它供应商以校验接口返回为准。
---

## v0.2 Provider Adapter 契约

新增供应商先读 [docs/provider-adapter-contract-v0.2.md](provider-adapter-contract-v0.2.md)：适配器 = 探测 + 归一化观察，公共协议唯一为 `Diagnosis Result v0.2`（schema + diagnostic-codes.json）。

## 供应商状态矩阵（v0.2 / v0.3）

| 供应商 | v0.2 诊断 | v0.3 凭据上下文 |
|---|---|---|
| GitHub | 成熟/参考（发现 + 认证状态 + 传输 + doctor 完整链路） | 多账号/profile 逻辑引用适配器（`github-context.ps1`） |
| npm | 参考/实验（仅发现，`doctor.ps1 -Provider npm`） | v0.3 上下文参考适配器（`npm-context.ps1`，无实时认证变更） |
| PyPI | 保留 v0.1 行为（`check.ps1` / `refresh.ps1` / twine 注入） | 尚无完整 v0.3 上下文适配器 |
| 其它供应商 | 未来/实验（按实际进展如实标注） | 未来/实验 |

当前架构/版本：**v0.3.0**；v0.1 / v0.2 行为保持向后兼容。

## Provider Adapter 边界（v0.3）

- **提供商特定观察/引用转换**：适配器只负责把已消毒的观察转成逻辑引用（`env/...`、`cli/<host>/<account>`、`config/<registry>/<account>`、`connector/...`），并做确定性去重与冲突 fail-closed。
- **通用 context resolver 保持 provider 中立**：`scripts/core/context.ps1` 的 `Resolve-AgentCredentialContext` 与 `scripts/core/binding.ps1` 的 `Resolve-AgentCredentialProjectProfile` 不含任何 provider 分支，GitHub / npm 走同一套逻辑。
- **适配器绝不按数组顺序选择**：排序只用于报告；选择权归通用 resolver，歧义必须 fail-closed。
- **适配器不拥有原始秘密存储**：不读原始值、不写凭据文件、不做 login/logout/config 变更；原始值只在执行层进程作用域内短暂存在。

## v0.4 Broker 适配器边界与版本说明（当前版本 v0.4.0）

- **GitHub / npm 适配器把提供商特定观察转成逻辑引用**；**provider 特化分支止于适配层**。
- **Core 的 plan / 执行门禁保持 provider 中立**：`scripts/core/plan.ps1`（`New-AgentCredentialExecutionPlan` / `Get-AgentCredentialBrokerGate`）与 `scripts/core/broker-execution.ps1`（`Invoke-AgentCredentialExecutionPlan`）不含 GitHub/npm 分支。
- **`active` 仍不是选择权威**；选择权在通用 resolver（v0.3 语义延续）。
- **适配器不拥有执行期的 raw 秘密解析**：raw 值只经调用方 resolver 在进程作用域执行边界内瞬时存在。

> 当前架构/版本：**v0.4.0**（Credential Broker / ExecutionPlan）；v0.1 / v0.2 / v0.3 行为保持向后兼容。（v0.3.0 历史 tag/Release 仍指向 main=7ff474f。）
