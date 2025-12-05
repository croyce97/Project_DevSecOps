# Hướng dẫn cài đặt GitLab Runner, SonarQube và Rancher

## 1. Chuẩn bị
- Đảm bảo các EC2 (GitLab Runner, SonarQube) đã được khởi tạo và có thể SSH/Session Manager vào được.
- Đảm bảo các port cần thiết đã mở (thường là 22, 80, 443, 9000, 8443...)
- Đăng nhập vào từng máy chủ với quyền sudo.

## 2. Cài đặt GitLab Runner (Shell Executor + Kubernetes Executor)

Máy chủ GitLab Runner sẽ cài đặt 2 runner:
- **Shell Executor**: Dùng cho các job build Docker, scan SonarQube, Maven, Trivy
- **Kubernetes Executor**: Dùng cho các job deploy ứng dụng lên EKS cluster

### Trên EC2 GitLab Runner (Ubuntu 22.04 LTS):

#### a. Cài đặt các công cụ cần thiết
```bash
sudo apt-get update
sudo apt-get install -y curl openssh-server openssh-client git
```

#### b. Cài đặt Docker (cho Shell Executor)
```bash
sudo apt-get install -y apt-transport-https ca-certificates curl software-properties-common
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt-get update && sudo apt-get install -y docker-ce docker-ce-cli containerd.io
sudo usermod -aG docker gitlab-runner
```

#### c. Cài đặt Maven (cho Shell Executor)
```bash
sudo apt-get install -y maven
mvn --version
```

#### d. Cài đặt Trivy (cho Shell Executor)
```bash
sudo apt-get install -y wget apt-transport-https gnupg lsb-release
wget -qO - https://aquasecurity.github.io/trivy-repo/deb/public.key | sudo apt-key add -
echo "deb https://aquasecurity.github.io/trivy-repo/deb $(lsb_release -sc) main" | sudo tee -a /etc/apt/sources.list.d/trivy.list
sudo apt-get update && sudo apt-get install -y trivy
trivy --version
```

#### e. Cài đặt kubectl (cho Kubernetes Executor)
```bash
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
kubectl version --client
```

#### f. Cài đặt GitLab Runner
```bash
curl -L https://packages.gitlab.com/install/repositories/runner/gitlab-runner/script.deb.sh | sudo bash
sudo apt-get install -y gitlab-runner
```

#### g. Đăng ký Shell Executor (cho Docker, SonarQube, Maven, Trivy)
```bash
sudo gitlab-runner register
```
- Trong quá trình đăng ký:
  - GitLab instance URL: `https://gitlab.com/` (hoặc URL GitLab instance của bạn)
  - Registration token: Lấy từ GitLab Project > Settings > CI/CD > Runners
  - Description: `shell-runner`
  - Tags: `shell,docker,maven,trivy,sonarqube`
  - Executor: `shell`

#### h. Đăng ký Kubernetes Executor (cho deploy lên EKS)
```bash
sudo gitlab-runner register
```
- Trong quá trình đăng ký:
  - GitLab instance URL: `https://gitlab.com/` (hoặc URL GitLab instance của bạn)
  - Registration token: Lấy từ GitLab Project > Settings > CI/CD > Runners
  - Description: `kubernetes-runner`
  - Tags: `k8s,deploy,kubernetes`
  - Executor: `kubernetes`

#### i. Khởi động GitLab Runner
```bash
sudo systemctl enable --now gitlab-runner
sudo gitlab-runner status
sudo gitlab-runner list
```

---

## 3. Kết nối GitLab Runner với EKS (Kubernetes Executor)

### a. Cấu hình kubeconfig cho GitLab Runner
```bash
aws eks update-kubeconfig --name canhnq-cluster --region ap-southeast-2
```

### b. Tạo ServiceAccount, Role, RoleBinding, Secret trên EKS

```bash
cd /path/to/infra/k8s/rbac
kubectl apply -f svc-account.yaml
kubectl apply -f role.yaml
kubectl apply -f role-binding.yaml
kubectl apply -f secret.yaml
```

### c. Lấy token truy cập cho GitLab Runner
```bash
kubectl get secret -n default
```
Tìm secret có tên bắt đầu bằng `gitlab-runner-sa-token-...` (hoặc tên bạn đặt trong svc-account.yaml/secret.yaml).

Lấy token:
```bash
kubectl get secret <SECRET_NAME> -n default -o jsonpath='{.data.token}' | base64 -d
```

### d. Cấu hình GitLab Runner với Kubernetes Executor
Sửa file `/etc/gitlab-runner/config.toml`:
```toml
[[runners]]
  name = "kubernetes-runner"
  url = "https://gitlab.com/"
  token = "YOUR_RUNNER_TOKEN"
  executor = "kubernetes"
  [runners.kubernetes]
    host = "https://YOUR_EKS_ENDPOINT"
    token = "YOUR_K8S_TOKEN"
    namespace = "default"
```

Sau đó khởi động lại GitLab Runner:
```bash
sudo gitlab-runner restart
```

### e. Sử dụng .gitlab-ci.yml để deploy lên EKS
Sau khi kết nối thành công, bạn có thể tạo `.gitlab-ci.yml` trong repository để build/deploy trực tiếp lên EKS từ pipeline GitLab CI.

## 4. Cài đặt SonarQube
### Trên EC2 SonarQube (Ubuntu 22.04 LTS):
```bash
sudo apt update && sudo apt install -y openjdk-17-jdk unzip
wget https://binaries.sonarsource.com/Distribution/sonarqube/sonarqube-10.4.1.88267.zip
unzip sonarqube-10.4.1.88267.zip
sudo mv sonarqube-10.4.1.88267 /opt/sonarqube
sudo useradd -r -s /bin/false sonar
sudo chown -R sonar:sonar /opt/sonarqube
```

- Khởi động SonarQube (background):
```bash
sudo -u sonar /opt/sonarqube/bin/linux-x86-64/sonar.sh start &
```

- Hoặc để chạy ở foreground (để debug):
```bash
sudo -u sonar /opt/sonarqube/bin/linux-x86-64/sonar.sh console
```

- Kiểm tra status:
```bash
sudo -u sonar /opt/sonarqube/bin/linux-x86-64/sonar.sh status
```

- Truy cập SonarQube: http://<EC2_SONARQUBE_PUBLIC_IP>:9000
- **Đăng nhập lần đầu:**
  - Username: `admin`
  - Password: `admin`
  - SonarQube sẽ yêu cầu đổi mật khẩu lần đầu đăng nhập

---

## 5. Cài đặt Rancher (trên EKS Cluster)

Rancher là nền tảng quản lý Kubernetes giúp đơn giản hóa việc triển khai và quản lý nhiều cluster.

**Cài đặt Helm (nếu chưa có):**
```bash
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
helm version
```

**Thêm Helm Repositories:**
```bash
helm repo add rancher-stable https://releases.rancher.com/server-charts/stable
helm repo add jetstack https://charts.jetstack.io
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update
```

**Cài đặt Ingress Controller:**
```bash
helm install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx \
  --create-namespace \
  --set controller.service.type=LoadBalancer
```

**Cài đặt cert-manager:**
```bash
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.14.4/cert-manager.crds.yaml
helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --version v1.14.4
```

**Cài đặt Rancher:**
```bash
kubectl create namespace cattle-system
helm install rancher rancher-stable/rancher \
  --namespace cattle-system \
  --set hostname=rancher.local \
  --set replicas=1 \
  --set bootstrapPassword=admin123
```

**Truy cập Rancher UI:**
```bash
# Lấy địa chỉ LoadBalancer
kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'

# Hoặc sử dụng port-forward
kubectl -n cattle-system port-forward svc/rancher 8443:443
```

- Truy cập: `https://localhost:8443` hoặc `https://<LOADBALANCER_URL>`
- **Đăng nhập:** Username: `admin`, Password: `admin123`

**Lấy password từ secret (nếu cần):**
```bash
kubectl get secret --namespace cattle-system bootstrap-secret -o go-template='{{.data.bootstrapPassword|base64decode}}{{"\n"}}'
```

**Script cài đặt nhanh (`install-rancher.sh`):**
```bash
#!/bin/bash

# Thêm Helm repos
helm repo add rancher-stable https://releases.rancher.com/server-charts/stable
helm repo add jetstack https://charts.jetstack.io
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update

# Cài đặt ingress-nginx
helm install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx \
  --create-namespace \
  --set controller.service.type=LoadBalancer

# Cài đặt cert-manager
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.14.4/cert-manager.crds.yaml
helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --version v1.14.4

# Cài đặt Rancher
kubectl create namespace cattle-system
helm install rancher rancher-stable/rancher \
  --namespace cattle-system \
  --set hostname=rancher.local \
  --set replicas=1 \
  --set bootstrapPassword=admin123
```

---

## 6. Kết nối GitLab Runner với SonarQube

- Shell Executor đã cài sẵn Docker, Maven, Trivy, SonarQube Scanner
- Kubernetes Executor dùng để deploy ứng dụng lên EKS
- Cấu hình SonarQube server trong `.gitlab-ci.yml`
- Tạo pipeline mẫu:
  - Build code với Maven
  - Scan với SonarQube
  - Scan image với Trivy
  - Build Docker image
  - Deploy lên EKS với Kubernetes Executor

---

## 7. Tham khảo
- [GitLab Runner](https://docs.gitlab.com/runner/install/)
- [SonarQube](https://docs.sonarqube.org/latest/setup/get-started-2-minutes/)
- [Trivy](https://aquasecurity.github.io/trivy/)
- [Rancher](https://ranchermanager.docs.rancher.com/getting-started/installation-and-upgrade)
