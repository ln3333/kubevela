# KubeVela Workflow Step 开发指南

## 1. 什么是 Workflow Step

Workflow Step（工作流步骤）是 KubeVela Application 部署工作流的基本执行单元。每个 Application 可以在 `spec.workflow` 中定义一系列有序的 steps，每个 step 执行一个特定操作（如部署组件、发送通知、等待审批等）。

### 核心数据结构

```go
// kubevela/apis/core.oam.dev/v1beta1/application_types.go
type Workflow struct {
    Ref   string                               `json:"ref,omitempty"`
    Mode  *wfTypesv1alpha1.WorkflowExecuteMode `json:"mode,omitempty"`
    Steps []wfTypesv1alpha1.WorkflowStep       `json:"steps,omitempty"`
}
```

每个 step 通过 `type` 字段指向一个 **WorkflowStepDefinition**，它是一个 Kubernetes CRD：

```go
// kubevela/apis/core.oam.dev/v1beta1/workflow_step_definition.go
type WorkflowStepDefinitionSpec struct {
    Reference common.DefinitionReference `json:"definitionRef,omitempty"`
    Schematic *common.Schematic          `json:"schematic,omitempty"`  // 只支持 CUE
    Version   string                     `json:"version,omitempty"`
}
```

### 使用示例

```yaml
apiVersion: core.oam.dev/v1beta1
kind: Application
metadata:
  name: my-app
spec:
  components:
    - name: my-server
      type: webservice
      properties:
        image: nginx:latest
  workflow:
    steps:
      - name: deploy-step
        type: apply-deployment      # ← 匹配 WorkflowStepDefinition 名称
        properties:
          image: nginx:latest       # ← 填入 parameter.image
          replicas: 3               # ← 填入 parameter.replicas
```

## 2. 内置 Workflow Step 列表

共 31 个，位于 `kubevela/vela-templates/definitions/internal/workflowstep/`：

| Step 类型 | 分类 | 说明 |
|-----------|------|------|
| `deploy` | Application Delivery | 统一的多集群部署步骤 |
| `apply-component` | Application Delivery | 应用特定组件及其 traits |
| `apply-deployment` | Resource Management | 用指定 image 和 cmd 应用 Deployment |
| `apply-object` | Resource Management | 应用原始 Kubernetes 对象 |
| `read-object` | Resource Management | 从集群读取 Kubernetes 对象 |
| `suspend` | Process Control | 暂停工作流，等待手动恢复 |
| `step-group` | Process Control | 并行执行子步骤 |
| `depends-on-app` | Process Control | 等待另一个 Application 完成 |
| `notification` | Notification | 发送通知到 Email/DingTalk/Slack/Lark/Webhook |
| `webhook` | Notification | 向 Webhook URL 发送 POST 请求 |
| `request` | Notification | 向指定 URL 发送请求 |
| `export2secret` | Data Export | 将数据导出到 Kubernetes Secret |
| `export2config` | Data Export | 将数据导出到 ConfigMap |
| `export-data` | Data Export | 将数据导出到指定集群 |
| `export-service` | Data Export | 将 Service 导出到指定集群 |
| `create-config` | Config Management | 创建或更新 config |
| `read-config` | Config Management | 读取 config |
| `delete-config` | Config Management | 删除 config |
| `list-config` | Config Management | 列出 config |
| `build-push-image` | CI/CD | 从 git URL 构建并推送镜像 |
| `check-metrics` | Observability | 验证应用指标 |
| `collect-service-endpoints` | Observability | 收集应用的 service endpoints |
| `print-message-in-status` | Debug | 在 step status 中打印消息 |
| `vela-cli` | Utility | 运行 vela CLI 命令 |
| `clean-jobs` | Utility | 清理集群中的 jobs |
| `restart-workflow` | Utility | 按定时/间隔重启当前 workflow |
| `apply-terraform-config` | Terraform | 应用 Terraform 配置 |
| `apply-terraform-provider` | Terraform | 应用 Terraform provider 配置 |
| `deploy-cloud-resource` | Cloud | 部署云资源并分发 secret 到多集群 |
| `share-cloud-resource` | Cloud | 同步 Terraform 组件创建的 secret 到运行时集群 |
| `generate-jdbc-connection` | Cloud | 基于 alibaba-rds 组件生成 JDBC 连接 |

另有 5 个已废弃步骤位于 `definitions/deprecated/`，以及 vela-workflow addon 提供的额外步骤（`addon-operation`、`apply-app`、`chat-gpt`、`read-app`）。

## 3. CUE 语法详解

KubeVela 使用 [CUE](https://cuelang.org/) 语言编写 Definition 模板。以 `apply-deployment.cue` 为例：

```cue
import (
    "strconv"
    "strings"
    "vela/kube"       // KubeVela 内置包，提供 #Apply 等操作原语
    "vela/builtin"    // KubeVela 内置包，提供 #Suspend、#ConditionalWait 等
)

// ─── 元数据块：定义 step 名称、描述、类型 ───
"apply-deployment": {
    alias: ""
    annotations: {}
    attributes: {}
    description: "Apply deployment with specified image and cmd."
    annotations: {
        "category": "Resource Management"
    }
    labels: {}
    type: "workflow-step"
}

// ─── 模板块：step 的核心执行逻辑 ───
template: {
    // output: 执行 Kubernetes 资源操作
    output: kube.#Apply & {
        $params: {
            cluster: parameter.cluster
            value: {
                apiVersion: "apps/v1"
                kind:       "Deployment"
                metadata: {
                    name:      context.stepName
                    namespace: context.namespace
                }
                spec: {
                    selector: matchLabels: "workflow.oam.dev/step-name": "\(context.name)-\(context.stepName)"
                    replicas: parameter.replicas
                    template: {
                        metadata: labels: "workflow.oam.dev/step-name": "\(context.name)-\(context.stepName)"
                        spec: containers: [{
                            name:  context.stepName
                            image: parameter.image
                            if parameter["cmd"] != _|_ {
                                command: parameter.cmd
                            }
                        }]
                    }
                }
            }
        }
    }

    // wait: 等待条件满足后继续
    wait: builtin.#ConditionalWait & {
        $params: continue: output.$returns.value.status.readyReplicas == parameter.replicas
    }

    // parameter: 输入参数 schema
    parameter: {
        image:    string          // 必填，string 类型
        replicas: *1 | int        // 默认值 1，int 类型
        cluster:  *"" | string    // 默认空串（本地集群）
        cmd?: [...string]         // 可选字段，string 列表
    }
}
```

### CUE 核心语法速查

| 语法 | 含义 | 示例 |
|------|------|------|
| `string` / `int` / `bool` | 基础类型约束 | `name: string` |
| `*value \| type` | 默认值 + 类型 | `port: *80 \| int` |
| `field?` | 可选字段 | `cmd?: string` |
| `[...T]` | 开放列表（元素类型 T） | `args: [...string]` |
| `#Name` | Definition（schema/类型定义） | `#Apply` |
| `A & B` | 统一/合并（Unification） | `#Schema & {field: "val"}` |
| `_\|_` | Bottom 值（不存在/错误） | `if x != _\|_` |
| `"\(expr)"` | 字符串插值 | `"hello \(name)"` |
| `a: b: c: val` | 链式嵌套简写 | 等同 `a: { b: { c: val } }` |
| `if cond { ... }` | 条件字段生成 | `if x > 0 { y: x }` |
| `_` | Top 值（任意类型） | `field: _` |
| `{...}` | 开放 struct（允许任意字段） | `value: {...}` |
| `...` | struct 尾部 open marker | `#Def: { name: string, ... }` |

### CUE 模板中的变量来源

| 变量 | 来源 | 说明 |
|------|------|------|
| `parameter.*` | 用户在 Application YAML 的 `properties` 中传入 | 由 `parameter` 块定义 schema |
| `context.stepName` | 运行时注入 | 当前 step 的名称 |
| `context.name` | 运行时注入 | Application 的名称 |
| `context.namespace` | 运行时注入 | Application 的命名空间 |
| `output.$returns.*` | 前序操作的返回值 | 如 `kube.#Apply` 返回的资源对象 |

## 4. Provider 机制：CUE 如何调用 Go

CUE 模板中的操作原语（如 `kube.#Apply`）通过 **Provider 机制** 桥接到 Go 实现。

### 4.1 CUE Schema 定义

以 `kube.#Apply` 为例，定义在 [workflow/pkg/providers/kube/kube.cue](https://github.com/kubevela/workflow/tree/main/pkg/providers/kube)：

```cue
#Apply: {
    #do:       "apply"       // 要调用的 provider 方法名
    #provider: "kube"        // 使用的 provider 名称

    $params: {
        cluster: *"" | string   // 目标集群，默认本地
        value: {...}            // 要 apply 的 K8s 资源
        patch?: {...}           // 可选的 patcher
    }

    $returns?: {
        value?: {...}           // apply 后返回的资源对象
        err?: string            // 错误信息
    }
    ...
}
```

同文件中还定义了 `#Patch`、`#ApplyInParallel`、`#Read`、`#List`、`#Delete` 等操作。

### 4.2 Go 实现

CUE 中 `#do: "apply"` + `#provider: "kube"` 被 cuex 编译器路由到 Go 函数，位于 [workflow/pkg/providers/kube/kube.go](https://github.com/kubevela/workflow/tree/main/pkg/providers/kube)：

```go
func Apply(ctx context.Context, params *ResourceParams) (*ResourceReturns, error) {
    workload := params.Params.Resource      // 从 $params.value 反序列化
    handlers := getHandlers(params.RuntimeParams)

    if workload.GetNamespace() == "" {
        workload.SetNamespace("default")
    }
    for k, v := range params.RuntimeParams.Labels {
        k8s.AddLabel(workload, k, v)
    }

    deployCtx := handleContext(ctx, params.Params.Cluster)
    if err := handlers.Apply(deployCtx, params.KubeClient, ...); err != nil {
        return nil, err
    }
    return &ResourceReturns{Returns: ResourceReturnVars{Resource: workload}}, nil
}
```

底层 `apply` 函数的逻辑：
1. `client.Get()` 检查资源是否已存在
2. 不存在 → `client.Create()` 创建
3. 已存在 → `patch.ThreeWayMergePatch()` 三方合并后 `client.Patch()` 更新

### 4.3 Provider 注册

在 `kubevela/pkg/workflow/providers/compiler.go` 中，CUE schema 和 Go 实现被绑定注册：

```go
cuex.NewCompilerWithInternalPackages(
    // ...
    cuexruntime.NewInternalPackage("kube", kube.GetTemplate(), kube.GetProviders()),
    cuexruntime.NewInternalPackage("builtin", builtin.GetTemplate(), builtin.GetProviders()),
    cuexruntime.NewInternalPackage("multicluster", multicluster.GetTemplate(), multicluster.GetProviders()),
    // ...
)
```

- `kube.GetTemplate()` → 通过 `//go:embed kube.cue` 返回 CUE schema
- `kube.GetProviders()` → 返回 `#do` 名称到 Go 函数的映射：

```go
func GetProviders() map[string]cuexruntime.ProviderFn {
    return map[string]cuexruntime.ProviderFn{
        "apply":             GenericProviderFn(Apply),
        "apply-in-parallel": GenericProviderFn(ApplyInParallel),
        "read":              GenericProviderFn(Read),
        "list":              GenericProviderFn(List),
        "delete":            GenericProviderFn(Delete),
        "patch":             NativeProviderFn(Patch),
    }
}
```

### 4.4 可用的内置 Provider 包

| CUE 包名 | import 路径 | 源码位置 | 提供的操作原语 |
|-----------|-------------|----------|---------------|
| `kube` | `"vela/kube"` | [workflow/pkg/providers/kube](https://github.com/kubevela/workflow/tree/main/pkg/providers/kube) | `#Apply`, `#Read`, `#List`, `#Delete`, `#Patch`, `#ApplyInParallel` |
| `builtin` | `"vela/builtin"` | workflow/pkg/providers/builtin | `#Suspend`, `#ConditionalWait`, `#Fail`, `#Message`, `#Log` |
| `http` | `"vela/http"` | workflow/pkg/providers/http | `#Do` (HTTP 请求) |
| `email` | `"vela/email"` | workflow/pkg/providers/email | `#Send` (发送邮件) |
| `metrics` | `"vela/metrics"` | workflow/pkg/providers/metrics | `#PromCheck` (Prometheus 指标检查) |
| `time` | `"vela/time"` | workflow/pkg/providers/time | `#Date`, `#Timestamp` |
| `util` | `"vela/util"` | workflow/pkg/providers/util | `#String`, `#Log`, `#PatchK8sObject` |
| `multicluster` | `"vela/multicluster"` | kubevela/pkg/workflow/providers/multicluster | `#Deploy`, `#ListClusters` |
| `oam` | `"vela/oam"` | kubevela/pkg/workflow/providers/oam | `#ApplyComponent`, `#RenderComponent`, `#LoadComponets` |
| `config` | `"vela/config"` | kubevela/pkg/workflow/providers/config | config CRUD 操作 |
| `query` | `"vela/query"` | kubevela/pkg/workflow/providers/query | 资源查询操作 |
| `terraform` | `"vela/terraform"` | kubevela/pkg/workflow/providers/terraform | Terraform 相关操作 |
| `op` | `"vela/op"` | (legacy) 旧版兼容包 | 旧版操作原语 |

### 4.5 完整调用链路

```
用户 Application YAML
    │  workflow.steps[].type = "apply-deployment"
    │  workflow.steps[].properties = { image: "nginx", replicas: 3 }
    │
    ▼
WorkflowStepLoader (kubevela/pkg/workflow/template/load.go)
    │  1. 先查静态内置 CUE 文件
    │  2. 再查集群中的 WorkflowStepDefinition CR
    │  → 加载 apply-deployment.cue 模板
    │
    ▼
cuex 编译器
    │  1. 将 properties 绑定到 parameter
    │  2. 注入 context（stepName, namespace, name 等）
    │  3. 渲染 template → 得到 kube.#Apply 调用
    │  4. 发现 #provider="kube", #do="apply"
    │  5. 路由到 Go provider: kube.Apply()
    │
    ▼
Go 函数 kube.Apply()
    │  反序列化 $params.value → Unstructured Deployment 对象
    │  → client.Get() 检查是否存在
    │  → 不存在: client.Create() / 已存在: ThreeWayMergePatch + client.Patch()
    │
    ▼
返回 $returns.value （apply 后的 Deployment 对象）
    │
    ▼
builtin.#ConditionalWait
    │  轮询直到 output.$returns.value.status.readyReplicas == parameter.replicas
    │
    ▼
Step 完成 → 进入下一个 step
```

## 5. 如何新增自定义 Workflow Step

### 方式一：创建 WorkflowStepDefinition CR（推荐，无需改代码）

编写 CUE 模板，通过 `kubectl apply` 将 `WorkflowStepDefinition` 应用到集群：

```yaml
apiVersion: core.oam.dev/v1beta1
kind: WorkflowStepDefinition
metadata:
  name: my-custom-step
  namespace: vela-system
spec:
  schematic:
    cue:
      template: |
        import "vela/kube"

        apply: kube.#Apply & {
          $params: {
            cluster: parameter.cluster
            value: {
              apiVersion: "v1"
              kind:       "ConfigMap"
              metadata: {
                name:      parameter.name
                namespace: context.namespace
              }
              data: parameter.data
            }
          }
        }

        parameter: {
          name:    string
          cluster: *"" | string
          data: [string]: string
        }
```

### 方式二：在源码中添加内置步骤

在 `kubevela/vela-templates/definitions/internal/workflowstep/` 下添加 `.cue` 文件，参考现有模板格式。

### 方式三：通过 Addon 分发

在 addon 的 `definitions/` 目录下放置 CUE 定义文件，addon 安装时自动注册。

### 方式四：使用 defkit Go API

通过 `kubevela/pkg/definition/defkit` 包以编程方式构建步骤定义，适合代码生成和 addon 开发场景。

## 6. 关键源码索引

| 内容 | 路径 |
|------|------|
| Application 类型定义 | `kubevela/apis/core.oam.dev/v1beta1/application_types.go` |
| WorkflowStepDefinition CRD | `kubevela/apis/core.oam.dev/v1beta1/workflow_step_definition.go` |
| 内置步骤 CUE 模板 | `kubevela/vela-templates/definitions/internal/workflowstep/*.cue` |
| 已废弃步骤 | `kubevela/vela-templates/definitions/deprecated/*.cue` |
| Helm 打包的 CR | `kubevela/charts/vela-core/templates/defwithtemplate/*.yaml` |
| 模板加载器 | `kubevela/pkg/workflow/template/load.go` |
| Provider 编译器注册 | `kubevela/pkg/workflow/providers/compiler.go` |
| kube Provider (CUE + Go) | [github.com/kubevela/workflow/pkg/providers/kube](https://github.com/kubevela/workflow/tree/main/pkg/providers/kube) |
| defkit 构建器 | `kubevela/pkg/definition/defkit/workflow_step.go` |
| defkit 注册表 | `kubevela/pkg/definition/defkit/registry.go` |
| 定义控制器 | `kubevela/pkg/controller/core.oam.dev/v1beta1/core/workflow/workflowstepdefinition/` |
| 设计文档 | `kubevela/design/vela-core/workflow_policy.md` |

## 7. build-push-image-v2：基于远端 Docker Daemon 的构建步骤

### 概述

`build-push-image-v2` 是对内置 `build-push-image`（基于 Kaniko）的替代方案，改用**远端 Docker daemon** 构建镜像，支持从 **GitLab SSH** 拉取代码，并按 4 种代码类型自动生成 Dockerfile。

### 与 build-push-image (Kaniko) 的对比

| 特性 | build-push-image (Kaniko) | build-push-image-v2 (Docker daemon) |
|------|--------------------------|-------------------------------------|
| 构建方式 | Kaniko（无 daemon） | 远端 Docker daemon |
| 代码拉取 | Git Token | SSH 私钥 |
| Dockerfile | 仓库自带 | 仓库自带或按代码类型自动生成 |
| 镜像参数 | 单一 `image` 字段 | registry / repo / imageName / imageTag 分开 |
| 依赖 | 无（Kaniko 自包含） | 需要可达的 Docker daemon |

### 架构

```
用户 Application YAML
    │  type: build-push-image-v2
    │  properties: { gitURL, codeType, repo, imageName, ... }
    │
    ▼
build-push-image-v2.cue
    │
    ├─ kube.#Apply → 从 properties.sshKey 创建 Opaque Secret（键 ssh-privatekey）
    ├─ kube.#Apply → 创建 builder Pod
    │      ├─ env: GIT_URL, GIT_BRANCH, CODE_TYPE, DOCKER_HOST, REGISTRY, REPO, IMAGE_NAME, IMAGE_TAG, ...
    │      └─ volume: 上述 Secret → /root/.ssh/id_rsa（subPath ssh-privatekey）
    │
    ├─ util.#Log → 采集构建日志
    ├─ kube.#Read → 读取 Pod 状态
    └─ builtin.#ConditionalWait → 等待 phase == "Succeeded"
```

Builder Pod 内部（entrypoint.sh）：
```
SSH 配置 → git clone → Dockerfile 检测/生成 → docker build (远端) → docker push
```

### 参数说明

| 参数 | 必填 | 默认值 | 说明 |
|------|------|--------|------|
| `gitURL` | 是 | - | GitLab SSH URL，如 `ssh://git@gitlab.example.com/group/repo.git` |
| `gitBranch` | 否 | `"main"` | Git 分支 |
| `codeType` | 是 | - | 代码类型：`python3.12-pip` / `java21-maven` / `node-yarn` / `node-npm` |
| `dockerHost` | 否 | `"tcp://192.168.1.1:2375"` | 远端 Docker daemon 地址 |
| `registry` | 否 | `"harbor.dev.example.com"` | 镜像仓库地址 |
| `repo` | 是 | - | 镜像 repo 路径，如 `"team"` |
| `imageName` | 是 | - | 镜像名，如 `"my-app"` |
| `imageTag` | 否 | `"latest"` | 镜像 tag |
| `dockerfile` | 否 | - | 自定义 Dockerfile 相对路径；不填则按 `codeType` 自动生成 |
| `buildArgs` | 否 | - | 额外 build-arg 列表，如 `["KEY1=VAL1"]` |
| `sshKey` | 是 | - | SSH 私钥 PEM（用于 `ssh://` GitLab）。工作流会先在应用命名空间创建 **Opaque Secret**（键名 `ssh-privatekey`），再拉起 builder Pod 挂载；**勿将私钥写入 Git 或提交到公开仓库** |
| `builderImage` | 否 | `"harbor.dev.example.com/infra/vela-builder:latest"` | 构建镜像 |

自动创建的 Secret 名称：`{Application 名}-{stepSessionID}-git-ssh`（与 `context` 一致，每次执行唯一）。

最终推送的镜像地址：`${registry}/${repo}/${imageName}:${imageTag}`

### 代码类型与自动生成的 Dockerfile

当仓库中无 Dockerfile（或未指定 `dockerfile` 参数）时，`entrypoint.sh` 根据 `codeType` 自动生成：

- **python3.12-pip**：`python:3.12-slim` + `pip install -r requirements.txt`
- **java21-maven**：多阶段构建，`maven:3.9-eclipse-temurin-21` 编译 + `eclipse-temurin:21-jre` 运行
- **node-yarn**：`node:20-slim` + `yarn install && yarn build`
- **node-npm**：`node:20-slim` + `npm ci && npm run build`

### 前置准备

1. **构建 builder 镜像**：

   ```bash
   cd kubevela/docs/builder-image
   docker build -t harbor.dev.example.com/infra/vela-builder:latest -f Dockerfile.builder .
   docker push harbor.dev.example.com/infra/vela-builder:latest
   ```

2. **SSH 私钥**：在 Application 的 `properties.sshKey` 中提供 PEM 内容（或通过 VelaUX 表单录入）。工作流步骤会 **自动创建** 上述 Secret，**无需**再手工 `kubectl create secret`（除非你希望改用其它方案自行管理凭据）。

3. **确保远端 Docker daemon 可达**（默认 `192.168.1.1:2375`）。

### 将 WorkflowStepDefinition 应用到集群

把 `build-push-image-v2.cue` 安装为集群中的 `WorkflowStepDefinition`（与 VelaUX、控制器约定一致，命名空间一般为 **`vela-system`**）。

#### 方式一：CLI（推荐）

使用 KubeVela CLI 将 CUE 编译为 CR 并写入集群；**默认命名空间为 `vela-system`**。

```bash
# 在 kubevela 仓库根目录下，或写出 CUE 的绝对路径
vela def apply kubevela/vela-templates/definitions/internal/workflowstep/build-push-image-v2.cue
```

常用选项：

```bash
# 仅渲染/校验，不真正 apply（便于检查生成的对象）
vela def apply kubevela/vela-templates/definitions/internal/workflowstep/build-push-image-v2.cue --dry-run

# 显式指定定义所在命名空间（一般保持默认即可）
vela def apply kubevela/vela-templates/definitions/internal/workflowstep/build-push-image-v2.cue -n vela-system
```

前置条件：`kubectl` 上下文指向目标集群，且已安装 KubeVela、`WorkflowStepDefinition` CRD 可用。

验证：

```bash
kubectl get workflowstepdefinition build-push-image-v2 -n vela-system -o yaml
```

成功 apply 后，控制器会写入 OpenAPI Schema 的 ConfigMap（供 VelaUX 表单等使用）。

#### 方式二：YAML + kubectl apply

若使用 GitOps 或不想在本机安装 `vela` CLI：

1. 使用 `vela def apply ... --dry-run` 得到 `WorkflowStepDefinition` 的 YAML，或按本文档 **第 5 节**手写 `WorkflowStepDefinition`，将 CUE 模板放在 `spec.schematic.cue.template` 下。
2. 执行：

```bash
kubectl apply -f build-push-image-v2.yaml
```

建议仍放在 **`vela-system`**（或与集群中其它 `WorkflowStepDefinition` 一致的系统命名空间）。

#### 方式三：随 Helm Chart 发布（维护发行版）

内置步骤由 `vela-templates` 下的 CUE **生成**为 `charts/vela-core/templates/defwithtemplate/*.yaml`（例如现有的 `build-push-image.yaml`）。若要把 `build-push-image-v2` 打进官方 chart，需在仓库中执行与 **definition 生成**相关的 `make` 目标，将新 CUE 纳入 chart 模板；面向**日常集群**时，**方式一**即可。

#### 应用后注意

| 项 | 说明 |
|----|------|
| Application 引用 | `workflow.steps[].type: build-push-image-v2` 与 CR 名称一致即可 |
| Builder 镜像 | 定义只负责下发 Secret 与 Pod；仍需按上文构建并推送 `builderImage` |
| `sshKey` 安全 | 私钥会进入 Application 资源与 etcd；生产环境建议配合 SealedSecret、External Secrets、或仅通过 CI 注入 properties |
| 更新定义 | 修改 CUE 后再次执行 `vela def apply` 覆盖同名 CR |

### 使用示例

```yaml
apiVersion: core.oam.dev/v1beta1
kind: Application
metadata:
  name: my-app
spec:
  workflow:
    steps:
      - name: build-image
        type: build-push-image-v2
        properties:
          gitURL: "ssh://git@gitlab.example.com/team/my-app.git"
          gitBranch: "develop"
          codeType: "java21-maven"
          repo: "team"
          imageName: "my-app"
          imageTag: "v1.0.0"
          # 多行 PEM；勿提交到 Git，可用 CI 注入或外部密钥方案
          sshKey: |
            -----BEGIN OPENSSH PRIVATE KEY-----
            ...
            -----END OPENSSH PRIVATE KEY-----
```

### 源码文件

| 文件 | 说明 |
|------|------|
| `kubevela/vela-templates/definitions/internal/workflowstep/build-push-image-v2.cue` | CUE workflow step 定义 |
| `kubevela/docs/builder-image/entrypoint.sh` | 构建 Pod 的入口脚本 |
| `kubevela/docs/builder-image/Dockerfile.builder` | 构建镜像的 Dockerfile |
