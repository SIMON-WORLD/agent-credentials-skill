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