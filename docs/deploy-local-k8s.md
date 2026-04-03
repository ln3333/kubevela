# 部署 Vela Core 到本地 Kubernetes

本文档介绍如何在本地 Kubernetes (Docker Desktop K8s) 构建并部署 vela-core。

## 前置条件

- Docker Desktop 已启用 Kubernetes
- kubectl 已配置
- Go 1.23+
- Helm 3+

## 部署步骤

### 1. 修改 Dockerfile（如需要使用国内代理）

修改 `Dockerfile` 第 12 行，将默认 GOPROXY 改为国内镜像：

```dockerfile
ENV GOPROXY=${GOPROXY:-https://goproxy.cn}
```

### 2. 构建 Docker 镜像

```bash
docker build -t vela-core:latest -f Dockerfile .
```

### 3. 安装 CRDs

```bash
kubectl apply -f charts/vela-core/crds/
```

### 4. 安装 Helm（如未安装）

```bash
brew install helm
```

### 5. 安装 vela-core

```bash
helm install vela-core charts/vela-core \
  --set image.repository=vela-core \
  --set image.tag=latest \
  --set image.pullPolicy=IfNotPresent \
  --create-namespace \
  -n vela-system \
  --timeout 5m
```

### 6. 手动拉取依赖镜像（如需要）

如果 cluster-gateway 镜像拉取缓慢，可手动提前拉取：

```bash
docker pull oamdev/cluster-gateway:v1.9.0-alpha.2
```

### 7. 验证部署

检查 Pod 状态：

```bash
kubectl get pods -n vela-system
```

预期输出：

```
NAME                                               READY   STATUS      RESTARTS   AGE
vela-core-5f9849dd7b-fsm9d                         1/1     Running     0          5m
vela-core-cluster-gateway-f4bc47c59-8xsqw          1/1     Running     0          5m
vela-core-admission-patch-xxxxx                    0/1     Completed   0          5m
```

查看组件定义：

```bash
./bin/vela comp list
```

查看 Trait 定义：

```bash
./bin/vela trait list
```

## 部署应用示例

### 部署 Nginx

创建 Application CR：

```yaml
# docs/examples/nginx-app.yaml
apiVersion: core.oam.dev/v1beta1
kind: Application
metadata:
  name: nginx-app
spec:
  components:
    - name: nginx
      type: webservice
      properties:
        image: nginx:latest
        port: 80
      traits:
        - type: expose
          properties:
            port: [80]
            http: true
```

部署：

```bash
kubectl apply -f docs/examples/nginx-app.yaml
```

验证：

```bash
# 查看 Application 状态
kubectl get app

# 查看 Pods
kubectl get pods

# 查看 Service
kubectl get svc
```

访问 nginx：

```bash
kubectl port-forward svc/nginx 8080:80
# 然后访问 http://localhost:8080
```

删除应用：

```bash
kubectl delete -f docs/examples/nginx-app.yaml
```

## 卸载

```bash
helm uninstall vela-core -n vela-system
kubectl delete -f charts/vela-core/crds/
```

## 常见问题

### Helm 安装超时

如果 helm 安装时超时（Job not ready），可以增加 timeout 或等待后重试：

```bash
# 等待资源就绪
kubectl wait --for=condition=Ready pod -n vela-system -l app.kubernetes.io/instance=vela-core --timeout=300s

# 或直接检查状态后重试
helm install vela-core charts/vela-core \
  --set image.repository=vela-core \
  --set image.tag=latest \
  --set image.pullPolicy=IfNotPresent \
  --create-namespace \
  -n vela-system \
  --timeout 10m
```

### 镜像拉取失败

如果某些镜像拉取缓慢，可手动拉取：

```bash
docker pull oamdev/cluster-gateway:v1.9.0-alpha.2
```
