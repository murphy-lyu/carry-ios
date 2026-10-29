# CloudKit 原生结构初始化工具

独立开发应用 `app.nevestudio.carry.schema-bootstrap`，仅面向 `Bing Xue / 25RAM7275Z` 的 `iCloud.app.nevestudio.carry` Development 环境。它没有生产部署入口，不覆盖 Carry，不包含 Carry 的 App Group、HealthKit、照片或 WeatherKit 权限。

## 模型来源

在专用 QA 模拟器上运行 `CarryAutomationTests/CloudKitModelExportTests`。该测试用 Apple 的 `NSManagedObjectModel.makeManagedObjectModel(for: SchemaV1.models)` 导出真实模型，验证安全归档读回及全部类型覆盖；只写模型元数据，不读取用户行程、不访问 CloudKit。每次模型变更都必须重新执行，不能复用旧二进制。

模拟器保持启动后，从本目录执行：

```sh
python3 prepare-model.py --simulator <专用模拟器 UUID>
xcodegen generate --spec project.yml
xcodebuild -project CarrySchemaBootstrap.xcodeproj -scheme CarrySchemaBootstrap \
  -configuration Debug -destination 'id=<测试 iPhone UDID>' \
  -derivedDataPath /tmp/CarrySchemaBootstrapDeviceBuild -allowProvisioningUpdates build
```

生成的 `.mom` 和 Xcode project 均忽略；源模型必须来自本分支当前的编译导出。当前明确要求 11 个实体并含 `AutomationExecutionRecord`；以后增加实体时同步调整工具覆盖门禁。使用不同 Bundle ID 需要独立开发 App ID/profile，但不创建 App Store Connect 应用记录。安装前核对实际签名/profile：团队、唯一工具 Bundle ID、CloudKit 容器和 `Development` 环境；确认无 Carry App Group，profile 包含目标设备。

## 三种显式模式

- `--inspect-model`：仅验证模型归档，不访问 CloudKit。
- 默认（不传参数）：检查设备 iCloud 账户，使用新建临时库执行 `.dryRun`，不上传模型代表记录。dry-run 仍要求 mirroring delegate 能完成 iCloud 初始化。
- `--initialize-development-schema`：在前两项通过后显式执行 Apple 的原生初始化；SDK 上传全字段代表记录生成结构，成功后删除代表记录。此步骤会修改 Development schema，不执行生产部署。

通过 `devicectl device process launch` 运行，每次使用 `--terminate-existing` 开始新进程。结果写入工具自身的 `Documents/bootstrap-result.json`，含时间、模式、阶段、模型名和错误域/码；不记录凭据、账号标识或用户内容。读取结果时核对模式和完成时间，不能把上一次结果当作本次成功。

完成初始化后在 CloudKit Console 核对全量业务类型、字段、索引和生产差异。生产发布确认、实际 iCloud 同步、原生 MCP 联网与 UI 验收单独进行；工具成功不代表这些门禁通过。用户日常测试手机可以先用于接口检查，不能仅根据设备归属要求更换 Apple ID；真实权限错误另行核对。

依据：[Apple SwiftData 同步与原生初始化](https://developer.apple.com/documentation/swiftdata/syncing-model-data-across-a-persons-devices)。

## 2026-10-25 结构快照

用户既有 iPhone 完成原生初始化后，从控制台导出 Development；用户当次确认部署后，控制台显示 Changes Deployed，切换 Production 读回全部 11 个业务类型，再导出 Production。`schema/development.ckdb` 和 `schema/production.ckdb` 字节完全一致，均为 20303 字节，SHA256 `50065f98c272e11711f2be22ddda33c7b11bbefaeebd51f3a52070d96a4fc7b2`。只包含类型、字段、索引和默认角色规则，无用户记录、账号凭据或 token。快照相同证明结构一致，不代替真实双设备同步。工具已从日常测试手机卸载。
